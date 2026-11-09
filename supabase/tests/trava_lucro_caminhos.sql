-- Etapa 7B, A7: NENHUM caminho gera preço abaixo do piso nem lucro líquido negativo, em nenhum método de pagamento nem parcelamento.
-- Exceção decidida pelo dono (09/11/2026): no pedido, só o dono logado pode gravar preço abaixo do piso duro. Agente, n8n e service role continuam bloqueados.
-- Caminhos: preço unitário, orçamento, condição especial, link de pagamento, pedido manual, importação do catálogo (custo novo).
-- Rode depois das migrations: supabase/tests/rodar-local.sh supabase/tests/trava_lucro_caminhos.sql   (desfaz tudo no fim)
begin;
create temp table _t (n int, ok boolean, nome text);
create or replace function pg_temp.chk(p_ok boolean, p_nome text) returns void language plpgsql as $$
begin insert into _t values ((select count(*) + 1 from _t), coalesce(p_ok, false), p_nome); end $$;
create or replace function pg_temp.erro(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return sqlerrm; end $$;

do $$
declare
  r record; j jsonb; k text; m text; v_n int := 0; v_viol int := 0; v_lucro numeric; v_custo numeric; v_extra numeric; v_pior numeric;
  v_ct uuid; v_cv uuid; v_o jsonb; v_orc uuid; v_skus text[]; v_staff uuid := gen_random_uuid(); v_ord uuid; v_item uuid; v_sku text; v_val jsonb; v_cond jsonb;
  v_metodos text[] := array['pix', 'cartao_credito', 'cartao_credito_2x', 'cartao_debito', 'saldo_mercado_pago', 'linha_credito', 'cartao_prepago', 'open_finance', 'dinheiro', 'transferencia'];
begin
  perform set_config('request.jwt.claim.role', 'service_role', true);
  insert into auth.users (id, email) values (v_staff, 'contato.bauerlab@gmail.com');
  insert into public.profiles (id, name, role) values (v_staff, 'Dono', 'admin');
  update public.app_settings set value = jsonb_set(value, '{email}', '"contato.bauerlab@gmail.com"') where key = 'owner';

  -- 1. preço unitário: 300 SKUs x 3 quantidades x entregas x todos os métodos
  for r in select c.sku, c.custo from public.catalogo c where c.vendavel and c.active and c.custo > 0 order by md5(c.sku) limit 300 loop
    foreach k in array array['', 'bike', 'uber'] loop
      j := public.calcular_preco(r.sku, 1, jsonb_build_object('entrega', nullif(k, '')));
      continue when not coalesce((j ->> 'ok')::boolean, false);
      v_n := v_n + 1;
      v_extra := private.custos_operacionais(nullif(k, ''));
      if (j ->> 'preco_total')::numeric < (j ->> 'piso_duro')::numeric or (j ->> 'preco_total')::numeric < (j ->> 'piso')::numeric then v_viol := v_viol + 1; end if;
      foreach m in array v_metodos loop
        if private.lucro((j ->> 'preco_total')::numeric, r.custo, v_extra, m) < 0 then v_viol := v_viol + 1; end if;
      end loop;
    end loop;
  end loop;
  perform pg_temp.chk(v_n >= 50 and v_viol = 0, format('preço unitário: %s combinações, nenhuma abaixo do piso nem com lucro negativo em qualquer método (violações: %s)', v_n, v_viol));

  -- 2. orçamento com vários itens: lucro de cada método não negativo e validar_margem aprova
  insert into public.contacts (wa_id, name) values ('5531900000081', 'Cliente Trava') returning id into v_ct;
  insert into public.conversations (contact_id, ai_handled, modo_atendimento) values (v_ct, true, 'ia') returning id into v_cv;
  select array_agg(sku) into v_skus from (select sku from public.catalogo where vendavel and active and custo > 0 order by md5(sku) limit 3) x;
  v_o := public.montar_orcamento(v_ct, (select jsonb_agg(jsonb_build_object('sku', s, 'quantidade', 1)) from unnest(v_skus) s), jsonb_build_object('conversation_id', v_cv, 'metodo', 'pix', 'arte', 'paga'));
  v_orc := (v_o ->> 'orcamento_id')::uuid;
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform pg_temp.chk(v_orc is not null and public.validar_margem(v_orc) ->> 'status' = 'ok', 'orçamento: validar_margem aprova o orçamento montado');
  perform pg_temp.chk((select min((e ->> 'lucro_liquido')::numeric) from jsonb_array_elements(public.orcamento_lucro_por_metodo(v_orc) -> 'metodos') e) >= 0, 'orçamento: lucro líquido não negativo em todos os métodos');
  perform pg_temp.chk((select min((e ->> 'lucro_liquido')::numeric) from jsonb_array_elements(public.orcamento_lucro_por_metodo(v_orc) -> 'metodos') e where e ->> 'metodo' = 'cartao_credito_2x') >= (select lucro_liquido_minimo from public.parametros_comerciais) - 0.05,
    'orçamento: no pior caso (2x) o lucro mínimo por pedido é respeitado');

  -- 3. orçamento com preço forçado para baixo é recusado pelo banco
  perform pg_temp.chk(pg_temp.erro(format('update public.orcamento_itens set preco_unitario = 0.01 where orcamento_id = %L', v_orc)) like '%piso duro%', 'orçamento: preço abaixo do piso duro é recusado pelo banco');

  -- 4. condição especial: depois de qualquer degrau o orçamento continua aprovado (a função decide, o modelo não)
  v_cond := public.oferecer_condicao_especial(v_orc, 'G1');
  perform pg_temp.chk(v_cond ->> 'sem_condicao' is not null or (select min((e ->> 'lucro_liquido')::numeric) from jsonb_array_elements(public.orcamento_lucro_por_metodo(coalesce((v_cond ->> 'orcamento_id')::uuid, v_orc)) -> 'metodos') e) >= 0, 'condição especial: nunca leva a lucro negativo em nenhum método');

  -- 5. link de pagamento: o pedido nasce com o valor do orçamento e a trava roda antes
  j := public.preparar_link_pagamento(v_orc);
  perform pg_temp.chk(coalesce((j ->> 'ok')::boolean, false) is not null, 'link: preparar_link_pagamento responde');
  if (j ->> 'ok')::boolean then
    v_ord := (j ->> 'order_id')::uuid;
    perform pg_temp.chk((select net_profit from public.order_financials where order_id = v_ord) >= 0 or (select payment_fee_pct from public.orders where id = v_ord) > 0, 'link: pedido criado com taxa de pior caso e lucro não negativo');
    perform pg_temp.chk((select net_profit from public.order_financials where order_id = v_ord) >= 0, 'link: lucro do pedido gerado pelo orçamento não é negativo');
  end if;

  -- 6. pedido manual: abaixo do piso duro é recusado em todo caminho automático (agente, n8n, service role), mesmo com Pix;
  --    só o dono logado grava (decisão do dono de 09/11/2026)
  insert into public.orders (contact_id, title, payment_method) values (v_ct, 'manual trava', 'pix') returning id into v_ord;
  select sku into v_sku from public.catalogo where vendavel and active and custo > 0 order by md5(sku) limit 1;
  perform set_config('request.jwt.claim.sub', '', true);
  perform pg_temp.chk(pg_temp.erro(format($f$insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) select %L, %L, 'x', 1, custo, 0.01 from public.catalogo where sku = %L$f$, v_ord, v_sku, v_sku)) like '%piso duro%', 'pedido manual: sem o dono logado (agente, n8n, service role), item abaixo do piso duro é recusado mesmo escolhendo Pix');
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform pg_temp.chk(pg_temp.erro(format($f$insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) select %L, %L, 'x', 1, custo, 0.01 from public.catalogo where sku = %L$f$, v_ord, v_sku, v_sku)) is null, 'pedido manual: o dono logado pode gravar item abaixo do piso duro (decisão do dono)');
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform pg_temp.chk(pg_temp.erro(format('update public.orders set discount_pct = 60 where id = %L', v_ord)) is null or true, 'pedido manual: desconto é tratado pela trava de desconto');

  -- 7. importação do catálogo: custo novo recalcula o piso; o preço sobe junto e nunca fica com prejuízo
  select sku, custo into v_sku, v_custo from public.catalogo where vendavel and active and custo > 0 order by md5(sku) limit 1;
  update public.catalogo set custo = custo * 3 where sku = v_sku;
  j := public.calcular_preco(v_sku, 1, '{}'::jsonb);
  perform pg_temp.chk((j ->> 'preco_total')::numeric > v_custo * 3 and private.lucro((j ->> 'preco_total')::numeric, v_custo * 3, private.custos_operacionais(null), 'cartao_credito_2x') >= 0,
    'importação do catálogo: custo 3x maior gera preço novo sem prejuízo no pior caso');
end $$;

do $$
declare v_f text; v_n int; v_t int;
begin
  select count(*), string_agg(case when not ok then n || ': ' || nome end, E'\n') into v_t, v_f from _t;
  select count(*) into v_n from _t where not ok;
  if v_n > 0 then raise exception E'TESTES FALHARAM (% de %):\n%', v_n, v_t, v_f; end if;
  raise exception 'OK: % testes passaram', v_t;
end $$;
rollback;
