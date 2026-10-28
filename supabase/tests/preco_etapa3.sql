-- Testes da Etapa 3: preço sob demanda, cache de mercado, aprendizado, condição especial, política e edição manual de preço.
-- Um único bloco que se desfaz no final (nada fica gravado). Como rodar: supabase/tests/rodar-local.sh supabase/tests/preco_etapa3.sql
-- O resultado SEMPRE aparece como uma mensagem de erro (é assim que o bloco desfaz as alterações):
--   "OK: N testes passaram ..." = tudo certo;  "TESTES FALHARAM ..." = lista do que falhou.

do $$
declare
  v_relatorio text; v_falhas text; v_total integer;
  v_sku text := 'CFV02'; v_sku2 text := 'PFL01'; v_sku3 text := 'ADV01';
  v_custo numeric; j jsonb; j2 jsonb; k jsonb; c jsonb;
  v_c uuid; v_o uuid; v_ord uuid; v_item uuid; v_n uuid; v_cons uuid; v_staff uuid := gen_random_uuid();
  v_piso numeric; v_duro numeric; v_alvo numeric; v_msg text; v_pct0 numeric; v_kit uuid;
  i integer; v_sorteio record; v_qtd integer; v_neg integer := 0; v_ok_cond integer := 0; v_tentativas integer := 0;
  v_lucro numeric; v_liq numeric; v_duro_ent numeric; v_ent text; v_gat text; v_fin jsonb; v_fonte integer; v_preco numeric;
  v_min_lucro numeric := 1e9; v_min_folga numeric := 1e9; v_cenarios jsonb := '{}'::jsonb; v_tipo text;
begin
  create temp table _res (n serial, nome text, ok boolean, detalhe text) on commit drop;
  create or replace function pg_temp.ck(p_nome text, p_ok boolean, p_detalhe text default null) returns void
  language sql as 'insert into _res (nome, ok, detalhe) values (p_nome, coalesce(p_ok, false), p_detalhe)';
  create or replace function pg_temp.erro(p_sql text) returns text language plpgsql as
  $f$ begin execute p_sql; return null; exception when others then return sqlerrm; end $f$;

  -- identidades: o dono (autenticado) e o servidor (service_role) são simulados pelos claims da sessão
  insert into auth.users (id, email) values (v_staff, 'dono@teste.local');
  insert into public.profiles (id, name, role) values (v_staff, 'Dono Teste', 'admin');
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claim.sub', v_staff::text, true);

  select custo into v_custo from public.catalogo where sku = v_sku;
  perform pg_temp.ck('fixture: catálogo de teste com CFV02, PFL01 e ADV01', v_custo = 75.99 and exists (select 1 from public.catalogo where sku = v_sku2) and exists (select 1 from public.catalogo where sku = v_sku3));

  -- ============================== 1. preço sem mercado
  delete from public.precos_mercado;
  j := public.calcular_preco(v_sku);
  v_piso := (j ->> 'piso')::numeric; v_duro := (j ->> 'piso_duro')::numeric;
  perform pg_temp.ck('preço: sem mercado usa custo x multiplicador com confiança baixa e aviso',
    j ->> 'regra' in ('custo_x_multiplicador', 'piso') and j ->> 'confianca' = 'baixa' and (j -> 'avisos') ? 'sem_dado_de_mercado' and (j ->> 'preco_total')::numeric >= v_piso, j::text);
  perform pg_temp.ck('preço: piso >= custo x 1,5 e piso_duro < piso', v_piso >= v_custo * 1.5 and v_duro < v_piso, j::text);
  perform pg_temp.ck('preço: lucro líquido sem mercado é positivo', (j ->> 'lucro_liquido')::numeric > 0, j::text);

  -- ============================== 2. mercado consistente (3 fontes)
  insert into public.precos_mercado (sku, chave_especificacao, fonte, preco, confianca)
    select v_sku, (select especificacao_normalizada from public.catalogo where sku = v_sku), f, p, 'alta'
      from (values ('a.com.br', 250.00), ('b.com.br', 260.00), ('c.com.br', 270.00)) t (f, p);
  j := public.calcular_preco(v_sku);
  v_alvo := private.arredonda_90(260 * 0.93);
  perform pg_temp.ck('preço: mercado com 3 fontes = mediana x fator 0,93, confiança alta',
    j ->> 'regra' = 'mercado' and j ->> 'confianca' = 'alta' and (j ->> 'preco_total')::numeric = v_alvo and (j ->> 'fontes_mercado')::int = 3 and not (j ->> 'nao_competitivo')::boolean, j::text);
  perform pg_temp.ck('preço: nunca abaixo do piso_duro', (j ->> 'preco_total')::numeric >= (j ->> 'piso_duro')::numeric);
  perform pg_temp.ck('agente_preco não devolve custo, piso, margem nem mediana',
    (public.agente_preco(v_sku)::text !~ '(piso|custo|margem|lucro|mediana|fornecedor)'), public.agente_preco(v_sku)::text);

  -- fator por grupo (aprendido) muda o alvo, dentro dos limites
  insert into public.fatores_competitivos (grupo_produto, fator) values ('CARTÕES DE VISITA', 0.90);
  j := public.calcular_preco(v_sku);
  perform pg_temp.ck('preço: fator do grupo (0,90) é usado no lugar do padrão', (j ->> 'fator_competitivo')::numeric = 0.90 and (j ->> 'preco_total')::numeric = private.arredonda_90(260 * 0.90), j::text);
  delete from public.fatores_competitivos;

  -- ============================== 3. mercado muito abaixo do piso
  delete from public.precos_mercado;
  insert into public.precos_mercado (sku, chave_especificacao, fonte, preco, confianca)
    select v_sku, (select especificacao_normalizada from public.catalogo where sku = v_sku), f, p, 'alta'
      from (values ('a.com.br', 40.00), ('b.com.br', 45.00), ('c.com.br', 50.00)) t (f, p);
  j := public.calcular_preco(v_sku);
  perform pg_temp.ck('preço: mercado muito abaixo do piso mantém o piso, marca não competitivo e avisa',
    j ->> 'regra' = 'piso' and (j ->> 'nao_competitivo')::boolean and (j -> 'avisos') ? 'mercado_abaixo_do_piso'
    and (j ->> 'preco_total')::numeric >= v_piso and (j ->> 'lucro_liquido')::numeric >= 0, j::text);
  perform pg_temp.ck('agente_preco orienta destacar valor quando não competitivo', public.agente_preco(v_sku) ->> 'orientacao' ilike '%destaque%', public.agente_preco(v_sku)::text);

  -- ============================== 4. cache, pesquisa, outlier e sem dado
  delete from public.precos_mercado; delete from public.consultas_preco_mercado;
  j := public.consultar_cache_preco_mercado(v_sku2, '{"grupo":"digitado pelo agente"}');
  perform pg_temp.ck('cache: sem dado pede pesquisa e devolve a especificação do catálogo (não a do agente)',
    (j ->> 'precisa_pesquisar')::boolean and j -> 'especificacao' ->> 'grupo' = 'PANFLETOS, FLYERS E FOLHETOS' and (j ->> 'timeout_s')::int = 45, j::text);
  v_cons := (j ->> 'consulta_id')::uuid;
  j2 := public.consultar_cache_preco_mercado(v_sku2);
  perform pg_temp.ck('cache: segunda chamada durante a pesquisa não dispara outra', (j2 ->> 'em_andamento')::boolean and not (j2 ->> 'precisa_pesquisar')::boolean, j2::text);
  j := public.registrar_pesquisa_mercado(v_cons,
    '[{"fonte":"a.com.br","preco":170,"mesma_especificacao":true},{"fonte":"b.com.br","preco":175,"mesma_especificacao":true},
      {"fonte":"c.com.br","preco":180,"mesma_especificacao":true},{"fonte":"d.com.br","preco":620,"mesma_especificacao":true},
      {"fonte":"e.com.br","preco":50,"mesma_especificacao":false},{"fonte":"a.com.br","preco":999,"mesma_especificacao":true}]'::jsonb, 4200, null, 0, 6);
  perform pg_temp.ck('pesquisa: outlier descartado, mesma fonte conta uma vez e outra especificação é ignorada',
    (j ->> 'fontes')::int = 3 and (j ->> 'outliers')::int = 1 and (j ->> 'mediana')::numeric = 175 and j ->> 'confianca' = 'alta'
    and (j ->> 'minimo')::numeric = 170 and (j ->> 'maximo')::numeric = 180, j::text);
  j := public.consultar_cache_preco_mercado(v_sku2);
  perform pg_temp.ck('cache: pesquisa válida é devolvida na hora, sem nova pesquisa', (j ->> 'cache')::boolean and not (j ->> 'precisa_pesquisar')::boolean and (j ->> 'fontes')::int = 3 and (j ->> 'mediana')::numeric = 175, j::text);
  j := public.calcular_preco(v_sku2);
  perform pg_temp.ck('preço: calcular_preco passa a usar a pesquisa e informa a consulta de origem', j ->> 'regra' in ('mercado', 'piso') and (j ->> 'fontes_mercado')::int = 3 and (j ->> 'consulta_mercado_id') is not null, j::text);
  update public.precos_mercado set coletado_em = now() - interval '15 days';
  j := public.consultar_cache_preco_mercado(v_sku2);
  perform pg_temp.ck('cache: após 14 dias pesquisa de novo', (j ->> 'precisa_pesquisar')::boolean, j::text);
  perform pg_temp.ck('preço: pesquisa vencida (15 dias) não vale para o preço', public.calcular_preco(v_sku2) ->> 'regra' = 'custo_x_multiplicador');
  j := public.registrar_pesquisa_mercado((j ->> 'consulta_id')::uuid, '[]'::jsonb, 45000, 'tempo_esgotado');
  perform pg_temp.ck('pesquisa: falha ou estouro de tempo devolve sem dado', j ->> 'status' = 'sem_dado' or j ->> 'status' = 'erro', j::text);
  j := public.consultar_cache_preco_mercado(v_sku2);
  perform pg_temp.ck('cache: sem dado recente não repete a pesquisa de imediato (limite de taxa)', (j ->> 'sem_dado')::boolean and not (j ->> 'precisa_pesquisar')::boolean, j::text);
  perform pg_temp.ck('pesquisa: sem dado cai na fórmula de custo com travas', public.calcular_preco(v_sku2) ->> 'regra' = 'custo_x_multiplicador' and (public.calcular_preco(v_sku2) ->> 'preco_total')::numeric >= (public.calcular_preco(v_sku2) ->> 'piso')::numeric);

  -- limite de taxa e robots por domínio
  j := public.reservar_acesso_dominio('www.alfacards.com.br');
  perform pg_temp.ck('domínio: primeiro acesso permitido (robots conferido, exige navegador)', (j ->> 'permitido')::boolean and (j ->> 'exige_navegador')::boolean, j::text);
  j := public.reservar_acesso_dominio('www.alfacards.com.br');
  perform pg_temp.ck('domínio: segundo acesso imediato espera o intervalo', not (j ->> 'permitido')::boolean and j ->> 'motivo' = 'limite_de_taxa', j::text);
  j := public.reservar_acesso_dominio('site-novo.exemplo.com.br');
  perform pg_temp.ck('domínio: domínio novo não é acessado antes de conferir robots e termos', not (j ->> 'permitido')::boolean and j ->> 'motivo' = 'dominio_novo_nao_conferido', j::text);

  -- aquecer cache (desligado por padrão e sem varrer o catálogo)
  perform pg_temp.ck('aquecer cache: desligado por padrão devolve lista vazia', public.skus_para_aquecer() = '[]'::jsonb);
  update public.parametros_comerciais set aquecer_cache_ligado = true where id = 1;
  perform pg_temp.ck('aquecer cache: ligado sem orçamentos recentes continua vazio (nada de varredura em massa)', public.skus_para_aquecer(20) = '[]'::jsonb);
  update public.parametros_comerciais set aquecer_cache_ligado = false where id = 1;

  -- ============================== 5. âncora de vendas anteriores
  delete from public.precos_mercado; delete from public.precos_praticados;
  insert into public.precos_mercado (sku, chave_especificacao, fonte, preco, confianca)
    select v_sku, (select especificacao_normalizada from public.catalogo where sku = v_sku), f, p, 'alta' from (values ('a.com.br', 200.00), ('b.com.br', 200.00), ('c.com.br', 200.00)) t (f, p);
  j := public.calcular_preco(v_sku);
  insert into public.precos_praticados (sku, grupo_produto, quantidade, preco_total, resultado, fechado_em) values (v_sku, 'CARTÕES DE VISITA', 1, 190, 'ganho', now()), (v_sku, 'CARTÕES DE VISITA', 1, 190, 'ganho', now());
  j2 := public.calcular_preco(v_sku);
  perform pg_temp.ck('âncora: 2 vendas não bastam (precisa de 3)', j2 ->> 'regra' = 'mercado' and j2 -> 'ancora_vendas' = 'null'::jsonb, j2::text);
  insert into public.precos_praticados (sku, grupo_produto, quantidade, preco_total, resultado, fechado_em) values (v_sku, 'CARTÕES DE VISITA', 1, 190, 'ganho', now());
  insert into public.precos_praticados (sku, grupo_produto, quantidade, preco_total, resultado, criado_em) values (v_sku, 'CARTÕES DE VISITA', 1, 10, 'ganho', now() - interval '120 days');
  j2 := public.calcular_preco(v_sku);
  perform pg_temp.ck('âncora: 3 vendas em 90 dias entram (a de 120 dias não), limitadas pelo mercado',
    j2 ->> 'regra' = 'mercado_com_ancora_vendas' and (j2 ->> 'ancora_vendas')::numeric = 190 and (j2 ->> 'preco_total')::numeric <= 200 and (j2 ->> 'preco_total')::numeric >= (j ->> 'preco_total')::numeric, j2::text);
  insert into public.precos_praticados (sku, grupo_produto, quantidade, preco_total, resultado) select v_sku, 'CARTÕES DE VISITA', 1, 900, 'ganho' from generate_series(1, 5);
  j2 := public.calcular_preco(v_sku);
  perform pg_temp.ck('âncora: vendas acima do mercado nunca puxam o preço acima da mediana de mercado', (j2 ->> 'preco_total')::numeric <= 200, j2::text);
  delete from public.precos_praticados; delete from public.precos_mercado;

  -- ============================== 6. kit
  insert into public.kits (name, segment, price) values ('Kit teste', 'loja', 0) returning id into v_kit;
  insert into public.kit_items (kit_id, description, qty, sku) values (v_kit, 'Cartões', 1, v_sku), (v_kit, 'Panfletos', 1, v_sku2), (v_kit, 'Adesivos', 2, v_sku3);
  k := public.kit_preco(v_kit);
  perform pg_temp.ck('kit: preço calculado pelos SKUs, nunca abaixo do piso do conjunto', (k ->> 'preco')::numeric >= (select sum(c.custo * ki.qty) * 1.5 from public.kit_items ki join public.catalogo c on c.sku = ki.sku where ki.kit_id = v_kit), k::text);
  insert into public.precos_mercado (sku, chave_especificacao, fonte, preco, confianca)
    select s, (select especificacao_normalizada from public.catalogo where sku = s), f, 20.00, 'alta' from unnest(array[v_sku, v_sku2, v_sku3]) s cross join unnest(array['a.com.br', 'b.com.br', 'c.com.br']) f;
  k := public.kit_preco(v_kit);
  perform pg_temp.ck('kit: mercado muito abaixo não derruba o kit abaixo do piso do conjunto', (k ->> 'preco')::numeric >= (select sum(c.custo * ki.qty) * 1.5 from public.kit_items ki join public.catalogo c on c.sku = ki.sku where ki.kit_id = v_kit), k::text);
  delete from public.precos_mercado;

  -- ============================== 7. aprendizado: orçamentos alimentam precos_praticados e o ajuste semanal respeita limites
  insert into public.contacts (wa_id, name) values ('5531900001000', 'Aprendizado') returning id into v_c;
  for i in 1..9 loop     -- cartões: 1 ganho em 9 = 11%
    insert into public.orcamentos (contact_id, status) values (v_c, 'rascunho') returning id into v_o;
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, margem_liquida_pct)
      values (v_o, v_sku, 'Cartões', 1, v_piso + 300, 45);
    update public.orcamentos set status = 'enviado' where id = v_o;
    update public.orcamentos set status = case when i = 1 then 'pago' else 'expirado' end where id = v_o;
  end loop;
  for i in 1..9 loop     -- panfletos: 6 ganhos em 9 = 67%
    insert into public.orcamentos (contact_id, status) values (v_c, 'rascunho') returning id into v_o;
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, margem_liquida_pct) values (v_o, v_sku2, 'Panfleto', 1, 400, 30);
    update public.orcamentos set status = 'enviado' where id = v_o;
    update public.orcamentos set status = case when i <= 6 then 'pago' else 'perdido' end where id = v_o;
  end loop;
  for i in 1..7 loop     -- adesivos: 7 orçamentos, menos que o mínimo de 8
    insert into public.orcamentos (contact_id, status) values (v_c, 'rascunho') returning id into v_o;
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, margem_liquida_pct) values (v_o, v_sku3, 'Adesivo', 1, 300, 30);
    update public.orcamentos set status = 'enviado' where id = v_o;
    update public.orcamentos set status = 'expirado' where id = v_o;
  end loop;
  perform pg_temp.ck('aprendizado: cada orçamento e seu resultado entram em precos_praticados',
    (select count(*) from public.precos_praticados where grupo_produto = 'CARTÕES DE VISITA' and resultado = 'ganho') = 1
    and (select count(*) from public.precos_praticados where grupo_produto = 'PANFLETOS, FLYERS E FOLHETOS' and resultado = 'ganho') = 6);
  j := public.aprender_precos_semana(true);
  perform pg_temp.ck('aprendizado: simulação não grava', (j ->> 'simulado')::boolean and (select count(*) from public.ajustes_fator_preco) = 0 and (j ->> 'ajustes')::int = 2, j::text);
  j := public.aprender_precos_semana();
  perform pg_temp.ck('aprendizado: conversão 11% com margem acima da meta baixa o fator em 0,01 (0,93 para 0,92)',
    (select fator from public.fatores_competitivos where grupo_produto = 'CARTÕES DE VISITA') = 0.92, j::text);
  perform pg_temp.ck('aprendizado: conversão 67% sobe o fator em 0,01 (0,93 para 0,94)', (select fator from public.fatores_competitivos where grupo_produto = 'PANFLETOS, FLYERS E FOLHETOS') = 0.94, j::text);
  perform pg_temp.ck('aprendizado: grupo com menos de 8 orçamentos não muda', not exists (select 1 from public.fatores_competitivos where grupo_produto = 'ADESIVOS'));
  perform pg_temp.ck('aprendizado: cada ajuste fica registrado com antes, depois e motivo', (select count(*) from public.ajustes_fator_preco where fator_antes <> fator_depois and motivo is not null) = 2);
  update public.fatores_competitivos set fator = 0.90 where grupo_produto = 'CARTÕES DE VISITA';
  update public.fatores_competitivos set fator = 0.98 where grupo_produto = 'PANFLETOS, FLYERS E FOLHETOS';
  perform public.aprender_precos_semana();
  perform pg_temp.ck('aprendizado: respeita mínimo 0,90 e máximo 0,98', (select fator from public.fatores_competitivos where grupo_produto = 'CARTÕES DE VISITA') = 0.90 and (select fator from public.fatores_competitivos where grupo_produto = 'PANFLETOS, FLYERS E FOLHETOS') = 0.98);
  perform pg_temp.ck('aprendizado: orçamento de teste não conta', (select count(*) from public.precos_praticados pp join public.orcamentos o on o.id = pp.orcamento_id where o.teste) = 0);
  delete from public.fatores_competitivos; delete from public.ajustes_fator_preco; delete from public.precos_praticados;

  -- ============================== 8. condição especial como ferramenta
  perform pg_temp.ck('condição: aplicar_desconto antiga não existe mais', not exists (select 1 from pg_proc where proname = 'aplicar_desconto' and pronamespace = 'public'::regnamespace));
  insert into public.contacts (wa_id, name) values ('5531900002000', 'Cliente condição') returning id into v_c;
  insert into public.orders (contact_id, title) values (v_c, 'Pedido condição') returning id into v_ord;
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) values (v_ord, v_sku, 'Cartões', 1, v_custo, v_piso + 300) returning id into v_item;
  insert into public.orcamentos (contact_id, order_id, status) values (v_c, v_ord, 'rascunho') returning id into v_o;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, v_sku, 'Cartões', 1, v_piso + 300);
  j := public.oferecer_condicao_especial(v_o, 'G1');
  perform pg_temp.ck('condição: nunca antes de o orçamento ser enviado', j ->> 'tipo' = 'sem_condicao' and j ->> 'motivo' = 'orcamento_ainda_nao_enviado', j::text);
  update public.orcamentos set status = 'enviado' where id = v_o;
  select discount_pct into v_pct0 from public.orders where id = v_ord;
  j := public.oferecer_condicao_especial(v_o, 'G1');
  perform pg_temp.ck('condição: G1 devolve tipo, texto curto, valor e validade de 24 h', j ->> 'tipo' = 'desconto' and (j ->> 'valor')::numeric > 0 and j ->> 'texto_curto' is not null
    and (j ->> 'valida_ate')::timestamptz between now() + interval '23 hours' and now() + interval '25 hours' and (j ->> 'expira_horas')::numeric between 23 and 24.01, j::text);
  v_n := (j ->> 'orcamento_id')::uuid;
  perform pg_temp.ck('condição: gera orçamento atualizado com origem, status enviado e lucro líquido positivo',
    (select origem_id = v_o and status = 'enviado' and desconto_valor = (j ->> 'valor')::numeric from public.orcamentos where id = v_n)
    and (private.orcamento_financeiro(v_n) ->> 'lucro')::numeric >= 0);
  perform pg_temp.ck('condição: pedido ligado passa a cobrar o valor da condição (percentual para baixo, nunca concede mais)',
    (select round(f.gross - f.total, 2) <= (j ->> 'valor')::numeric and (j ->> 'valor')::numeric - round(f.gross - f.total, 2) < f.gross * 0.0001 + 0.01 from public.order_financials f where f.order_id = v_ord), j::text);
  perform pg_temp.ck('condição: o orçamento original continua com o preço normal', (select desconto_valor = 0 and status = 'enviado' from public.orcamentos where id = v_o));
  j2 := public.oferecer_condicao_especial(v_o, 'G3');
  perform pg_temp.ck('condição: segunda no mesmo orçamento é recusada', j2 ->> 'tipo' = 'sem_condicao', j2::text);
  perform public.condicao_registrar_link((j ->> 'condicao_id')::uuid, 'https://mpago.la/teste');
  perform pg_temp.ck('condição: link novo fica gravado na condição e no orçamento atualizado',
    (select link_pagamento = 'https://mpago.la/teste' from public.orcamentos where id = v_n) and (select link_anterior_invalidado_em is not null from public.condicoes_especiais where id = (j ->> 'condicao_id')::uuid));
  -- expiração
  update public.condicoes_especiais set valida_ate = now() - interval '1 minute' where id = (j ->> 'condicao_id')::uuid;
  insert into public.pagamentos (order_id, eh_link, link_ativo, link, valor, status, modo, expira_em) values (v_ord, true, true, 'https://mpago.la/teste', 100, 'pendente', 'teste', now() - interval '1 minute');
  j2 := public.expirar_condicoes_e_orcamentos();
  perform pg_temp.ck('expiração: condição expira, orçamento atualizado expira, preço volta ao normal e o link deixa de valer',
    (select resultado = 'expirada' from public.condicoes_especiais where id = (j ->> 'condicao_id')::uuid)
    and (select status = 'expirado' from public.orcamentos where id = v_n)
    and (select discount_pct = v_pct0 from public.orders where id = v_ord)
    and not exists (select 1 from public.pagamentos where order_id = v_ord and link_ativo), j2::text);
  j2 := public.oferecer_condicao_especial(v_o, 'G3');
  perform pg_temp.ck('expiração: a condição não se repete para o mesmo orçamento', j2 ->> 'tipo' = 'sem_condicao', j2::text);

  -- caçador de desconto: muitos orçamentos e nenhuma compra
  insert into public.contacts (wa_id, name) values ('5531900003000', 'Caçador') returning id into v_c;
  for i in 1..4 loop
    insert into public.orcamentos (contact_id, status) values (v_c, 'rascunho') returning id into v_o;
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, v_sku, 'Cartões', 1, v_piso + 300);
    update public.orcamentos set status = 'enviado' where id = v_o;
  end loop;
  j := public.oferecer_condicao_especial(v_o, 'G1');
  perform pg_temp.ck('caçador: 4 orçamentos sem compra não recebem condição e o dono é avisado',
    j ->> 'tipo' = 'sem_condicao' and j ->> 'motivo' = 'cacador_de_desconto' and exists (select 1 from public.alertas where tipo = 'cacador_de_desconto' and contact_id = v_c), j::text);
  -- padrão incomum: 3 condições consumidas e nenhuma compra
  insert into public.contacts (wa_id, name) values ('5531900004000', 'Padrão') returning id into v_c;
  for i in 1..3 loop
    insert into public.orcamentos (contact_id, status) values (v_c, 'enviado') returning id into v_o;
    insert into public.condicoes_especiais (orcamento_id, contact_id, degrau, gatilho, tipo, valor, texto_curto, valida_ate, resultado)
      values (v_o, v_c, 2, 'G1', 'desconto', 10, 'x', now() - interval '1 day', 'expirada');
  end loop;
  j := public.detectar_padroes_desconto();
  perform pg_temp.ck('padrão incomum: 3 condições consumidas e nenhuma compra geram alerta ao dono', (j ->> 'alertas_criados')::int >= 1 and exists (select 1 from public.alertas where tipo = 'padrao_desconto' and contact_id = v_c), j::text);
  j := public.detectar_padroes_desconto();
  perform pg_temp.ck('padrão incomum: não repete o alerta em 30 dias', (j ->> 'alertas_criados')::int = 0, j::text);

  -- relatório semanal
  j := public.relatorio_condicoes_semana(7, true);
  perform pg_temp.ck('relatório: traz degraus, consumo da margem e receita incremental', j ? 'degraus' and j ? 'consumo_da_margem_pct' and j ? 'receita_incremental_estimada', j::text);
  j := public.resumo_semanal_precos(true);
  perform pg_temp.ck('resumo semanal: texto para o dono e alerta de baixa gravidade', j ->> 'texto' like 'Resumo de preços%' and exists (select 1 from public.alertas where tipo = 'resumo_semanal_precos' and gravidade = 'baixa'), j::text);

  -- ============================== 9. política de desconto
  perform pg_temp.ck('política: percentual acima de 10% é recusado', pg_temp.erro('update public.politica_desconto set percentual = 12 where degrau = 3') is not null);
  perform pg_temp.ck('política: fração da gordura acima de 100% é recusada', pg_temp.erro('update public.politica_desconto set fracao_gordura_max = 1.2 where degrau = 2') is not null);
  j := public.simular_politica_desconto();
  perform pg_temp.ck('política: simulação do pior caso mostra lucro líquido >= 0 em todos os degraus', (j ->> 'seguro')::boolean and (select min((x ->> 'pior_lucro_liquido')::numeric) from jsonb_array_elements(j -> 'degraus') x) >= 0, j::text);
  j := public.simular_politica_desconto('[{"degrau":2,"percentual":10,"fracao_gordura_max":1,"desconto_max_reais":100000}]'::jsonb);
  perform pg_temp.ck('política: mesmo no extremo (10%, 100% da gordura, sem teto) o pior caso não dá prejuízo', (j ->> 'seguro')::boolean, j::text);
  j := public.salvar_politica_desconto('[{"degrau":2,"percentual":3,"fracao_gordura_max":0.5,"desconto_max_reais":60},{"degrau":3,"percentual":6,"fracao_gordura_max":0.5,"desconto_max_reais":60}]'::jsonb);
  perform pg_temp.ck('política: salvar aplica os novos valores e devolve a simulação', (select percentual = 3 and fracao_gordura_max = 0.5 from public.politica_desconto where degrau = 2) and (j ->> 'seguro')::boolean, j::text);
  update public.politica_desconto set percentual = 4, fracao_gordura_max = 0.6, desconto_max_reais = 80 where degrau = 2;
  update public.politica_desconto set percentual = 8, fracao_gordura_max = 0.6, desconto_max_reais = 80 where degrau = 3;

  -- ============================== 10. edição manual de preço no pedido (lucro líquido, piso duro e confirmação)
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  select (public.calcular_preco(v_sku) ->> 'piso')::numeric, (public.calcular_preco(v_sku) ->> 'piso_duro')::numeric into v_piso, v_duro;
  j := public.definir_preco_item_pedido(v_item, v_duro - 1, false, null, true);
  perform pg_temp.ck('preço manual: abaixo do piso duro aparece bloqueado com o lucro negativo', j ->> 'faixa' = 'abaixo_piso_duro' and not (j ->> 'ok')::boolean and (j ->> 'lucro_liquido')::numeric < 0, j::text);
  perform pg_temp.ck('preço manual: abaixo do piso duro é recusado até com confirmação', pg_temp.erro(format('select public.definir_preco_item_pedido(%L, %s, true, ''x'')', v_item, v_duro - 1)) like 'Preço bloqueado%');
  j := public.definir_preco_item_pedido(v_item, (v_duro + v_piso) / 2, false);
  perform pg_temp.ck('preço manual: entre o piso duro e o piso pede confirmação e não grava', (j ->> 'requer_confirmacao')::boolean and (select unit_price from public.order_items where id = v_item) = v_piso + 300, j::text);
  perform pg_temp.ck('preço manual: trava de banco impede reduzir abaixo do piso pelo CRM sem a função',
    pg_temp.erro(format('update public.order_items set unit_price = %s where id = %L', (v_duro + v_piso) / 2, v_item)) like 'Preço abaixo do piso%');
  j := public.definir_preco_item_pedido(v_item, (v_duro + v_piso) / 2, true, 'cliente antigo');
  perform pg_temp.ck('preço manual: com confirmação grava e registra no log', (select unit_price from public.order_items where id = v_item) = (v_duro + v_piso) / 2
    and exists (select 1 from public.precos_manuais_log where order_item_id = v_item and faixa = 'entre_pisos' and motivo = 'cliente antigo'), j::text);
  j := public.definir_preco_item_pedido(v_item, v_piso + 50, false);
  perform pg_temp.ck('preço manual: acima do piso é livre e mostra o lucro líquido', j ->> 'faixa' = 'ok' and (j ->> 'lucro_liquido')::numeric > 0, j::text);

  -- ============================== 11. segurança
  perform pg_temp.ck('segurança: anon não acessa as novas tabelas nem executa as novas funções',
    not has_table_privilege('anon', 'public.consultas_preco_mercado', 'select') and not has_table_privilege('anon', 'public.fatores_competitivos', 'select')
    and not has_table_privilege('anon', 'public.precos_manuais_log', 'select') and not has_table_privilege('anon', 'public.saude_precos', 'select')
    and not has_function_privilege('anon', 'public.oferecer_condicao_especial(uuid,text)', 'execute')
    and not has_function_privilege('anon', 'public.registrar_pesquisa_mercado(uuid,jsonb,integer,text,integer,integer)', 'execute')
    and not has_function_privilege('anon', 'public.definir_preco_item_pedido(uuid,numeric,boolean,text,boolean)', 'execute'));
  perform pg_temp.ck('segurança: RLS ligada nas novas tabelas', (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in ('fatores_competitivos', 'ajustes_fator_preco', 'consultas_preco_mercado', 'fontes_pesquisa', 'precos_manuais_log') and not c.relrowsecurity) = 0);

  -- ============================== 12. SIMULAÇÃO: 1.000 combinações aleatórias nunca geram prejuízo nem preço abaixo do piso_duro
  perform setseed(0.3);
  perform set_config('request.jwt.claim.role', 'service_role', true);
  for i in 1..1000 loop
    select sku, custo, quantidade into v_sorteio from public.catalogo where active and vendavel order by random() limit 1;
    v_qtd := 1 + floor(random() * 5)::int;
    v_ent := (array[null, 'bike', 'uber', 'retirada'])[1 + floor(random() * 4)::int];
    v_gat := (array['G1', 'G2', 'G3'])[1 + floor(random() * 3)::int];
    v_tipo := (array['sem_mercado', 'muito_abaixo', 'abaixo', 'igual', 'acima', 'outlier'])[1 + floor(random() * 6)::int];
    delete from public.precos_mercado;
    delete from public.consultas_preco_mercado;
    if v_tipo <> 'sem_mercado' then
      for v_fonte in 1..(1 + floor(random() * 3)::int) loop
        insert into public.precos_mercado (sku, chave_especificacao, fonte, preco, confianca)
        values (v_sorteio.sku, (select especificacao_normalizada from public.catalogo where sku = v_sorteio.sku), 'f' || v_fonte,
          round((v_sorteio.custo * case v_tipo when 'muito_abaixo' then 0.3 + random() * 0.4 when 'abaixo' then 0.9 + random() * 0.4
                                                when 'igual' then 1.5 + random() * 0.6 when 'acima' then 2.5 + random() * 3 else 1.5 + random() * 0.6 end)::numeric, 2), 'alta');
      end loop;
      if v_tipo = 'outlier' then
        insert into public.precos_mercado (sku, chave_especificacao, fonte, preco, confianca, outlier)
        values (v_sorteio.sku, (select especificacao_normalizada from public.catalogo where sku = v_sorteio.sku), 'fx', v_sorteio.custo * 0.1, 'alta', true);
      end if;
    end if;
    j := public.calcular_preco(v_sorteio.sku, v_qtd, jsonb_build_object('entrega', v_ent));
    v_preco := (j ->> 'preco_total')::numeric;
    if v_preco < (j ->> 'piso_duro')::numeric or (j ->> 'lucro_liquido')::numeric < 0 then v_neg := v_neg + 1; end if;
    v_min_folga := least(v_min_folga, v_preco - (j ->> 'piso_duro')::numeric);

    insert into public.contacts (wa_id, name) values ('5599' || lpad(i::text, 8, '0'), 'Sim ' || i) returning id into v_c;
    insert into public.orcamentos (contact_id, status, entrega, frete_valor, arte_modo, arte_valor, bairro)
    values (v_c, 'rascunho', case when v_ent = 'retirada' then 'retirada' else v_ent end,
            case when v_ent = 'uber' and random() < 0.5 then 25 else 0 end,
            (array['nenhuma', 'paga'])[1 + floor(random() * 2)::int], 0, (array['Centro', 'Savassi', 'Contagem'])[1 + floor(random() * 3)::int]);
    update public.orcamentos set arte_valor = case when arte_modo = 'paga' then 39.90 else 0 end where contact_id = v_c;
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario)
      select id, v_sorteio.sku, 'Item', v_qtd, round(v_preco / v_qtd, 2) from public.orcamentos where contact_id = v_c returning orcamento_id into v_o;
    -- preço por unidade arredondado pode perder centavos: sobe 1 centavo por unidade até cobrir o piso duro do conjunto (a regra do orçamento é a do banco)
    update public.orcamento_itens set preco_unitario = preco_unitario + 0.01 where orcamento_id = v_o and preco_unitario * quantidade < v_preco;
    begin
      update public.orcamentos set status = 'enviado' where id = v_o;
    exception when others then
      v_neg := v_neg + 1;       -- orçamento recusado pelas travas com o preço de calcular_preco = defeito
      continue;
    end;
    v_tentativas := v_tentativas + 1;
    j2 := public.oferecer_condicao_especial(v_o, v_gat);
    if j2 ->> 'tipo' <> 'sem_condicao' then
      v_ok_cond := v_ok_cond + 1;
      v_fin := private.orcamento_financeiro((j2 ->> 'orcamento_id')::uuid);
      v_lucro := (v_fin ->> 'lucro')::numeric;
      v_min_lucro := least(v_min_lucro, v_lucro);
      if v_lucro < 0 or (v_fin ->> 'receita_itens_liquida')::numeric + (select arte_valor + frete_valor from public.orcamentos where id = (j2 ->> 'orcamento_id')::uuid) < (v_fin ->> 'receita_piso_duro')::numeric - 0.005 then
        v_neg := v_neg + 1;
      end if;
      v_cenarios := jsonb_set(v_cenarios, array[j2 ->> 'tipo'], to_jsonb(coalesce((v_cenarios ->> (j2 ->> 'tipo'))::int, 0) + 1));
    end if;
  end loop;
  perform pg_temp.ck(format('simulação: 1.000 combinações (item, quantidade, mercado, frete, gatilho): %s com condição, nenhuma com prejuízo ou abaixo do piso_duro', v_ok_cond),
    v_neg = 0 and v_tentativas >= 900, format('violações=%s, orçamentos=%s, condições=%s (%s), menor lucro com condição=%s, menor folga do preço sobre o piso duro=%s', v_neg, v_tentativas, v_ok_cond, v_cenarios, v_min_lucro, v_min_folga));

  -- Relatório. A mensagem de "erro" no final é proposital: ela desfaz tudo o que o teste criou.
  select count(*), string_agg(format('%s %s%s', case when ok then 'OK    ' else 'FALHA ' end, nome, case when ok then '' else ' => ' || coalesce(detalhe, '') end), E'\n' order by n),
         string_agg(nome || ' => ' || coalesce(detalhe, ''), E'\n' order by n) filter (where not ok)
    into v_total, v_relatorio, v_falhas
  from _res;
  if v_falhas is not null then
    raise exception E'TESTES FALHARAM (nada foi gravado):\n%\n\nRelatório completo:\n%', v_falhas, v_relatorio;
  end if;
  raise exception E'OK: % testes passaram. Esta mensagem de erro é proposital, desfaz tudo o que o teste criou (nada foi gravado).\n%\n%', v_total, v_relatorio, (select detalhe from _res where nome like 'simulação:%');
end $$;
