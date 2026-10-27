-- Parte 1: pedidos (kanban), itens, histórico, arquivos de arte, parâmetros de preço, origem do anúncio (referral)
-- e acesso exclusivo do dono. Aditiva e idempotente. Rollback: ver docs/rollback-parte1.sql.

-- Configurações editáveis (preço, limites por etapa, dono)
create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;

insert into public.app_settings (key, value) values
  ('pricing', '{"floor_multiplier":1.5,"max_discount_pct":10,"min_net_profit":60,"tax_pct":6,"payment_fee_pct":1.5}'),
  ('kanban', '{"stage_limit_hours":{"novo":4,"cotando":8,"aguardando_pagamento":24,"pago":12,"arte":24,"prova":24,"producao":72,"entregue":0,"recompra":0}}'),
  ('owner', '{"email":"contato.bauerlab@gmail.com"}')
on conflict (key) do nothing;

-- Acesso exclusivo do dono: além de existir em profiles, o e-mail do login precisa ser o do dono (quando definido).
create or replace function private.is_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.profiles where id = (select auth.uid()))
    and coalesce(
      lower((select auth.jwt() ->> 'email')) = lower((select value ->> 'email' from public.app_settings where key = 'owner')),
      true
    );
$$;

drop policy if exists app_settings_select on public.app_settings;
create policy app_settings_select on public.app_settings for select to authenticated using (private.is_staff());
drop policy if exists app_settings_insert on public.app_settings;
create policy app_settings_insert on public.app_settings for insert to authenticated with check (private.is_admin());
drop policy if exists app_settings_update on public.app_settings;
create policy app_settings_update on public.app_settings for update to authenticated using (private.is_admin()) with check (private.is_admin());

-- Origem do anúncio (click to WhatsApp): referral enviado pela Meta na primeira mensagem
alter table public.contacts add column if not exists first_referral jsonb;
alter table public.contacts add column if not exists first_referral_at timestamptz;
alter table public.conversations add column if not exists last_referral jsonb;

drop function if exists public.ingest_inbound_message(text, text, text, text, text, text, timestamptz);
create or replace function public.ingest_inbound_message(
  p_wa_id text,
  p_name text,
  p_wa_message_id text,
  p_type text,
  p_body text,
  p_media_id text,
  p_ts timestamptz,
  p_referral jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contact_id uuid;
  v_conv_id uuid;
  v_msg_id uuid;
begin
  insert into public.contacts (wa_id, name, first_referral, first_referral_at)
  values (p_wa_id, nullif(p_name, ''), p_referral, case when p_referral is not null then p_ts end)
  on conflict (wa_id) do update
    set name = coalesce(public.contacts.name, excluded.name),
        first_referral = coalesce(public.contacts.first_referral, excluded.first_referral),
        first_referral_at = coalesce(public.contacts.first_referral_at, excluded.first_referral_at)
  returning id into v_contact_id;

  insert into public.conversations (contact_id)
  values (v_contact_id)
  on conflict (contact_id) do nothing;

  select id into v_conv_id from public.conversations where contact_id = v_contact_id;

  insert into public.messages (conversation_id, wa_message_id, direction, type, body, media_id, created_at)
  values (v_conv_id, p_wa_message_id, 'in', p_type, p_body, p_media_id, p_ts)
  on conflict (wa_message_id) do nothing
  returning id into v_msg_id;

  if v_msg_id is null then
    return null;
  end if;

  update public.conversations
  set status = 'open',
      last_inbound_at = greatest(coalesce(last_inbound_at, p_ts), p_ts),
      last_message_at = greatest(coalesce(last_message_at, p_ts), p_ts),
      last_message_preview = left(coalesce(p_body, ''), 120),
      unread_count = unread_count + 1,
      last_referral = coalesce(p_referral, last_referral)
  where id = v_conv_id;

  return v_msg_id;
end;
$$;

revoke execute on function public.ingest_inbound_message(text, text, text, text, text, text, timestamptz, jsonb)
  from public, anon, authenticated;
grant execute on function public.ingest_inbound_message(text, text, text, text, text, text, timestamptz, jsonb)
  to service_role;

-- Pedidos
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  number bigint generated always as identity,
  contact_id uuid not null references public.contacts (id) on delete cascade,
  conversation_id uuid references public.conversations (id) on delete set null,
  title text not null default 'Novo pedido',
  stage text not null default 'novo'
    check (stage in ('novo', 'cotando', 'aguardando_pagamento', 'pago', 'arte', 'prova', 'producao', 'entregue', 'recompra')),
  stage_entered_at timestamptz not null default now(),
  notes text,
  -- origem
  origin_ad_id text,
  origin_label text,
  origin_url text,
  -- preço
  discount_pct numeric(5, 2) not null default 0 check (discount_pct >= 0 and discount_pct <= 100),
  tax_pct numeric(5, 2) not null default 6 check (tax_pct >= 0 and tax_pct <= 100),
  payment_fee_pct numeric(5, 2) not null default 1.5 check (payment_fee_pct >= 0 and payment_fee_pct <= 100),
  price_override_reason text,
  -- pagamento (campos prontos para o webhook do Mercado Pago)
  payment_status text not null default 'pendente'
    check (payment_status in ('pendente', 'aprovado', 'recusado', 'expirado', 'estornado')),
  payment_method text,
  payment_link text,
  payment_external_id text,
  payment_confirmed_at timestamptz,
  payment_manual boolean not null default false,
  paid_at timestamptz,
  -- arte e prova
  art_mode text check (art_mode in ('cliente', 'criamos')),
  art_status text not null default 'aguardando'
    check (art_status in ('aguardando', 'em_criacao', 'enviada', 'aprovada', 'ajuste')),
  art_approved_at timestamptz,
  art_checklist jsonb not null default '{}'::jsonb,
  -- entrega
  supplier_order_no text,
  due_date date,
  delivery_method text check (delivery_method in ('retirada', 'uber')),
  delivery_address text,
  delivery_fee numeric(12, 2),
  delivery_tracking text,
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists orders_stage_idx on public.orders (stage);
create index if not exists orders_contact_idx on public.orders (contact_id);
create index if not exists orders_created_idx on public.orders (created_at desc);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  code text,
  description text not null,
  qty integer not null default 1 check (qty > 0),
  unit_cost numeric(12, 2) not null default 0 check (unit_cost >= 0),
  unit_price numeric(12, 2) not null default 0 check (unit_price >= 0),
  created_at timestamptz not null default now()
);
create index if not exists order_items_order_idx on public.order_items (order_id);

create table if not exists public.order_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  kind text not null check (kind in ('create', 'stage', 'payment', 'note', 'price', 'art', 'delivery')),
  from_stage text,
  to_stage text,
  message text,
  created_at timestamptz not null default now()
);
create index if not exists order_events_order_idx on public.order_events (order_id, created_at desc);

create table if not exists public.order_files (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  kind text not null check (kind in ('arte', 'prova', 'anexo')),
  version integer not null default 1,
  path text not null,
  filename text not null,
  status text check (status in ('enviada', 'aprovada', 'ajuste')),
  created_at timestamptz not null default now()
);
create index if not exists order_files_order_idx on public.order_files (order_id, created_at desc);

-- Valores calculados no banco (fonte única): total, custo, impostos, taxa e lucro líquido
create or replace view public.order_financials with (security_invoker = true) as
select
  o.id as order_id,
  coalesce(s.gross, 0) as gross,
  round(coalesce(s.gross, 0) * (1 - o.discount_pct / 100), 2) as total,
  coalesce(s.cost, 0) as cost,
  round(coalesce(s.gross, 0) * (1 - o.discount_pct / 100) * o.tax_pct / 100, 2) as tax,
  round(coalesce(s.gross, 0) * (1 - o.discount_pct / 100) * o.payment_fee_pct / 100, 2) as fee,
  round(
    coalesce(s.gross, 0) * (1 - o.discount_pct / 100) * (1 - (o.tax_pct + o.payment_fee_pct) / 100) - coalesce(s.cost, 0),
    2
  ) as net_profit,
  case when coalesce(s.gross, 0) * (1 - o.discount_pct / 100) > 0 then
    round(
      (coalesce(s.gross, 0) * (1 - o.discount_pct / 100) * (1 - (o.tax_pct + o.payment_fee_pct) / 100) - coalesce(s.cost, 0))
      / (coalesce(s.gross, 0) * (1 - o.discount_pct / 100)) * 100,
      1
    )
  else 0 end as margin_pct
from public.orders o
left join (
  select order_id, sum(qty * unit_price) as gross, sum(qty * unit_cost) as cost
  from public.order_items group by order_id
) s on s.order_id = o.id;

-- Regras de transição e histórico
create or replace function private.orders_before_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();

  if new.payment_status = 'aprovado' and old.payment_status is distinct from 'aprovado' then
    new.paid_at := coalesce(new.paid_at, now());
    new.payment_confirmed_at := coalesce(new.payment_confirmed_at, now());
  end if;
  if new.art_status = 'aprovada' and old.art_status is distinct from 'aprovada' then
    new.art_approved_at := coalesce(new.art_approved_at, now());
  end if;

  if new.stage is distinct from old.stage then
    if new.stage = 'pago' and new.payment_status <> 'aprovado' and not new.payment_manual then
      raise exception 'Só é possível mover para Pago com o pagamento confirmado. Confirme o pagamento manualmente se já recebeu.' using errcode = 'P0001';
    end if;
    if new.stage = 'producao' and new.art_status <> 'aprovada' then
      raise exception 'Só é possível mover para Produção com a arte aprovada pelo cliente.' using errcode = 'P0001';
    end if;
    new.stage_entered_at := now();
    if new.stage = 'entregue' and new.delivered_at is null then
      new.delivered_at := now();
    end if;
  end if;
  return new;
end;
$$;

create or replace function private.orders_after_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.order_events (order_id, kind, to_stage, message) values (new.id, 'create', new.stage, 'Pedido criado');
  elsif new.stage is distinct from old.stage then
    insert into public.order_events (order_id, kind, from_stage, to_stage) values (new.id, 'stage', old.stage, new.stage);
  end if;
  if tg_op = 'UPDATE' then
    if new.payment_status is distinct from old.payment_status then
      insert into public.order_events (order_id, kind, message)
      values (new.id, 'payment', 'Pagamento: ' || new.payment_status || case when new.payment_manual then ' (confirmado manualmente)' else '' end);
    end if;
    if new.art_status is distinct from old.art_status then
      insert into public.order_events (order_id, kind, message) values (new.id, 'art', 'Arte: ' || new.art_status);
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function private.orders_before_update() from public, anon, authenticated;
revoke execute on function private.orders_after_write() from public, anon, authenticated;

drop trigger if exists orders_before_update on public.orders;
create trigger orders_before_update before update on public.orders
  for each row execute function private.orders_before_update();
drop trigger if exists orders_after_write on public.orders;
create trigger orders_after_write after insert or update on public.orders
  for each row execute function private.orders_after_write();

-- RLS: só o dono
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_events enable row level security;
alter table public.order_files enable row level security;

do $$
declare t text;
begin
  foreach t in array array['orders', 'order_items', 'order_files'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (private.is_staff())', t || '_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (private.is_staff())', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('create policy %I on public.%I for update to authenticated using (private.is_staff()) with check (private.is_staff())', t || '_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for delete to authenticated using (private.is_staff())', t || '_delete', t);
  end loop;
end $$;

drop policy if exists order_events_select on public.order_events;
create policy order_events_select on public.order_events for select to authenticated using (private.is_staff());
drop policy if exists order_events_insert on public.order_events;
create policy order_events_insert on public.order_events for insert to authenticated with check (private.is_staff());

-- Realtime do kanban
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders') then
    alter publication supabase_realtime add table public.orders;
  end if;
end $$;

-- Armazenamento privado de artes e provas
insert into storage.buckets (id, name, public) values ('order-files', 'order-files', false)
on conflict (id) do nothing;

drop policy if exists order_files_storage_select on storage.objects;
create policy order_files_storage_select on storage.objects for select to authenticated
  using (bucket_id = 'order-files' and private.is_staff());
drop policy if exists order_files_storage_insert on storage.objects;
create policy order_files_storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'order-files' and private.is_staff());
drop policy if exists order_files_storage_delete on storage.objects;
create policy order_files_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'order-files' and private.is_staff());
