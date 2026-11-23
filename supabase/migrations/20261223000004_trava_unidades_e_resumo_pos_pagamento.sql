-- 23/11/2026: (1) as unidades do orçamento só valem enquanto o pedido ainda tem a mesma quantidade de pacotes do orçamento
-- (editou no painel: volta para pacotes x lote); (2) trava no link de pagamento: se o pedido tem o SKU com quantidade diferente
-- da do orçamento, o link NÃO sai (o chamador chama o dono, como no caso de valor diferente); (3) a confirmação pós-pagamento
-- recebe o resumo dos itens com unidades reais (só no texto livre; o template aprovado na Meta não muda). Aditiva e idempotente.

create or replace function private.checkout_unidades_item(p_order uuid, p_code text, p_qty integer) returns integer
language plpgsql stable security definer set search_path = ''
as $$
declare v_n integer; v_u integer; v_q integer; v_orc uuid; v_lote integer;
begin
  if p_code is null then return null; end if;
  select count(*) into v_n from public.order_items where order_id = p_order and code = p_code;
  if v_n = 1 then
    select id into v_orc from public.orcamentos where order_id = p_order order by criado_em desc limit 1;
    if v_orc is not null then
      select sum(unidades_cliente)::integer, sum(quantidade)::integer into v_u, v_q
        from public.orcamento_itens where orcamento_id = v_orc and sku = p_code and unidades_cliente > 0;
      if v_u > 0 and v_q = p_qty then return v_u; end if;
    end if;
  end if;
  select coalesce(quantidade, 1) into v_lote from public.catalogo where sku = p_code;
  return greatest(coalesce(p_qty, 1), 1) * greatest(coalesce(v_lote, 1), 1);
end;
$$;
revoke all on function private.checkout_unidades_item(uuid, text, integer) from public, anon, authenticated;

-- Trava do link: pedido x orçamento (quantidade por SKU)
do $m$
begin
  if to_regprocedure('public.preparar_link_pagamento_pre_unidades(uuid)') is null then
    alter function public.preparar_link_pagamento(uuid) rename to preparar_link_pagamento_pre_unidades;
  end if;
end $m$;
revoke all on function public.preparar_link_pagamento_pre_unidades(uuid) from public, anon, authenticated;
grant execute on function public.preparar_link_pagamento_pre_unidades(uuid) to service_role;

create or replace function public.preparar_link_pagamento(p_orcamento uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r jsonb; v_dif record;
begin
  r := public.preparar_link_pagamento_pre_unidades(p_orcamento);
  if not coalesce((r ->> 'ok')::boolean, false) or (r ->> 'order_id') is null then return r; end if;
  select q.sku, q.qq, p.pq into v_dif
    from (select i.sku, sum(i.quantidade) qq from public.orcamento_itens i where i.orcamento_id = p_orcamento and i.sku is not null group by i.sku) q
    join (select code, sum(qty) pq from public.order_items where order_id = (r ->> 'order_id')::uuid and code is not null group by code) p on p.code = q.sku
   where p.pq <> q.qq limit 1;
  if found then
    return jsonb_build_object('ok', false, 'motivo', 'quantidade_do_pedido_diferente_do_orcamento',
      'alternativa', 'Não envie o link. Chame o dono para conferir a quantidade do pedido.');
  end if;
  return r;
end;
$$;
revoke all on function public.preparar_link_pagamento(uuid) from public, anon, authenticated;
grant execute on function public.preparar_link_pagamento(uuid) to service_role;

-- Resumo dos itens na confirmação pós-pagamento (até 3, sem SKU nem custo)
create or replace function public.pagamento_pos_reservar_msg(p_order uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  pos public.pagamento_pos%rowtype; o public.orders%rowtype; c public.contacts%rowtype; cv public.conversations%rowtype; v_ref text; v_itens jsonb;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.pagamento_pos set msg_status = 'enviando', msg_inicio_em = now(), msg_tentativas = msg_tentativas + 1
   where order_id = p_order and banco_ok and msg_tentativas < 3
     and (msg_status in ('pendente', 'falhou_temp') or (msg_status = 'enviando' and msg_inicio_em < now() - interval '5 minutes'))
  returning * into pos;
  if not found then
    select * into pos from public.pagamento_pos where order_id = p_order;
    return jsonb_build_object('ok', true, 'enviar', false, 'msg_status', pos.msg_status);
  end if;
  select * into o from public.orders where id = p_order;
  select * into c from public.contacts where id = o.contact_id;
  select * into cv from public.conversations where id = o.conversation_id;
  v_ref := 'SG-' || lpad(o.number::text, 4, '0');
  select coalesce(jsonb_agg(jsonb_build_object('descricao', x.description, 'unidades', x.u) order by x.created_at), '[]'::jsonb) into v_itens
    from (select oi.description, oi.created_at, private.checkout_unidades_item(oi.order_id, oi.code, oi.qty) u
            from public.order_items oi where oi.order_id = p_order and oi.code is not null and oi.description !~* '^frete' order by oi.created_at limit 3) x;
  return jsonb_build_object('ok', true, 'enviar', true, 'tentativa', pos.msg_tentativas,
    'wa_id', c.wa_id, 'conversation_id', cv.id, 'nome', private.fu_nome(c.name),
    'pedido', v_ref, 'previsao', coalesce(to_char(o.due_date, 'DD/MM'), 'a confirmar'), 'itens', v_itens,
    'arte_status', o.art_status, 'entrega', o.delivery_method,
    'janela_ate', greatest(cv.last_inbound_at + interval '24 hours', coalesce(cv.ad_window_until, 'epoch'::timestamptz)));
end;
$$;
revoke execute on function public.pagamento_pos_reservar_msg(uuid) from public, anon, authenticated;
grant execute on function public.pagamento_pos_reservar_msg(uuid) to service_role;
