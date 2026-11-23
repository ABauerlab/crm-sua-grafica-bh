-- Checkout espelha o negociado: lote de 5 un. aparece como 5 un. (não 1), sem mudar subtotal nem total. Tudo é desfeito (exception).
-- Esperado: o erro final "OK: ...".
do $$
declare c uuid; oid uuid; oc uuid; tok text; r jsonb; v_sku text; v_lote integer; v_preco numeric; it jsonb;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';
  select sku, quantidade, preco_venda into v_sku, v_lote, v_preco from public.catalogo where active and vendavel and preco_venda is not null and quantidade > 1 limit 1;
  insert into public.contacts (wa_id, name, is_teste) values ('55000099966', 'Teste Unidades', true) returning id into c;
  insert into public.orders (contact_id, title, stage, teste) values (c, 'Teste unidades', 'aguardando_pagamento', true) returning id, checkout_token into oid, tok;
  insert into public.order_items (order_id, code, fora_catalogo, description, qty, unit_cost, unit_price) values (oid, v_sku, false, 'Produto em lote', 1, 10, v_preco);
  insert into public.pagamentos (order_id, eh_link, link_ativo, link, valor, status, modo, expira_em)
  values (oid, true, true, 'https://suagraficabh.com.br/pagar/' || tok, v_preco, 'pendente', 'teste', now() + interval '2 days');

  -- sem orçamento: unidades = pacotes x lote do catálogo
  r := public.checkout_carregar(tok);
  it := r -> 'itens' -> 0;
  if (it ->> 'unidades')::integer <> v_lote then raise exception 'FALHA: esperava % un., veio %', v_lote, it ->> 'unidades'; end if;
  if (it ->> 'subtotal')::numeric <> v_preco then raise exception 'FALHA: subtotal mudou'; end if;

  -- com orçamento: vale o que o cliente pediu (3 un. dentro do lote)
  insert into public.orcamentos (contact_id, order_id, status, teste) values (c, oid, 'enviado', true) returning id into oc;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, unidades_cliente) values (oc, v_sku, 'Produto em lote', 1, v_preco, 3);
  r := public.checkout_carregar(tok);
  if (r -> 'itens' -> 0 ->> 'unidades')::integer <> 3 then raise exception 'FALHA: esperava 3 un. do orçamento, veio %', r -> 'itens' -> 0 ->> 'unidades'; end if;
  if (r ->> 'total')::numeric <> v_preco then raise exception 'FALHA: total mudou'; end if;
  raise exception 'OK: checkout mostra as unidades do cliente e não mexe nos valores';
end $$;
