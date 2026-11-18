-- Checkout próprio (/pagar/<token>): carregar, dados, arte, expiração e pago. Tudo é desfeito no fim (exception).
-- Esperado: o erro final "OK: ...".
do $$
declare c uuid; oid uuid; tok text; r jsonb; t0 numeric; t1 numeric;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';
  insert into public.contacts (wa_id, name, is_teste) values ('55000099977', 'Teste Checkout', true) returning id into c;
  insert into public.orders (contact_id, title, stage, teste) values (c, 'Teste checkout', 'aguardando_pagamento', true) returning id, checkout_token into oid, tok;
  insert into public.order_items (order_id, code, fora_catalogo, description, qty, unit_cost, unit_price) values (oid, null, true, 'Item de teste', 2, 10, 50);
  if tok !~ '^[0-9a-f]{32}$' then raise exception 'FALHA: token gerado inválido %', tok; end if;

  -- sem link ativo: expirado
  r := public.checkout_carregar(tok);
  if r ->> 'estado' <> 'expirado' then raise exception 'FALHA: sem link deveria estar expirado, veio %', r ->> 'estado'; end if;
  r := public.checkout_carregar('zzzz');
  if (r ->> 'ok')::boolean then raise exception 'FALHA: token inválido aceito'; end if;

  insert into public.pagamentos (order_id, eh_link, link_ativo, link, valor, status, modo, expira_em)
  values (oid, true, true, 'https://suagraficabh.com.br/pagar/' || tok, 100, 'pendente', 'teste', now() + interval '2 days');
  r := public.checkout_carregar(tok);
  if r ->> 'estado' <> 'aberto' or (r ->> 'total')::numeric <> 100 then raise exception 'FALHA: carregar %', r; end if;
  if r::text ~* 'custo|"sku"|fornecedor' then raise exception 'FALHA: dado interno exposto %', r; end if;
  if jsonb_array_length(r -> 'faltando') <> 2 and jsonb_array_length(r -> 'faltando') <> 3 then raise exception 'FALHA: faltando %', r -> 'faltando'; end if;
  if (r #>> '{pagamento,parcelas,1,valor}')::numeric <> 50 then raise exception 'FALHA: parcela 2x %', r -> 'pagamento'; end if;

  -- dados do cliente
  r := public.checkout_salvar_dados(tok, 'Paulo Moreira', 'paulo@exemplo.com', '529.982.247-25');
  if not (r ->> 'ok')::boolean then raise exception 'FALHA: salvar dados %', r; end if;
  if (select document from public.contacts where id = c) <> '52998224725' then raise exception 'FALHA: documento não salvo'; end if;
  r := public.checkout_salvar_dados(tok, 'Paulo', 'sem-arroba', '123');
  if (r ->> 'ok')::boolean then raise exception 'FALHA: dados inválidos aceitos'; end if;
  if jsonb_array_length(public.checkout_carregar(tok) -> 'faltando') <> 0 then raise exception 'FALHA: ainda faltando dados'; end if;

  -- arte: criação soma, trocar para pronta tira
  select total into t0 from public.order_financials where order_id = oid;
  r := public.checkout_definir_arte(tok, 'criacao');
  if not (r ->> 'ok')::boolean or (r ->> 'total')::numeric <= t0 then raise exception 'FALHA: arte criação %', r; end if;
  r := public.checkout_definir_arte(tok, 'conferencia');
  if (select count(*) from public.order_items where order_id = oid and checkout_extra) <> 1 then raise exception 'FALHA: deveria ter 1 linha de arte'; end if;
  r := public.checkout_definir_arte(tok, 'pronta');
  select total into t1 from public.order_financials where order_id = oid;
  if t1 <> t0 then raise exception 'FALHA: arte pronta deveria voltar ao total original (% x %)', t1, t0; end if;
  r := public.checkout_definir_arte(tok, 'xx');
  if (r ->> 'ok')::boolean then raise exception 'FALHA: arte inválida aceita'; end if;

  -- link vencido bloqueia mudanças
  update public.pagamentos set expira_em = now() - interval '1 minute' where order_id = oid;
  if public.checkout_carregar(tok) ->> 'estado' <> 'expirado' then raise exception 'FALHA: vencido'; end if;
  r := public.checkout_definir_arte(tok, 'criacao');
  if r ->> 'erro' <> 'link_expirado' then raise exception 'FALHA: arte em link vencido %', r; end if;

  -- pago
  update public.pagamentos set expira_em = now() + interval '1 day' where order_id = oid;
  update public.orders set payment_status = 'aprovado', paid_at = now(), payment_manual = true where id = oid;
  if public.checkout_carregar(tok) ->> 'estado' <> 'pago' then raise exception 'FALHA: deveria estar pago'; end if;
  if not (public.checkout_status(tok) ->> 'pago')::boolean then raise exception 'FALHA: status pago'; end if;
  r := public.checkout_salvar_dados(tok, 'Paulo Moreira', 'paulo@exemplo.com', '52998224725');
  if r ->> 'erro' <> 'pedido_ja_pago' then raise exception 'FALHA: salvar dados em pedido pago %', r; end if;
  raise exception 'OK: checkout carregar, dados, arte, expiração e pago';
end $$;
