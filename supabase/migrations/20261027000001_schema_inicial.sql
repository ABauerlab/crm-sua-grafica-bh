-- Schema inicial do CRM Sua Gráfica BH

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null,
  role text not null default 'agent' check (role in ('admin', 'agent')),
  created_at timestamptz not null default now()
);

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  wa_id text not null unique check (wa_id ~ '^[0-9]+$'),
  name text,
  notes text,
  tags text[] not null default '{}',
  created_at timestamptz not null default now()
);

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  -- uma conversa por contato: o cartão do funil acompanha o contato
  contact_id uuid not null unique references public.contacts (id) on delete cascade,
  status text not null default 'open' check (status in ('open', 'pending', 'closed')),
  stage text not null default 'novo' check (stage in ('novo', 'orcamento', 'negociando', 'fechado', 'perdido')),
  assigned_to uuid references public.profiles (id) on delete set null,
  ai_handled boolean not null default false,
  last_message_at timestamptz,
  last_message_preview text,
  last_inbound_at timestamptz,
  unread_count integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  wa_message_id text unique,
  direction text not null check (direction in ('in', 'out')),
  type text not null default 'text' check (type in ('text', 'image', 'document', 'audio', 'template', 'other')),
  body text,
  template_name text,
  media_id text,
  media_path text,
  status text check (status in ('sent', 'delivered', 'read', 'failed')),
  error text,
  created_at timestamptz not null default now()
);

create table public.templates_cache (
  name text not null,
  language text not null,
  category text,
  status text,
  body text,
  synced_at timestamptz not null default now(),
  primary key (name, language)
);

-- wa_id já é indexado pela restrição unique; os demais índices abaixo.
create index conversations_last_message_at_idx on public.conversations (last_message_at desc nulls last);
create index conversations_assigned_to_idx on public.conversations (assigned_to);
create index messages_conversation_id_created_at_idx on public.messages (conversation_id, created_at);
create index contacts_tags_idx on public.contacts using gin (tags);

-- Funções de apoio para as políticas de RLS
create function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.profiles where id = (select auth.uid()));
$$;

create function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'admin');
$$;

revoke execute on function public.is_staff() from public, anon;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_staff() to authenticated;
grant execute on function public.is_admin() to authenticated;

-- RLS em todas as tabelas
alter table public.profiles enable row level security;
alter table public.contacts enable row level security;
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.templates_cache enable row level security;

-- profiles: equipe lê; só admin escreve
create policy profiles_select on public.profiles for select to authenticated using (public.is_staff());
create policy profiles_insert on public.profiles for insert to authenticated with check (public.is_admin());
create policy profiles_update on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy profiles_delete on public.profiles for delete to authenticated using (public.is_admin());

-- contacts / conversations: equipe lê e escreve
create policy contacts_select on public.contacts for select to authenticated using (public.is_staff());
create policy contacts_insert on public.contacts for insert to authenticated with check (public.is_staff());
create policy contacts_update on public.contacts for update to authenticated using (public.is_staff()) with check (public.is_staff());
create policy contacts_delete on public.contacts for delete to authenticated using (public.is_admin());

create policy conversations_select on public.conversations for select to authenticated using (public.is_staff());
create policy conversations_insert on public.conversations for insert to authenticated with check (public.is_staff());
create policy conversations_update on public.conversations for update to authenticated using (public.is_staff()) with check (public.is_staff());

-- messages / templates_cache: equipe só lê; escrita acontece nas Edge Functions (service role)
create policy messages_select on public.messages for select to authenticated using (public.is_staff());
create policy templates_cache_select on public.templates_cache for select to authenticated using (public.is_staff());

-- Realtime (respeita RLS)
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.conversations;
