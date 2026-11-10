-- Pedido do site com arte própria (pronta ou conferência) só é cobrado depois que o PDF foi anexado (a trava agora é do servidor).
create or replace function public.validar_antes_de_cobrar(p_order uuid)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_pay text; v_total numeric; v_orc uuid; v_val jsonb;
begin
  select payment_status into v_pay from public.orders where id = p_order;
  if not found then return 'Pedido não encontrado.'; end if;
  if v_pay = 'aprovado' then return 'Este pedido já está pago.'; end if;
  select total into v_total from public.order_financials where order_id = p_order;
  if coalesce(v_total, 0) <= 0 then return 'O pedido precisa ter itens e valor maior que zero para gerar o link.'; end if;
  if exists (select 1 from public.orders o where o.id = p_order and o.origin_label = 'site' and o.art_status = 'aguardando')
     and not exists (select 1 from public.order_files f where f.order_id = p_order and f.kind = 'arte')
     and not exists (select 1 from public.order_items i where i.order_id = p_order and i.description = 'Criação de arte') then
    return 'Anexe o PDF da arte em alta qualidade para continuar.';
  end if;
  select o.id into v_orc from public.orcamentos o where o.order_id = p_order and o.status in ('rascunho', 'enviado', 'aceito') order by o.criado_em desc limit 1;
  if v_orc is not null then
    v_val := public.validar_margem(v_orc);
    if v_val ->> 'status' <> 'ok' then return 'Orçamento recusado pela trava de lucro (' || coalesce(v_val ->> 'motivo', 'prejuízo') || ').'; end if;
  end if;
  return null;
end;
$$;
