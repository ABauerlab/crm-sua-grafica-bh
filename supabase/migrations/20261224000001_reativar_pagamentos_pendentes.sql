-- Lista os pedidos com pagamento pendente (link ativo, sem pagamento), para o botão
-- "Reativar pagamentos pendentes" no Kanban. Exclui pedidos orçados hoje (ainda dentro
-- do prazo normal de resposta do cliente) e pedidos excluídos, cancelados ou arquivados.
create or replace function public.pagamentos_pendentes_reativar_listar()
returns table (
  order_id uuid,
  conversation_id uuid,
  number int,
  contact_name text,
  wa_id text,
  payment_link text,
  created_at timestamptz,
  dias_aberto int
)
language sql
stable
security invoker
as $$
  select
    o.id,
    o.conversation_id,
    o.number,
    c.name,
    c.wa_id,
    o.payment_link,
    o.created_at,
    (current_date - o.created_at::date)::int
  from public.orders o
  join public.contacts c on c.id = o.contact_id
  where private.is_staff()
    and o.stage = 'aguardando_pagamento'
    and o.payment_status = 'pendente'
    and o.payment_link is not null
    and o.conversation_id is not null
    and o.excluido_em is null
    and o.cancelado_em is null
    and o.arquivado_em is null
    and o.created_at::date < current_date
  order by o.created_at asc;
$$;

alter function public.pagamentos_pendentes_reativar_listar() set search_path = public, private;

revoke all on function public.pagamentos_pendentes_reativar_listar() from public, anon;
grant execute on function public.pagamentos_pendentes_reativar_listar() to authenticated;
