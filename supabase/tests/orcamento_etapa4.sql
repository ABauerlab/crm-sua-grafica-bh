-- Testes da Etapa 4: montar_orcamento, documento do PDF, orçamento vencido, link de pagamento e lucro real do pedido.
-- Um único bloco que se desfaz no final. Como rodar: supabase/tests/rodar-local.sh supabase/tests/orcamento_etapa4.sql
-- O resultado aparece como mensagem de erro: "OK: N testes passaram" = tudo certo; "TESTES FALHARAM" = lista do que falhou.

do $$
declare
  v_relatorio text; v_falhas text; v_total integer;
  v_staff uuid := gen_random_uuid(); v_c uuid; v_conv uuid;
  j jsonb; j2 jsonb; d jsonb; d2 jsonb; p jsonb; v_o uuid; v_o2 uuid; v_o3 uuid; v_ord uuid; v_n0 integer; v_lucro_card numeric; v_lucro_pix numeric;
  v_txt text; v_msg text; v_pr public.parametros_comerciais%rowtype; o public.orcamentos%rowtype; v_item_custo numeric;
begin
  create temp table _res (n serial, nome text, ok boolean, detalhe text) on commit drop;
  create or replace function pg_temp.ck(p_nome text, p_ok boolean, p_detalhe text default null) returns void
  language sql as 'insert into _res (nome, ok, detalhe) values (p_nome, coalesce(p_ok, false), p_detalhe)';
  create or replace function pg_temp.erro(p_sql text) returns text language plpgsql as
  $f$ begin execute p_sql; return null; exception when others then return sqlerrm; end $f$;

  insert into auth.users (id, email) values (v_staff, 'dono@teste.local');
  insert into public.profiles (id, name, role) values (v_staff, 'Dono Teste', 'admin');
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  select * into v_pr from public.parametros_comerciais where id = 1;
  insert into public.contacts (wa_id, name, segment) values ('5531900004000', 'Cliente Orçamento', null) returning id into v_c;
  insert into public.conversations (contact_id) values (v_c) returning id into v_conv;
  delete from public.precos_mercado;

  -- ============================== 1. montar_orcamento: entrega central grátis, arte com frete
  j := public.montar_orcamento(v_c, '[{"sku":"CFV02","quantidade":1}]', jsonb_build_object('bairro', 'Centro', 'arte', 'com_frete', 'conversation_id', v_conv));
  v_o := (j ->> 'orcamento_id')::uuid;
  select * into o from public.orcamentos where id = v_o;
  perform pg_temp.ck('montar: ok, rascunho, número SG-nnnn e validade de 48 h pelo parâmetro',
    j ->> 'status' = 'ok' and o.status = 'rascunho' and j ->> 'numero' ~ '^SG-\d{4,}$'
    and abs(extract(epoch from (o.validade_ate - now())) / 3600 - v_pr.validade_orcamento_horas) < 0.1, j::text);
  perform pg_temp.ck('montar: frete grátis de bicicleta na região central e arte com frete = R$ 49,90',
    j -> 'frete' ->> 'modo' = 'bike_gratis' and (j -> 'arte' ->> 'valor')::numeric = 49.90 and o.arte_modo = 'com_frete' and o.entrega = 'bike', j::text);
  perform pg_temp.ck('montar: total = itens + arte', (j ->> 'total')::numeric = (j ->> 'subtotal')::numeric + 49.90 and o.total = (j ->> 'total')::numeric, j::text);
  perform pg_temp.ck('montar: JSON do agente sem SKU, custo, piso, margem, lucro, mercado nem fornecedor',
    j::text !~* '(sku|custo|piso|margem|lucro|mediana|fornecedor|CFV02)', j::text);
  perform pg_temp.ck('montar: prazo com data de calendário e data prevista', j ->> 'prazo' ~* 'se pagar e mandar a arte até \d+h' and (j ->> 'data_prevista') ~ '^\d{4}-\d{2}-\d{2}$', j::text);
  perform pg_temp.ck('montar: upsell por regra (cartão leva adesivo ou panfleto)', j -> 'upsell' ->> 'tipo' = 'cartao_adesivo_panfleto', j::text);
  perform pg_temp.ck('montar: custo total, lucro, margem, regra e confiança ficam só no banco',
    o.custo_total > 0 and o.lucro_liquido > 0 and o.margem_liquida_pct > 0 and o.regra_preco is not null and o.confianca_preco is not null, row(o.custo_total, o.lucro_liquido, o.margem_liquida_pct)::text);
  perform pg_temp.ck('montar: item grava especificação pública e campos de mercado',
    (select count(*) = 1 and bool_and(especificacao is not null and especificacao !~* 'CFV' and piso is not null and piso_duro is not null and lucro_liquido is not null) from public.orcamento_itens where orcamento_id = v_o));
  perform pg_temp.ck('montar: nunca abaixo do piso duro (validar_margem ok)', public.validar_margem(v_o) ->> 'status' = 'ok');

  -- ============================== 2. fora da região: frete do cliente, arte com frete vira só arte
  j2 := public.montar_orcamento(v_c, '[{"sku":"CFV02","quantidade":1}]', jsonb_build_object('bairro', 'Contagem', 'arte', 'com_frete'));
  perform pg_temp.ck('montar: fora da região usa Uber por conta do cliente e a arte com frete vira R$ 39,90 com aviso',
    j2 -> 'frete' ->> 'modo' = 'uber_cliente' and j2 -> 'arte' ->> 'modo' = 'paga' and (j2 -> 'arte' ->> 'valor')::numeric = 39.90 and j2 -> 'avisos' ? 'arte_com_frete_indisponivel', j2::text);
  perform pg_temp.ck('montar: frete do cliente não entra no total nem vira custo nosso',
    (select o2.frete_valor = 0 and o2.entrega = 'retirada' and o2.frete_modo = 'uber_cliente' from public.orcamentos o2 where o2.id = (j2 ->> 'orcamento_id')::uuid));

  -- ============================== 3. sem local e sem arte definida: opções de arte
  j2 := public.montar_orcamento(v_c, '[{"sku":"PFL01","quantidade":1},{"sku":"ADV01","quantidade":2}]', '{}'::jsonb);
  v_o3 := (j2 ->> 'orcamento_id')::uuid;
  perform pg_temp.ck('montar: sem arte definida devolve as duas opções (R$ 39,90 e R$ 49,90) e total sem arte',
    j2 ->> 'status' = 'ok' and jsonb_array_length(j2 -> 'opcoes_arte') = 2 and (j2 -> 'arte' ->> 'valor')::numeric = 0 and jsonb_array_length(j2 -> 'itens') = 2
    and (j2 -> 'frete' ->> 'modo') = 'retirada', j2::text);
  perform pg_temp.ck('montar: dois itens, prazo é o mais distante e total = soma dos itens',
    (j2 ->> 'total')::numeric = (select sum(quantidade * preco_unitario) from public.orcamento_itens where orcamento_id = (j2 ->> 'orcamento_id')::uuid), j2::text);

  -- ============================== 4. recusas
  select count(*) into v_n0 from public.orcamentos;
  j2 := public.montar_orcamento(v_c, '[{"sku":"NAOEXISTE","quantidade":1}]', '{}'::jsonb);
  perform pg_temp.ck('montar: SKU inexistente é bloqueado e nada é gravado', j2 ->> 'status' = 'bloqueado' and j2 ->> 'motivo' = 'item_indisponivel' and (select count(*) from public.orcamentos) = v_n0, j2::text);
  j2 := public.montar_orcamento(v_c, '[]', '{}'::jsonb);
  perform pg_temp.ck('montar: orçamento sem itens é bloqueado', j2 ->> 'status' = 'bloqueado' and j2 ->> 'motivo' = 'itens_invalidos', j2::text);
  j2 := public.montar_orcamento(v_c, '[{"sku":"CFV02","quantidade":0}]', '{}'::jsonb);
  perform pg_temp.ck('montar: quantidade inválida é bloqueada', j2 ->> 'status' = 'bloqueado', j2::text);
  perform pg_temp.ck('montar: contato inexistente é bloqueado', public.montar_orcamento(gen_random_uuid(), '[{"sku":"CFV02","quantidade":1}]', '{}'::jsonb) ->> 'motivo' = 'contato_nao_encontrado');
  perform pg_temp.ck('montar: texto livre no lugar de SKU não vira item', public.montar_orcamento(v_c, '[{"sku":"cartão de visita","quantidade":1}]', '{}'::jsonb) ->> 'status' = 'bloqueado');

  -- ============================== 5. documento do PDF
  d := public.orcamento_documento(v_o);
  perform pg_temp.ck('documento: sem SKU, custo, piso, margem, lucro, fornecedor nem endereço de retirada',
    d::text !~* '(CFV02|sku|custo|piso|margem|lucro|fornecedor|rua rio de janeiro|sala 22|\mandar\M)', d::text);
  perform pg_temp.ck('documento: dados públicos da empresa (nome e CNPJ)', d -> 'empresa' ->> 'cnpj' = '58.481.181/0001-03' and d -> 'empresa' ->> 'nome' = 'Sua Gráfica BH', (d -> 'empresa')::text);
  perform pg_temp.ck('documento: prazo com data e frase "se pagar e mandar a arte até 12h"', d ->> 'prazo_frase' ~* 'se pagar e mandar a arte até 12h' and d ->> 'data_prevista' is not null, d ->> 'prazo_frase');
  d2 := public.orcamento_documento(v_o);
  perform pg_temp.ck('documento: hash estável sem mudança (geração idempotente)', d ->> 'hash' = d2 ->> 'hash');
  update public.orcamentos set arte_modo = 'paga', arte_valor = 39.90 where id = v_o;
  perform pg_temp.ck('documento: hash muda quando o orçamento muda', public.orcamento_documento(v_o) ->> 'hash' <> d ->> 'hash');
  update public.orcamentos set arte_modo = 'com_frete', arte_valor = 49.90 where id = v_o;
  perform pg_temp.ck('documento: orçamento válido não é marcado como vencido', (public.orcamento_documento(v_o) ->> 'vencido')::boolean = false);
  perform pg_temp.ck('documento: sem arte definida mostra as opções de arte', public.orcamento_documento(v_o3) -> 'arte' -> 'opcoes' is not null);

  -- ============================== 6. link de pagamento: validações e pedido
  p := public.preparar_link_pagamento(v_o);
  v_ord := (p ->> 'order_id')::uuid;
  perform pg_temp.ck('link: orçamento válido cria o pedido com o valor do orçamento', (p ->> 'ok')::boolean and abs((select total from public.order_financials where order_id = v_ord) - (select total from public.orcamentos where id = v_o)) < 0.01, p::text);
  perform pg_temp.ck('link: o pedido leva a arte como item e os itens do orçamento', (select count(*) from public.order_items where order_id = v_ord) = 2 and exists (select 1 from public.order_items where order_id = v_ord and description = 'Criação de arte' and unit_price = 49.90), null);
  perform pg_temp.ck('link: validade do link = validade do orçamento (horas restantes)', (p ->> 'expira_horas')::numeric between 47 and 48.1, p::text);
  perform pg_temp.ck('link: chamar de novo reaproveita o mesmo pedido (idempotente)', (public.preparar_link_pagamento(v_o) ->> 'order_id')::uuid = v_ord);
  perform pg_temp.ck('link: validar_antes_de_cobrar aceita pedido saudável', public.validar_antes_de_cobrar(v_ord) is null, public.validar_antes_de_cobrar(v_ord));

  -- pedido com valor diferente do orçamento é recusado
  update public.order_items set unit_price = unit_price + 5 where order_id = v_ord and code = 'CFV02';
  perform pg_temp.ck('link: pedido com valor diferente do orçamento é recusado', public.preparar_link_pagamento(v_o) ->> 'motivo' = 'valor_do_pedido_diferente_do_orcamento');
  update public.order_items set unit_price = unit_price - 5 where order_id = v_ord and code = 'CFV02';

  -- vencido
  update public.orcamentos set validade_ate = now() - interval '1 minute' where id = v_o;
  perform pg_temp.ck('link: orçamento vencido é recusado', public.preparar_link_pagamento(v_o) ->> 'motivo' = 'orcamento_vencido');
  perform pg_temp.ck('documento: orçamento vencido é sinalizado', (public.orcamento_documento(v_o) ->> 'vencido')::boolean);

  -- renovar: novo orçamento recalculado, antigo expira
  j2 := public.orcamento_renovar(v_o);
  v_o2 := (j2 ->> 'orcamento_id')::uuid;
  perform pg_temp.ck('renovar: gera orçamento novo, válido e recalculado; o antigo vira expirado',
    j2 ->> 'status' = 'ok' and (j2 ->> 'renovado')::boolean and (select status from public.orcamentos where id = v_o) = 'expirado'
    and (select origem_id from public.orcamentos where id = v_o2) = v_o and (select validade_ate from public.orcamentos where id = v_o2) > now()
    and (select arte_modo from public.orcamentos where id = v_o2) = 'com_frete', j2::text);
  perform pg_temp.ck('renovar: versão do documento conta a cadeia (v2)', (public.orcamento_documento(v_o2) ->> 'versao')::int = 2);
  perform pg_temp.ck('renovar: orçamento expirado não gera link', public.preparar_link_pagamento(v_o) ->> 'motivo' = 'orcamento_vencido');

  -- ============================== 7. trava de lucro: abaixo do piso duro e desconto sem condição
  perform pg_temp.ck('trava: item abaixo do piso duro é recusado pelo banco',
    pg_temp.erro(format('update public.orcamento_itens set preco_unitario = 1 where orcamento_id = %L', v_o2)) ~* 'piso duro|prejuízo');
  update public.orcamentos set status = 'enviado' where id = v_o2;
  update public.orcamentos set desconto_valor = 5 where id = v_o2;
  perform pg_temp.ck('trava: desconto sem condição especial bloqueia o link', public.preparar_link_pagamento(v_o2) ->> 'motivo' = 'desconto_sem_condicao_especial', public.preparar_link_pagamento(v_o2)::text);
  update public.orcamentos set desconto_valor = 0 where id = v_o2;
  p := public.preparar_link_pagamento(v_o2);
  v_ord := (p ->> 'order_id')::uuid;
  perform pg_temp.ck('link: orçamento enviado e saudável gera o pedido', (p ->> 'ok')::boolean, p::text);
  update public.orcamentos set desconto_valor = 5 where id = v_o2;
  perform pg_temp.ck('trava: validar_antes_de_cobrar recusa pedido cujo orçamento perdeu a margem', public.validar_antes_de_cobrar(v_ord) ~* 'trava de lucro', public.validar_antes_de_cobrar(v_ord));
  update public.orcamentos set desconto_valor = 0 where id = v_o2;

  -- ============================== 8. taxa do método e lucro real
  update public.orcamentos set metodo_previsto = null where id = v_o2;
  v_lucro_card := (public.validar_margem(v_o2) ->> 'lucro_liquido')::numeric;
  update public.orcamentos set metodo_previsto = 'pix' where id = v_o2;
  v_lucro_pix := (public.validar_margem(v_o2) ->> 'lucro_liquido')::numeric;
  perform pg_temp.ck('margem: validar_margem desconta a taxa do método (Pix rende mais que o cartão)', v_lucro_pix > v_lucro_card, format('pix=%s cartão=%s', v_lucro_pix, v_lucro_card));
  perform pg_temp.ck('margem: taxas do método (Pix 0,99% e cartão 4,98%)', (private.taxa_pagamento('pix') ->> 'pct')::numeric = 0.99 and (private.taxa_pagamento('cartao') ->> 'pct')::numeric = 4.98);

  perform private.confirmar_pagamento(v_ord, 'mercadopago', 'pix', 'mp-1', now(), null);
  perform pg_temp.ck('lucro real: pagamento por Pix grava a taxa 0,99% e o lucro líquido real no pedido',
    (select taxa_pagamento_real_pct = 0.99 and lucro_liquido_real is not null and lucro_liquido_real = (select net_profit from public.order_financials where order_id = v_ord) and payment_status = 'aprovado' and stage = 'pago' from public.orders where id = v_ord),
    (select row(taxa_pagamento_real_pct, lucro_liquido_real, stage)::text from public.orders where id = v_ord));
  perform pg_temp.ck('lucro real: orçamento enviado vira pago junto com o pedido', (select status from public.orcamentos where id = v_o2) = 'pago');
  perform pg_temp.ck('lucro real: pago não pode mais gerar link', public.preparar_link_pagamento(v_o2) ->> 'motivo' = 'orcamento_encerrado');

  -- cartão
  j2 := public.montar_orcamento(v_c, '[{"sku":"PFL01","quantidade":1}]', jsonb_build_object('bairro', 'Centro', 'arte', 'cliente'));
  p := public.preparar_link_pagamento((j2 ->> 'orcamento_id')::uuid);
  perform private.confirmar_pagamento((p ->> 'order_id')::uuid, 'mercadopago', 'cartao', 'mp-2', now(), null);
  perform pg_temp.ck('lucro real: pagamento no cartão grava 4,98%', (select taxa_pagamento_real_pct = 4.98 from public.orders where id = (p ->> 'order_id')::uuid));

  -- ============================== 8b. a service role valida a margem pelo invólucro (validar_margem direto falha em private)
  begin
    set local role service_role;
    j2 := public.orcamento_validar_margem(v_o3);
    v_msg := null;
  exception when others then
    v_msg := sqlerrm;
  end;
  reset role;
  perform pg_temp.ck('margem: service role valida pelo invólucro orcamento_validar_margem', v_msg is null and j2 ->> 'status' = 'ok', coalesce(v_msg, j2::text));
  begin
    set local role service_role;
    j2 := public.orcamento_marcar_enviado(v_o3);
    v_msg := null;
  exception when others then
    v_msg := sqlerrm;
  end;
  reset role;
  perform pg_temp.ck('envio: service role marca o orçamento como enviado pelo invólucro', v_msg is null and j2 ->> 'ok' = 'true' and (select status from public.orcamentos where id = v_o3) = 'enviado', coalesce(v_msg, j2::text));
  perform pg_temp.ck('margem: quem não é dono nem servidor não usa o invólucro', has_function_privilege('anon', 'public.orcamento_validar_margem(uuid)', 'execute') = false);

  -- ============================== 9. permissões
  perform pg_temp.ck('permissão: anon não executa as funções novas',
    not has_function_privilege('anon', 'public.montar_orcamento(uuid,jsonb,jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.orcamento_documento(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.preparar_link_pagamento(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.orcamento_renovar(uuid)', 'execute'));
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  perform pg_temp.ck('permissão: quem não é o dono não monta orçamento', pg_temp.erro(format('select public.montar_orcamento(%L, ''[{"sku":"CFV02","quantidade":1}]'', ''{}'')', v_c)) ~* 'sem permiss');
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform pg_temp.ck('bucket orcamentos é privado', (select coalesce(bool_and(not public), false) from storage.buckets where id = 'orcamentos'));

  select count(*), string_agg(format('%s %s%s', case when ok then 'OK    ' else 'FALHA ' end, nome, case when ok then '' else ' => ' || coalesce(detalhe, '') end), E'\n' order by n),
         string_agg(nome || ' => ' || coalesce(detalhe, ''), E'\n' order by n) filter (where not ok)
    into v_total, v_relatorio, v_falhas from _res;
  if v_falhas is not null then
    raise exception E'TESTES FALHARAM (nada foi gravado):\n%\n\nRelatório completo:\n%', v_falhas, v_relatorio;
  end if;
  raise exception E'OK: % testes passaram. Esta mensagem de erro é proposital, desfaz tudo o que o teste criou (nada foi gravado).\n%', v_total, v_relatorio;
end $$;
