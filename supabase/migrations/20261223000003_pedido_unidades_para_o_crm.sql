-- 23/11/2026: o CRM mostra a quantidade do item em pacotes (qty). Esta função devolve as unidades reais de cada item do pedido
-- (mesma regra do checkout: unidades do orçamento ou pacotes x lote), para o painel do pedido exibir "= 5 un.". Só equipe. Aditiva.
create or replace function public.pedido_itens_unidades(p_order uuid) returns table (item_id uuid, unidades integer)
language sql stable security definer set search_path = ''
as $$
  select oi.id, private.checkout_unidades_item(oi.order_id, oi.code, oi.qty)
    from public.order_items oi
   where oi.order_id = p_order and oi.code is not null and private.is_staff()
$$;
revoke all on function public.pedido_itens_unidades(uuid) from public, anon;
grant execute on function public.pedido_itens_unidades(uuid) to authenticated;
