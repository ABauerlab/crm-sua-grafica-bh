-- Duas coisas pedidas pelo dono para o botão "Reativar pagamentos pendentes":
-- 1) também reativar quem está em "Perdido" (reabrindo a conversa).
-- 2) guardar quem já recebeu reativação, para não reenviar e incomodar de novo.

-- Histórico de reativações manuais (qualquer etapa). Cooldown de reenvio é decidido no front
-- (7 dias), lendo a última linha por pedido; aqui só se grava o que foi enviado.
create table if not exists public.reativacoes_enviadas (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  stage text not null,
  canal text not null check (canal in ('template', 'livre')),
  template_name text,
  enviado_por uuid references public.profiles(id),
  enviado_em timestamptz not null default now()
);
create index if not exists reativacoes_enviadas_order_idx on public.reativacoes_enviadas (order_id, enviado_em desc);

alter table public.reativacoes_enviadas enable row level security;

create policy reativacoes_enviadas_select on public.reativacoes_enviadas
  for select to authenticated using (private.is_staff());
create policy reativacoes_enviadas_insert on public.reativacoes_enviadas
  for insert to authenticated with check (private.is_staff());

revoke all on public.reativacoes_enviadas from anon;

-- Lista ampliada: cotando, aguardando_pagamento e agora perdido (reabre a conversa).
-- Perdido só sai por mensagem livre se a janela de 24h ainda estiver aberta (não depende de
-- opt-in); fora da janela, só quem já consentiu em promoção recebe o template retomar_orcamento
-- (mesma regra que a coluna Perdidos do Kanban já previa). Devolve também a última reativação
-- enviada para este pedido, para o front decidir o cooldown e avisar "já reativado".
drop function if exists public.pagamentos_pendentes_reativar_listar();

create or replace function public.pagamentos_pendentes_reativar_listar()
returns table (
  order_id uuid,
  conversation_id uuid,
  number int,
  contact_name text,
  wa_id text,
  stage text,
  title text,
  total numeric,
  payment_link text,
  motivo_perda text,
  marketing_consent text,
  janela_aberta boolean,
  created_at timestamptz,
  dias_aberto int,
  ultima_reativacao_em timestamptz
)
language sql
stable
security invoker
set search_path = public, private
as $$
  select
    o.id,
    o.conversation_id,
    o.number,
    c.name,
    c.wa_id,
    o.stage,
    o.title,
    coalesce(f.total, 0),
    o.payment_link,
    o.motivo_perda,
    c.marketing_consent,
    (
      (conv.last_inbound_at is not null and conv.last_inbound_at + interval '24 hours' > now())
      or (conv.ad_window_until is not null and conv.ad_window_until > now())
    ),
    o.created_at,
    (current_date - o.created_at::date)::int,
    ult.enviado_em
  from public.orders o
  join public.contacts c on c.id = o.contact_id
  join public.conversations conv on conv.id = o.conversation_id
  left join public.order_financials f on f.order_id = o.id
  left join lateral (
    select max(r.enviado_em) as enviado_em from public.reativacoes_enviadas r where r.order_id = o.id
  ) ult on true
  where private.is_staff()
    and o.conversation_id is not null
    and o.excluido_em is null
    and o.cancelado_em is null
    and o.arquivado_em is null
    and o.created_at::date < current_date
    and (
      (o.stage = 'aguardando_pagamento' and o.payment_status = 'pendente' and o.payment_link is not null)
      or
      (o.stage = 'cotando' and exists (
        select 1 from public.orcamentos oc where oc.order_id = o.id and oc.status in ('enviado', 'expirado')
      ))
      or
      (o.stage = 'perdido')
    )
  order by o.created_at asc;
$$;

revoke all on function public.pagamentos_pendentes_reativar_listar() from public, anon;
grant execute on function public.pagamentos_pendentes_reativar_listar() to authenticated;
