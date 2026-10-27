-- Parte 2: conversas com IA/humano, contatos completos, catálogo e kits, campanhas, tarefas e preparação do agente.
-- Aditiva e idempotente (sem drop). Rollback: docs/rollback-parte2.sql.

create extension if not exists pg_trgm with schema extensions;

-- Conversas: IA x humano, atenção, resumo, dados coletados, etiquetas e janela de anúncio (72 h)
alter table public.conversations add column if not exists attendant_changed_at timestamptz;
alter table public.conversations add column if not exists attendant_change_reason text;
alter table public.conversations add column if not exists needs_human boolean not null default false;
alter table public.conversations add column if not exists summary text;
alter table public.conversations add column if not exists collected_data jsonb not null default '{}'::jsonb;
alter table public.conversations add column if not exists labels text[] not null default '{}';
alter table public.conversations add column if not exists ad_window_until timestamptz;

-- Contatos: perfil completo
alter table public.contacts add column if not exists email text;
alter table public.contacts add column if not exists document text;
alter table public.contacts add column if not exists company text;
alter table public.contacts add column if not exists segment text check (segment in ('barbearia', 'delivery', 'loja', 'outro'));
alter table public.contacts add column if not exists address text;

-- Janela de anúncio: clique em anúncio abre 72 h para responder
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
      last_referral = coalesce(p_referral, last_referral),
      ad_window_until = case when p_referral is not null then greatest(coalesce(ad_window_until, p_ts), p_ts + interval '72 hours') else ad_window_until end
  where id = v_conv_id;

  return v_msg_id;
end;
$$;

-- Notas internas (invisíveis ao cliente)
create table if not exists public.conversation_notes (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now()
);
create index if not exists conversation_notes_conv_idx on public.conversation_notes (conversation_id, created_at);

-- Respostas rápidas (atalho "/")
create table if not exists public.quick_replies (
  id uuid primary key default gen_random_uuid(),
  shortcut text not null unique check (shortcut ~ '^[a-z0-9_-]+$'),
  title text not null,
  body text not null,
  created_at timestamptz not null default now()
);

-- Tarefas e follow-up
create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  due_at timestamptz,
  priority text not null default 'media' check (priority in ('baixa', 'media', 'alta')),
  contact_id uuid references public.contacts (id) on delete cascade,
  order_id uuid references public.orders (id) on delete cascade,
  kind text check (kind in ('cobrar_pagamento', 'aprovar_prova', 'avisar_entrega', 'recompra')),
  done_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists tasks_due_idx on public.tasks (due_at) where done_at is null;
create index if not exists tasks_contact_idx on public.tasks (contact_id);
create index if not exists tasks_order_idx on public.tasks (order_id);
create index if not exists orders_conversation_idx on public.orders (conversation_id);

-- Catálogo do fornecedor e kits
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  description text not null,
  category text,
  supplier text not null default 'Fornecedor',
  cost numeric(12, 2) not null default 0 check (cost >= 0),
  suggested_price numeric(12, 2) not null default 0 check (suggested_price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists products_description_trgm on public.products using gin (description extensions.gin_trgm_ops);
create index if not exists products_category_idx on public.products (category);

create table if not exists public.kits (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  segment text check (segment in ('barbearia', 'delivery', 'loja', 'lancamento', 'outro')),
  description text,
  price numeric(12, 2) not null default 0 check (price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.kit_items (
  id uuid primary key default gen_random_uuid(),
  kit_id uuid not null references public.kits (id) on delete cascade,
  product_id uuid references public.products (id) on delete set null,
  description text not null,
  qty integer not null default 1 check (qty > 0),
  unit_cost numeric(12, 2) not null default 0 check (unit_cost >= 0)
);
create index if not exists kit_items_kit_idx on public.kit_items (kit_id);
create index if not exists kit_items_product_idx on public.kit_items (product_id);

-- Campanhas (Meta Ads): estrutura, gasto diário e gasto manual
create table if not exists public.ad_entities (
  ad_id text primary key,
  ad_name text,
  adset_id text,
  adset_name text,
  campaign_id text,
  campaign_name text,
  status text,
  updated_at timestamptz not null default now()
);

create table if not exists public.ad_daily (
  ad_id text not null,
  day date not null,
  spend numeric(12, 2) not null default 0,
  impressions integer not null default 0,
  clicks integer not null default 0,
  meta_conversations integer not null default 0,
  primary key (ad_id, day)
);
create index if not exists ad_daily_day_idx on public.ad_daily (day);

create table if not exists public.ad_manual_spend (
  id uuid primary key default gen_random_uuid(),
  day date not null default current_date,
  campaign_name text not null,
  amount numeric(12, 2) not null check (amount >= 0),
  note text,
  created_at timestamptz not null default now()
);

-- Agente de IA: log de ações
create table if not exists public.agent_logs (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.conversations (id) on delete set null,
  actor text not null default 'ia' check (actor in ('ia', 'humano', 'sistema')),
  action text not null,
  detail jsonb not null default '{}'::jsonb,
  result text,
  created_at timestamptz not null default now()
);
create index if not exists agent_logs_created_idx on public.agent_logs (created_at desc);
create index if not exists agent_logs_conv_idx on public.agent_logs (conversation_id);

-- Configurações novas
insert into public.app_settings (key, value) values
  ('agent', '{"enabled":false,"hours":{"start":"08:00","end":"18:00","days":[1,2,3,4,5]},"handoff_message":"Vou chamar um atendente para te ajudar. Um instante!"}'),
  ('company', '{"name":"Sua Gráfica BH","legal_name":"58.481.181 JOAO VICTOR BAUER ROCHA GOMES","cnpj":"58.481.181/0001-03","address":"Rua Rio de Janeiro, 462, Salas 2216/2217, Centro, Belo Horizonte/MG","email":"contato@suagraficabh.com.br","phone":"(31) 97561-8243","hours":"Seg a sex, 8h às 18h"}'),
  ('labels', '["dúvida","orçamento","reclamação","arte","recompra"]'),
  ('campaign_goals', '{"max_cost_per_conversation":6,"max_cost_per_sale":60,"min_roas":4}'),
  ('repurchase', '{"days":45}')
on conflict (key) do nothing;

-- Estatísticas por contato (LTV, lucro, última compra)
create or replace view public.contact_stats with (security_invoker = true) as
select
  c.id as contact_id,
  count(o.id) as orders_count,
  count(o.id) filter (where o.payment_status = 'aprovado' or o.payment_manual) as paid_orders,
  coalesce(sum(f.total) filter (where o.payment_status = 'aprovado' or o.payment_manual), 0) as ltv,
  coalesce(sum(f.net_profit) filter (where o.payment_status = 'aprovado' or o.payment_manual), 0) as profit,
  max(o.paid_at) as last_order_at
from public.contacts c
left join public.orders o on o.contact_id = c.id
left join public.order_financials f on f.order_id = o.id
group by c.id;

-- Preço sugerido, piso, desconto máximo e lucro estimado: tudo calculado no banco com os parâmetros de preço
create or replace view public.products_priced with (security_invoker = true) as
select
  p.*,
  round(p.cost * coalesce((select (value ->> 'floor_multiplier')::numeric from public.app_settings where key = 'pricing'), 1.5), 2) as floor_price,
  round(p.suggested_price * (1 - coalesce((select (value ->> 'max_discount_pct')::numeric from public.app_settings where key = 'pricing'), 10) / 100), 2) as max_discount_price,
  round(
    p.suggested_price * (1 - (
      coalesce((select (value ->> 'tax_pct')::numeric from public.app_settings where key = 'pricing'), 6)
      + coalesce((select (value ->> 'payment_fee_pct')::numeric from public.app_settings where key = 'pricing'), 1.5)
    ) / 100) - p.cost,
    2
  ) as est_net_profit
from public.products p;

-- Desempenho por anúncio no período: gasto (Meta + manual não entra por anúncio), conversas, orçamentos, vendas, faturamento e lucro
create or replace function public.ad_performance(p_from date, p_to date)
returns table (
  ad_id text,
  ad_name text,
  adset_id text,
  adset_name text,
  campaign_id text,
  campaign_name text,
  spend numeric,
  impressions bigint,
  clicks bigint,
  meta_conversations bigint,
  conversations bigint,
  quotes bigint,
  paid_orders bigint,
  revenue numeric,
  net_profit numeric
)
language sql
stable
security invoker
set search_path = ''
as $$
  with spend as (
    select d.ad_id, sum(d.spend) as spend, sum(d.impressions) as impressions, sum(d.clicks) as clicks, sum(d.meta_conversations) as meta_conversations
    from public.ad_daily d
    where d.day between p_from and p_to
    group by d.ad_id
  ),
  convs as (
    select c.first_referral ->> 'source_id' as ad_id, count(*) as conversations
    from public.contacts c
    where c.first_referral ->> 'source_id' is not null
      and c.first_referral_at::date between p_from and p_to
    group by 1
  ),
  ords as (
    select o.origin_ad_id as ad_id,
      count(*) filter (where exists (select 1 from public.order_items i where i.order_id = o.id)) as quotes,
      count(*) filter (where o.payment_status = 'aprovado' or o.payment_manual) as paid_orders,
      coalesce(sum(f.total) filter (where o.payment_status = 'aprovado' or o.payment_manual), 0) as revenue,
      coalesce(sum(f.net_profit) filter (where o.payment_status = 'aprovado' or o.payment_manual), 0) as net_profit
    from public.orders o
    join public.order_financials f on f.order_id = o.id
    where o.origin_ad_id is not null and o.created_at::date between p_from and p_to
    group by 1
  ),
  ids as (
    select ad_id from spend union select ad_id from convs union select ad_id from ords
  )
  select
    i.ad_id,
    e.ad_name,
    e.adset_id,
    e.adset_name,
    e.campaign_id,
    e.campaign_name,
    coalesce(s.spend, 0),
    coalesce(s.impressions, 0)::bigint,
    coalesce(s.clicks, 0)::bigint,
    coalesce(s.meta_conversations, 0)::bigint,
    coalesce(cv.conversations, 0)::bigint,
    coalesce(o.quotes, 0)::bigint,
    coalesce(o.paid_orders, 0)::bigint,
    coalesce(o.revenue, 0),
    coalesce(o.net_profit, 0)
  from ids i
  left join public.ad_entities e on e.ad_id = i.ad_id
  left join spend s on s.ad_id = i.ad_id
  left join convs cv on cv.ad_id = i.ad_id
  left join ords o on o.ad_id = i.ad_id
  order by coalesce(s.spend, 0) desc, i.ad_id;
$$;

-- RLS: só o dono, em todas as tabelas novas
do $$
declare t text;
begin
  foreach t in array array['conversation_notes', 'quick_replies', 'tasks', 'products', 'kits', 'kit_items', 'ad_entities', 'ad_daily', 'ad_manual_spend', 'agent_logs'] loop
    execute format('alter table public.%I enable row level security', t);
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

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'conversation_notes') then
    alter publication supabase_realtime add table public.conversation_notes;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_settings') then
    alter publication supabase_realtime add table public.app_settings;
  end if;
end $$;
