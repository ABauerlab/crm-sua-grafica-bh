-- Situação do orçamento em relação ao pedido: 'sem_orcamento' | 'atualizado' | 'desatualizado'.
-- Compara os itens (SKU, descrição, quantidade, preço e custo) e o desconto do pedido com o orçamento ativo.
-- Aditiva e idempotente. Só leitura: não altera nada.
create or replace function public.pedido_orcamento_situacao(p_order uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  o public.orcamentos%rowtype;
  v_desc_pct numeric;
  v_bruto numeric;
  v_diff integer;
  v_desc_esperado numeric;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;

  select * into o from public.orcamentos
   where order_id = p_order and status in ('rascunho', 'enviado', 'aceito')
   order by criado_em desc limit 1;
  if not found then
    return jsonb_build_object('situacao', 'sem_orcamento');
  end if;

  select coalesce(max(discount_pct), 0) into v_desc_pct from public.orders where id = p_order;
  select coalesce(sum(qty * unit_price), 0) into v_bruto from public.order_items where order_id = p_order;
  v_desc_esperado := round(v_bruto * v_desc_pct / 100, 2);

  -- Diferença nos dois sentidos, como multiconjunto: qualquer item a mais, a menos ou alterado conta.
  select count(*) into v_diff from (
    (select nullif(btrim(oi.code), '') as sku, oi.description, oi.qty, oi.unit_price, oi.unit_cost
       from public.order_items oi where oi.order_id = p_order
     except all
     select i.sku, i.descricao, i.quantidade, i.preco_unitario, i.custo_unitario
       from public.orcamento_itens i where i.orcamento_id = o.id)
    union all
    (select i.sku, i.descricao, i.quantidade, i.preco_unitario, i.custo_unitario
       from public.orcamento_itens i where i.orcamento_id = o.id
     except all
     select nullif(btrim(oi.code), ''), oi.description, oi.qty, oi.unit_price, oi.unit_cost
       from public.order_items oi where oi.order_id = p_order)
  ) x;

  return jsonb_build_object(
    'situacao', case when v_diff = 0 and o.desconto_valor = v_desc_esperado then 'atualizado' else 'desatualizado' end,
    'orcamento_id', o.id,
    'numero', o.numero,
    'status', o.status,
    'itens_divergentes', v_diff,
    'desconto_divergente', o.desconto_valor <> v_desc_esperado
  );
end;
$$;

revoke execute on function public.pedido_orcamento_situacao(uuid) from public, anon;
grant execute on function public.pedido_orcamento_situacao(uuid) to authenticated, service_role;
