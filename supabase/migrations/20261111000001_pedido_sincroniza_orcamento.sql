-- O pedido é a fonte dos itens e do desconto. Esta função copia os itens do pedido para o orçamento ativo
-- ligado a ele (rascunho, enviado ou aceito), para que o PDF gerado depois reflita o pedido.
-- Aditiva e idempotente. Tudo ou nada: se um item não puder entrar no orçamento (sem SKU, fora do catálogo ou
-- abaixo do piso duro), a função recusa e nada é alterado. Pedido pago não é tocado (orçamento deixa de ser ativo).

create or replace function public.pedido_sincronizar_orcamento(p_order uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.orcamentos%rowtype;
  v_sem_sku integer;
  v_itens integer;
  v_bruto numeric;
  v_desc_pct numeric;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;

  select * into o from public.orcamentos
   where order_id = p_order and status in ('rascunho', 'enviado', 'aceito')
   order by criado_em desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'sincronizado', false, 'motivo', 'sem_orcamento_ativo');
  end if;

  select count(*) into v_itens from public.order_items where order_id = p_order;
  if v_itens = 0 then raise exception 'O pedido não tem itens.' using errcode = 'P0001'; end if;

  select count(*) into v_sem_sku from public.order_items where order_id = p_order and (code is null or btrim(code) = '');
  if v_sem_sku > 0 then
    raise exception 'Há % item(ns) sem SKU no pedido. Item manual não entra no orçamento em PDF.', v_sem_sku using errcode = 'P0001';
  end if;

  delete from public.orcamento_itens where orcamento_id = o.id;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario)
  select o.id, oi.code, oi.description, oi.qty, oi.unit_price
    from public.order_items oi
   where oi.order_id = p_order;

  select coalesce(sum(oi.qty * oi.unit_price), 0), coalesce(max(o2.discount_pct), 0)
    into v_bruto, v_desc_pct
    from public.order_items oi join public.orders o2 on o2.id = oi.order_id
   where oi.order_id = p_order;

  -- Desconto do pedido vira desconto do orçamento; a exibição agrupada antiga sai (o PDF volta a listar os itens reais)
  update public.orcamentos
     set desconto_valor = round(v_bruto * v_desc_pct / 100, 2), itens_exibicao = null
   where id = o.id;

  return jsonb_build_object('ok', true, 'sincronizado', true, 'orcamento_id', o.id, 'itens', v_itens);
end;
$$;

revoke execute on function public.pedido_sincronizar_orcamento(uuid) from public, anon;
grant execute on function public.pedido_sincronizar_orcamento(uuid) to authenticated, service_role;
