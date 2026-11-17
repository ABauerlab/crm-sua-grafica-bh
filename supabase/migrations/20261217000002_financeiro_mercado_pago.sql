-- Financeiro ligado à conta do Mercado Pago: extrato (recebimentos, taxas, estornos) e histórico de saldo,
-- atualizados sozinhos por agendamento (função mp-extrato). Aditiva e idempotente.

create table if not exists public.mp_movimentos (
  mp_payment_id text primary key,
  modo text not null default 'producao',
  tipo text not null default 'recebimento' check (tipo in ('recebimento', 'estorno', 'contestacao', 'pendente', 'recusado')),
  status text not null,
  data timestamptz not null,
  liberacao timestamptz,
  bruto numeric(12, 2) not null default 0,
  taxa numeric(12, 2) not null default 0,
  liquido numeric(12, 2),
  estornado numeric(12, 2) not null default 0,
  metodo text,
  referencia text,
  descricao text,
  order_id uuid references public.orders (id) on delete set null,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists mp_movimentos_data_idx on public.mp_movimentos (data desc);
create index if not exists mp_movimentos_order_idx on public.mp_movimentos (order_id);
alter table public.mp_movimentos enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'mp_movimentos' and policyname = 'mp_movimentos_admin') then
    create policy mp_movimentos_admin on public.mp_movimentos for select to authenticated using (private.is_admin());
  end if;
end $$;

create table if not exists public.mp_saldo_historico (
  id bigint generated always as identity primary key,
  capturado_em timestamptz not null default now(),
  modo text not null default 'producao',
  disponivel numeric(12, 2) not null default 0,
  a_liberar numeric(12, 2) not null default 0,
  total numeric(12, 2) not null default 0
);
create index if not exists mp_saldo_historico_idx on public.mp_saldo_historico (capturado_em desc);
alter table public.mp_saldo_historico enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'mp_saldo_historico' and policyname = 'mp_saldo_admin') then
    create policy mp_saldo_admin on public.mp_saldo_historico for select to authenticated using (private.is_admin());
  end if;
end $$;

-- Totais do período e conferência com os pedidos do CRM (só o dono lê).
create or replace function public.financeiro_mp(p_de date, p_ate date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_de timestamptz := (p_de::timestamp at time zone 'America/Sao_Paulo'); v_ate timestamptz := ((p_ate + 1)::timestamp at time zone 'America/Sao_Paulo'); r jsonb;
begin
  if not private.is_admin() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select jsonb_build_object(
    'recebimentos', count(*) filter (where tipo = 'recebimento'),
    'bruto', coalesce(sum(bruto) filter (where tipo = 'recebimento'), 0),
    'taxas', coalesce(sum(taxa) filter (where tipo = 'recebimento'), 0),
    'liquido', coalesce(sum(coalesce(liquido, bruto - taxa)) filter (where tipo = 'recebimento'), 0),
    'estornos', coalesce(sum(estornado), 0),
    'sem_pedido', count(*) filter (where tipo = 'recebimento' and order_id is null),
    'pendentes', count(*) filter (where tipo = 'pendente'),
    'ultima_atualizacao', max(atualizado_em)
  ) into r from public.mp_movimentos where data >= v_de and data < v_ate;
  return r || jsonb_build_object('saldo', (select to_jsonb(s) - 'id' from public.mp_saldo_historico s order by capturado_em desc limit 1));
end $$;
revoke all on function public.financeiro_mp(date, date) from public, anon;
grant execute on function public.financeiro_mp(date, date) to authenticated, service_role;

-- Vincula movimentos aos pedidos pela referência externa (SG-0523 => pedido 523).
create or replace function public.mp_movimentos_vincular() returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.mp_movimentos m set order_id = o.id
    from public.orders o
   where m.order_id is null and m.referencia ~ '^SG-[0-9]+' and o.number = (regexp_replace(m.referencia, '^SG-([0-9]+).*$', '\1'))::bigint;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.mp_movimentos_vincular() from public, anon;
grant execute on function public.mp_movimentos_vincular() to service_role;

-- Atualização automática a cada 5 minutos (mesmo segredo do Vault usado pelas outras rotinas).
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
do $$
begin
  if exists (select 1 from cron.job where jobname = 'mp-extrato-sync') then perform cron.unschedule('mp-extrato-sync'); end if;
  perform cron.schedule('mp-extrato-sync', '*/5 * * * *', $job$
    select net.http_post(
      url := 'https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/mp-extrato',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)),
      body := '{"dias": 3}'::jsonb);
  $job$);
end $$;
