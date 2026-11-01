-- Testes das funções e travas da Etapa 1 do agente. Um único bloco, que no final se desfaz sozinho (nada fica gravado).
-- Como rodar: cole tudo no SQL Editor do Supabase e clique em Run, ou: psql "$DATABASE_URL" -f supabase/tests/agente_etapa1.sql
-- O resultado SEMPRE aparece como uma mensagem de erro (é assim que o bloco desfaz as alterações):
--   "OK: N testes passaram ..." = tudo certo;  "TESTES FALHARAM ..." = lista do que falhou.

do $$
declare
  v_relatorio text;
  v_falhas text;
  v_total integer;
  v_small text; v_banner text; v_outro text;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid; v_c5 uuid; v_c6 uuid; v_c7 uuid; v_c8 uuid;
  v_o uuid; v_ord uuid; v_cost numeric; v_lead integer;
  j jsonb; j2 jsonb; v_piso numeric; v_duro numeric; v_msg text; v_ok boolean;
begin
  create temp table _res (n serial, nome text, ok boolean, detalhe text) on commit drop;
  create or replace function pg_temp.ck(p_nome text, p_ok boolean, p_detalhe text default null) returns void
  language sql as 'insert into _res (nome, ok, detalhe) values (p_nome, coalesce(p_ok, false), p_detalhe)';

  -- SKUs de teste: cartão de visita barato com prazo de 1 dia útil e banner grande
  select code into v_small from public.products where active and category = 'CARTÕES DE VISITA' and lead_days = 1 and weight <= 1000 order by cost limit 1 offset 1;
  select code into v_banner from public.products where active and category like 'BANNERS%' and (regexp_match(size, '\d+'))[1]::int >= 700 and weight <= 5000 order by cost limit 1;
  select code into v_outro from public.products where active and category = 'CARTÕES DE VISITA' and lead_days = 1 and weight <= 1000 and code <> v_small order by cost limit 1;
  perform pg_temp.ck('fixture: SKUs de teste encontrados', v_small is not null and v_banner is not null and v_outro is not null, concat_ws(',', v_small, v_banner, v_outro));
  select cost into v_cost from public.products where code = v_small;

  insert into public.contacts (wa_id, name) values ('5531900000001', 'Teste 1') returning id into v_c1;
  insert into public.contacts (wa_id, name) values ('5531900000002', 'Teste 2') returning id into v_c2;
  insert into public.contacts (wa_id, name) values ('5531900000003', 'Teste 3') returning id into v_c3;
  insert into public.contacts (wa_id, name) values ('5531900000004', 'Teste 4') returning id into v_c4;
  insert into public.contacts (wa_id, name) values ('5531900000005', 'Teste 5') returning id into v_c5;
  insert into public.contacts (wa_id, name) values ('5531900000006', 'Teste 6') returning id into v_c6;
  insert into public.contacts (wa_id, name) values ('5531900000007', 'Teste 7') returning id into v_c7;
  insert into public.contacts (wa_id, name) values ('5531900000008', 'Teste 8') returning id into v_c8;

  -- ============================== prazo (feriados nacionais cadastrados: 02/11 Finados, 20/11 Consciência Negra)
  j := public.calcular_prazo(v_small, '2026-11-07 15:00:00-03', true);   -- sábado
  perform pg_temp.ck('prazo: fim de semana começa na segunda 09/11', j ->> 'inicio_contagem' = '2026-11-09', j::text);
  perform pg_temp.ck('prazo: fim de semana pronto na quarta 11/11 (1 dia fornecedor + 1 logística)', j ->> 'data_pronto' = '2026-11-11', j::text);

  j := public.calcular_prazo(v_small, '2026-11-19 10:00:00-03', true);   -- quinta antes das 12h, sexta é feriado
  perform pg_temp.ck('prazo: feriado 20/11 é pulado (pronto terça 24/11)', j ->> 'data_pronto' = '2026-11-24', j::text);

  j := public.calcular_prazo(v_small, '2026-10-28 10:00:00-03', true);   -- quarta antes das 12h
  perform pg_temp.ck('prazo: antes das 12h conta o próprio dia (pronto sexta 30/10)', j ->> 'data_pronto' = '2026-10-30' and j ->> 'inicio_contagem' = '2026-10-28', j::text);
  perform pg_temp.ck('prazo: horário de retirada da sexta é até 18:30', j ->> 'retirada_abre' = '09:00' and j ->> 'retirada_fecha' = '18:30', j::text);
  perform pg_temp.ck('prazo: frase cita hoje e a data', (j ->> 'frase') like '%até 12h de hoje, fica pronto na sexta, dia 30', j ->> 'frase');

  j := public.calcular_prazo(v_small, '2026-10-28 13:00:00-03', false);  -- quarta depois das 12h
  perform pg_temp.ck('prazo: depois das 12h começa no próximo dia útil (pronto terça 03/11, pulando Finados)', j ->> 'data_pronto' = '2026-11-03' and j ->> 'inicio_contagem' = '2026-10-29', j::text);
  perform pg_temp.ck('prazo: sem arte aprovada avisa que depende da arte', (j ->> 'depende_da_arte')::boolean and (j ->> 'frase') like 'se pagar e mandar a arte%', j ->> 'frase');

  j := public.calcular_prazo(v_small, '2026-10-30 15:00:00-03', true);   -- sexta à tarde
  perform pg_temp.ck('prazo: sexta à tarde vai para terça 03/11 e fica pronto quinta 05/11', j ->> 'inicio_contagem' = '2026-11-03' and j ->> 'data_pronto' = '2026-11-05', j::text);
  perform pg_temp.ck('prazo: horário de retirada da quinta é até 17:00', j ->> 'retirada_fecha' = '17:00', j::text);
  perform pg_temp.ck('prazo: SKU inexistente devolve erro', public.calcular_prazo('NAO_EXISTE', now(), true) ->> 'erro' = 'sku_nao_encontrado');

  -- ============================== frete
  j := public.verificar_frete('Savassi', jsonb_build_array(jsonb_build_object('sku', v_small, 'quantidade', 1)), 200, false);
  perform pg_temp.ck('frete: bairro central + item pequeno + acima do mínimo é grátis', (j ->> 'frete_gratis')::boolean and j ->> 'entrega_sugerida' = 'bike', j::text);
  j := public.verificar_frete('FUNCIONARIOS', jsonb_build_array(jsonb_build_object('sku', v_small, 'quantidade', 1)), 200, false);
  perform pg_temp.ck('frete: bairro sem acento e em maiúsculas é reconhecido', (j ->> 'regiao_central')::boolean, j::text);
  j := public.verificar_frete('30140-071', jsonb_build_array(jsonb_build_object('sku', v_small, 'quantidade', 1)), 200, false);
  perform pg_temp.ck('frete: CEP da faixa central é reconhecido', (j ->> 'regiao_central')::boolean and (j ->> 'frete_gratis')::boolean, j::text);
  j := public.verificar_frete('Centro', jsonb_build_array(jsonb_build_object('sku', v_banner, 'quantidade', 1)), 500, false);
  perform pg_temp.ck('frete: bairro central com banner não cabe na bike', not (j ->> 'frete_gratis')::boolean and j ->> 'motivo' = 'nao_cabe_na_bike' and not (j ->> 'cabe_na_bike')::boolean, j::text);
  j := public.verificar_frete('Venda Nova', jsonb_build_array(jsonb_build_object('sku', v_small, 'quantidade', 1)), 500, false);
  perform pg_temp.ck('frete: fora da região central não é grátis', not (j ->> 'frete_gratis')::boolean and j ->> 'motivo' = 'fora_da_regiao_central', j::text);
  j := public.verificar_frete('Centro', jsonb_build_array(jsonb_build_object('sku', v_small, 'quantidade', 1)), 100, false);
  perform pg_temp.ck('frete: pedido abaixo do mínimo não é grátis e informa quanto falta', not (j ->> 'frete_gratis')::boolean and j ->> 'motivo' = 'abaixo_do_pedido_minimo' and (j ->> 'falta_para_frete_gratis')::numeric = 50, j::text);
  j := public.verificar_frete('Centro', jsonb_build_array(jsonb_build_object('sku', v_small, 'quantidade', 1)), 49.90, true);
  perform pg_temp.ck('frete: pacote de arte dispensa o pedido mínimo', (j ->> 'frete_gratis')::boolean, j::text);
  j := public.verificar_frete('Centro', jsonb_build_array(jsonb_build_object('sku', v_banner, 'quantidade', 1)), 49.90, true);
  perform pg_temp.ck('frete: pacote de arte NÃO dispensa a trava de tamanho', not (j ->> 'frete_gratis')::boolean, j::text);
  j := public.verificar_frete('Sion', jsonb_build_array(jsonb_build_object('sku', v_small, 'quantidade', 1)), 500, false);
  perform pg_temp.ck('frete: bairro candidato inativo não vale', not (j ->> 'regiao_central')::boolean, j::text);

  -- ============================== preço
  j := public.calcular_preco(v_small, 1, '{}');
  v_piso := (j ->> 'piso')::numeric; v_duro := (j ->> 'piso_duro')::numeric;
  perform pg_temp.ck('preço: nunca abaixo do piso e o piso nunca abaixo do piso_duro', (j ->> 'preco_total')::numeric >= v_piso and v_piso >= v_duro, j::text);
  perform pg_temp.ck('preço: termina em ,90', round(((j ->> 'preco_total')::numeric - floor((j ->> 'preco_total')::numeric)) * 100) = 90, j::text);
  perform pg_temp.ck('preço: lucro líquido respeita o mínimo de R$ 60', (j ->> 'lucro_liquido')::numeric >= 60, j::text);
  perform pg_temp.ck('preço: resposta não traz custo', not (j ? 'custo' or j ? 'cost' or j ? 'custo_total'), j::text);
  perform pg_temp.ck('preço: sem mercado a confiança é baixa', j ->> 'confianca' in ('baixa'), j::text);
  perform pg_temp.ck('preço: SKU inexistente devolve erro', public.calcular_preco('NAO_EXISTE') ->> 'erro' = 'sku_nao_encontrado');
  -- mercado abaixo do piso mantém o piso e marca não competitivo
  insert into public.precos_mercado (sku, chave_especificacao, fonte, preco) values (v_small, 'teste', 'a', 20), (v_small, 'teste', 'b', 22), (v_small, 'teste', 'c', 21);
  j2 := public.calcular_preco(v_small, 1, '{}');
  perform pg_temp.ck('preço: mercado abaixo do piso mantém o piso e marca não competitivo', j2 ->> 'regra' = 'piso' and (j2 ->> 'nao_competitivo')::boolean and (j2 ->> 'preco_total')::numeric >= v_piso, j2::text);
  delete from public.precos_mercado where chave_especificacao = 'teste';
  insert into public.precos_mercado (sku, chave_especificacao, fonte, preco) values (v_small, 'teste', 'a', 900), (v_small, 'teste', 'b', 1000), (v_small, 'teste', 'c', 1100);
  j2 := public.calcular_preco(v_small, 1, '{}');
  perform pg_temp.ck('preço: mercado confiável usa mediana x 0,93', j2 ->> 'regra' = 'mercado' and j2 ->> 'confianca' = 'alta' and (j2 ->> 'preco_total')::numeric = 929.90, j2::text);  -- 1.000 x 0,93 = 930, o ,90 mais próximo é 929,90
  delete from public.precos_mercado where chave_especificacao = 'teste';
  -- taxa por método: Pix custa menos que cartão, então o piso cai
  j2 := public.calcular_preco(v_small, 1, '{"metodo":"pix"}');
  perform pg_temp.ck('preço: piso usa a taxa do método informado (Pix < cartão)', (j2 ->> 'piso')::numeric <= v_piso, j2::text);

  -- ============================== triggers de banco
  insert into public.orcamentos (contact_id, status) values (v_c1, 'rascunho') returning id into v_o;
  v_ok := false;
  begin insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, v_small, 'Cartões', 1, 0.50);
  exception when others then v_ok := true; v_msg := sqlerrm; end;
  perform pg_temp.ck('trava: item de orçamento abaixo do piso_duro é recusado pelo banco', v_ok, v_msg);
  v_ok := false;
  begin insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, null, 'Sem SKU', 1, 100);
  exception when others then v_ok := true; v_msg := sqlerrm; end;
  perform pg_temp.ck('trava: item de orçamento sem SKU é recusado', v_ok, v_msg);
  v_ok := false;
  begin insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, 'NAO_EXISTE', 'SKU falso', 1, 100);
  exception when others then v_ok := true; v_msg := sqlerrm; end;
  perform pg_temp.ck('trava: SKU inexistente é recusado', v_ok, v_msg);

  -- preço acima do piso_duro do item, mas que dá prejuízo no pedido (WhatsApp + IA): rascunho passa, envio é recusado
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, v_small, 'Cartões', 1, ceil(v_cost / 0.835 * 100) / 100 + 0.01);
  j := public.validar_margem(v_o);
  perform pg_temp.ck('margem: preço abaixo do piso é bloqueado com motivo e alternativa', j ->> 'status' = 'bloqueado' and j ->> 'alternativa' is not null, j::text);
  v_ok := false;
  begin update public.orcamentos set status = 'enviado' where id = v_o;
  exception when others then v_ok := true; v_msg := sqlerrm; end;
  perform pg_temp.ck('trava: orçamento com prejuízo não pode ser enviado', v_ok, v_msg);

  -- pedido: item abaixo do piso duro
  insert into public.orders (contact_id) values (v_c1) returning id into v_ord;
  v_ok := false;
  begin insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) values (v_ord, v_small, 'Cartões', 1, 100, 100);
  exception when others then v_ok := true; v_msg := sqlerrm; end;
  perform pg_temp.ck('trava: item de pedido abaixo do piso_duro é recusado pelo banco', v_ok, v_msg);
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) values (v_ord, v_small, 'Cartões', 1, 100, 200);
  v_ok := false;
  begin update public.orders set discount_pct = 60 where id = v_ord;
  exception when others then v_ok := true; v_msg := sqlerrm; end;
  perform pg_temp.ck('trava: desconto que leva o pedido a prejuízo é recusado', v_ok, v_msg);

  -- ============================== margem OK e desconto acima do teto
  insert into public.orcamentos (contact_id, status, bairro) values (v_c2, 'rascunho', 'Centro') returning id into v_o;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, v_small, 'Cartões', 1, v_piso + 300);
  update public.orcamentos set status = 'enviado' where id = v_o;
  j := public.validar_margem(v_o);
  perform pg_temp.ck('margem: orçamento saudável passa com lucro informado', j ->> 'status' = 'ok' and (j ->> 'lucro_liquido')::numeric > 60, j::text);
  insert into public.condicoes_especiais (orcamento_id, contact_id, degrau, gatilho, tipo, valor, texto_curto, valida_ate)
    values (v_o, v_c2, 2, 'G1', 'desconto', 5, 'desconto de R$ 5,00', now() + interval '1 day');
  update public.orcamentos set desconto_valor = 20 where id = v_o;
  j := public.validar_margem(v_o);
  perform pg_temp.ck('margem: desconto acima do teto concedido é bloqueado', j ->> 'status' = 'bloqueado' and (j -> 'motivos') ? 'desconto_acima_do_teto', j::text);
  update public.orcamentos set desconto_valor = 5 where id = v_o;
  j := public.validar_margem(v_o);
  perform pg_temp.ck('margem: desconto dentro do teto concedido passa', j ->> 'status' = 'ok', j::text);
  update public.orcamentos set desconto_valor = 0 where id = v_o;
  delete from public.condicoes_especiais where orcamento_id = v_o;
  update public.orcamentos set desconto_valor = 5 where id = v_o;
  j := public.validar_margem(v_o);
  perform pg_temp.ck('margem: desconto sem condição especial é bloqueado', j ->> 'status' = 'bloqueado' and (j -> 'motivos') ? 'desconto_sem_condicao_especial', j::text);
  update public.orcamentos set desconto_valor = 0 where id = v_o;

  -- ============================== condição especial
  -- rascunho nunca recebe condição
  insert into public.orcamentos (contact_id, status) values (v_c3, 'rascunho') returning id into v_o;
  perform pg_temp.ck('condição: nunca antes de o orçamento ser enviado', public.calcular_condicao_especial(v_o, 'G1') ->> 'motivo' = 'orcamento_ainda_nao_enviado');

  -- gordura zero: preço exatamente no piso
  insert into public.orcamentos (contact_id, status) values (v_c3, 'rascunho') returning id into v_o;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, v_small, 'Cartões', 1, v_piso);
  update public.orcamentos set status = 'enviado' where id = v_o;
  j := public.calcular_condicao_especial(v_o, 'G1');
  perform pg_temp.ck('condição: gordura zero não gera desconto em dinheiro', j ->> 'tipo' = 'sem_condicao' and j ->> 'motivo' = 'sem_gordura_acima_do_piso', j::text);

  -- valor calculado abaixo de R$ 5: gordura de R$ 6 permite no máximo R$ 3,60
  insert into public.orcamentos (contact_id, status) values (v_c4, 'rascunho') returning id into v_o;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, v_small, 'Cartões', 1, v_piso + 6);
  update public.orcamentos set status = 'enviado' where id = v_o;
  j := public.calcular_condicao_especial(v_o, 'G1');
  perform pg_temp.ck('condição: desconto calculado abaixo de R$ 5 não é oferecido em dinheiro', j ->> 'tipo' = 'sem_condicao' and j ->> 'motivo' = 'desconto_menor_que_o_minimo', j::text);

  -- caso feliz G1: desconto degrau 2 (4%), respeitando teto financeiro; depois a segunda condição no mesmo orçamento
  insert into public.orcamentos (contact_id, status) values (v_c5, 'rascunho') returning id into v_o;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, v_small, 'Cartões', 1, v_piso + 300);
  update public.orcamentos set status = 'enviado' where id = v_o;
  j := public.calcular_condicao_especial(v_o, 'G1');
  perform pg_temp.ck('condição: G1 sem vantagem aplicável gera desconto do degrau 2 dentro de todos os tetos',
    j ->> 'tipo' = 'desconto' and (j ->> 'degrau')::int = 2
    and (j ->> 'valor')::numeric <= (v_piso + 300) * 0.04 + 0.001 and (j ->> 'valor')::numeric <= 300 * 0.6 + 0.001 and (j ->> 'valor')::numeric <= 80
    and (j ->> 'valida_ate')::timestamptz > now() + interval '23 hours', j::text);
  j2 := public.calcular_condicao_especial(v_o, 'G3');
  perform pg_temp.ck('condição: segunda condição no mesmo orçamento é recusada', j2 ->> 'tipo' = 'sem_condicao' and j2 ->> 'motivo' = 'ja_houve_condicao_neste_orcamento', j2::text);
  -- intervalo por contato: outro orçamento do mesmo contato dentro de 30 dias
  insert into public.orcamentos (contact_id, status) values (v_c5, 'rascunho') returning id into v_o;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, v_small, 'Cartões', 1, v_piso + 300);
  update public.orcamentos set status = 'enviado' where id = v_o;
  perform pg_temp.ck('condição: no máximo uma a cada 30 dias por contato', public.calcular_condicao_especial(v_o, 'G1') ->> 'motivo' = 'intervalo_entre_condicoes_do_contato');

  -- G3: degrau 3 (8%) com teto absoluto
  insert into public.orcamentos (contact_id, status) values (v_c6, 'rascunho') returning id into v_o;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, v_small, 'Cartões', 1, v_piso + 3000);
  update public.orcamentos set status = 'enviado' where id = v_o;
  j := public.calcular_condicao_especial(v_o, 'G3');
  perform pg_temp.ck('condição: G3 usa o degrau 3 e o teto de R$ 80', j ->> 'tipo' = 'desconto' and (j ->> 'degrau')::int = 3 and (j ->> 'valor')::numeric = 80, j::text);

  -- vantagem sem custo: frete grátis sem pedido mínimo na região central
  insert into public.orcamentos (contact_id, status, bairro, frete_valor, entrega) values (v_c7, 'rascunho', 'Savassi', 25, 'uber') returning id into v_o;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, v_small, 'Cartões', 1, v_piso + 40);
  update public.orcamentos set status = 'enviado' where id = v_o;
  j := public.calcular_condicao_especial(v_o, 'G1');
  perform pg_temp.ck('condição: degrau 1 oferece frete grátis sem mínimo quando se aplica', j ->> 'tipo' = 'frete_gratis' and (j ->> 'degrau')::int = 1, j::text);

  -- item com permite_desconto = false fica fora
  update public.products set permite_desconto = false where code = v_outro;
  insert into public.orcamentos (contact_id, status) values (v_c8, 'rascunho') returning id into v_o;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario)
    values (v_o, v_outro, 'Cartões', 1, (public.calcular_preco(v_outro) ->> 'preco_total')::numeric + 300);
  update public.orcamentos set status = 'enviado' where id = v_o;
  j := public.calcular_condicao_especial(v_o, 'G1');
  perform pg_temp.ck('condição: item com permite_desconto = false não recebe desconto', j ->> 'tipo' = 'sem_condicao' and j ->> 'motivo' = 'itens_sem_permissao_de_desconto', j::text);

  -- ============================== estrutura e segurança
  perform pg_temp.ck('estrutura: tabelas novas com RLS ativa',
    (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and not c.relrowsecurity
       and c.relname in ('parametros_comerciais','politica_desconto','zonas_frete_gratis','agente_config','anuncios_produtos','orcamentos','orcamento_itens','condicoes_especiais','precos_mercado','precos_praticados','conhecimento','followup_regras','followup_fila','alertas','testes_conversa')) = 0);
  perform pg_temp.ck('segurança: anon sem acesso a products, order_items e parametros_comerciais',
    not has_table_privilege('anon', 'public.products', 'select') and not has_table_privilege('anon', 'public.order_items', 'select') and not has_table_privilege('anon', 'public.parametros_comerciais', 'select'));
  perform pg_temp.ck('segurança: anon não executa as funções do agente', not has_function_privilege('anon', 'public.calcular_preco(text,integer,jsonb)', 'execute'));
  perform pg_temp.ck('modo_atendimento acompanha ai_handled',
    (select modo_atendimento from public.conversations limit 1) is not distinct from (select case when ai_handled then 'ia' else 'humano' end from public.conversations limit 1));

  -- Relatório. A mensagem de "erro" no final é proposital: ela desfaz tudo o que o teste criou.
  select count(*), string_agg(format('%s %s%s', case when ok then 'OK    ' else 'FALHA ' end, nome, case when ok then '' else ' => ' || coalesce(detalhe, '') end), E'\n' order by n),
         string_agg(nome || ' => ' || coalesce(detalhe, ''), E'\n' order by n) filter (where not ok)
    into v_total, v_relatorio, v_falhas
  from _res;
  if v_falhas is not null then
    raise exception E'TESTES FALHARAM (nada foi gravado):\n%\n\nRelatório completo:\n%', v_falhas, v_relatorio;
  end if;
  raise exception E'OK: % testes passaram. Esta mensagem de erro é proposital, desfaz tudo o que o teste criou (nada foi gravado).\n%', v_total, v_relatorio;
end $$;
