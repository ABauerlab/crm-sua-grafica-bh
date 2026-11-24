-- O botão "Reativar pagamentos pendentes" só cobria quem já tinha link de pagamento
-- (etapa aguardando_pagamento). O dono pediu para cobrir também quem está "cotando"
-- (orçamento já enviado ao cliente, card criado por orcamento_marcar_enviado, mas
-- ainda sem o link de pagamento gerado): aí o template verdadeiro é "o orçamento
-- ficou pronto", não "pagamento pendente". Etapa "novo" continua de fora: lá o
-- orçamento ainda está em rascunho, nunca foi enviado, e não há template de
-- utilidade verdadeiro para reativar sem inventar um fato.
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
  created_at timestamptz,
  dias_aberto int
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
    o.created_at,
    (current_date - o.created_at::date)::int
  from public.orders o
  join public.contacts c on c.id = o.contact_id
  left join public.order_financials f on f.order_id = o.id
  where private.is_staff()
    and o.conversation_id is not null
    and o.excluido_em is null
    and o.cancelado_em is null
    and o.arquivado_em is null
    and o.created_at::date < current_date
    and (
      -- aguardando pagamento: link ativo, ainda sem pagar
      (o.stage = 'aguardando_pagamento' and o.payment_status = 'pendente' and o.payment_link is not null)
      or
      -- cotando: orçamento já enviado (ou vencido) ao cliente, ainda sem link de pagamento
      (o.stage = 'cotando' and exists (
        select 1 from public.orcamentos oc where oc.order_id = o.id and oc.status in ('enviado', 'expirado')
      ))
    )
  order by o.created_at asc;
$$;

revoke all on function public.pagamentos_pendentes_reativar_listar() from public, anon;
grant execute on function public.pagamentos_pendentes_reativar_listar() to authenticated;
