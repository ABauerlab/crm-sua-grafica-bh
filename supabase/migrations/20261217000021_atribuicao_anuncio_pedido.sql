-- Atribuição de anúncio no pedido (bug de 17/11/2026: venda do Marcos, pago, não aparecia em Campanhas).
-- Causa: só o pedido manual do front gravava orders.origin_ad_id; pedidos criados pela Laura, pelo site ou por função
-- ficavam sem origem e ad_performance (que cruza por origin_ad_id) não os via.
-- Correção: (1) gatilho BEFORE INSERT herda a origem do contato (first_referral) em qualquer caminho de criação;
-- (2) backfill dos pedidos existentes; (3) ad_performance ignora teste/excluído e conta o dia em horário de Brasília.
-- Aditiva e idempotente.

create or replace function private.pedido_herdar_origem_anuncio()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ref jsonb;
begin
  if new.origin_ad_id is not null then
    return new;
  end if;
  select c.first_referral into v_ref from public.contacts c where c.id = new.contact_id;
  if v_ref ->> 'source_id' is not null then
    new.origin_ad_id := v_ref ->> 'source_id';
    new.origin_label := coalesce(new.origin_label, v_ref ->> 'headline');
    new.origin_url := coalesce(new.origin_url, v_ref ->> 'source_url');
  end if;
  return new;
exception when others then
  return new; -- atribuição nunca bloqueia a criação do pedido
end;
$$;

revoke all on function private.pedido_herdar_origem_anuncio() from public, anon, authenticated;

drop trigger if exists orders_herdar_origem_anuncio on public.orders;
create trigger orders_herdar_origem_anuncio
  before insert on public.orders
  for each row execute function private.pedido_herdar_origem_anuncio();

-- Backfill: sem disparar os demais gatilhos (Meta Purchase, alertas, histórico) por uma correção de origem.
alter table public.orders disable trigger user;
update public.orders o
   set origin_ad_id = c.first_referral ->> 'source_id',
       origin_label = coalesce(o.origin_label, c.first_referral ->> 'headline'),
       origin_url = coalesce(o.origin_url, c.first_referral ->> 'source_url')
  from public.contacts c
 where c.id = o.contact_id
   and o.origin_ad_id is null
   and c.first_referral ->> 'source_id' is not null;
alter table public.orders enable trigger user;

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
      and coalesce(c.is_teste, false) = false
      and (c.first_referral_at at time zone 'America/Sao_Paulo')::date between p_from and p_to
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
    where o.origin_ad_id is not null
      and coalesce(o.teste, false) = false
      and o.excluido_em is null
      and (o.created_at at time zone 'America/Sao_Paulo')::date between p_from and p_to
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
