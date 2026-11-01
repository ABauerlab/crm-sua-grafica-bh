-- Etapa 7B, Blocos C e D: fórmulas por dimensão, complementares, melhorias sugeridas, experimentos, indicações, painel Comercial.
begin;
create temp table _t (n int, ok boolean, nome text);
create or replace function pg_temp.chk(p_ok boolean, p_nome text) returns void language plpgsql as $$
begin insert into _t values ((select count(*) + 1 from _t), coalesce(p_ok, false), p_nome); end $$;
create or replace function pg_temp.erro_ok(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
do $$
declare v_staff uuid := gen_random_uuid(); v_a uuid; v_b uuid; v_sku text; v_sku2 text; r jsonb; v_exp uuid; v_cod text; v_custo numeric; v_o uuid;
begin
  perform set_config('request.jwt.claim.role', 'service_role', true);
  insert into auth.users (id, email) values (v_staff, 'contato.bauerlab@gmail.com');
  insert into public.profiles (id, name, role) values (v_staff, 'Dono', 'admin');
  update public.app_settings set value = jsonb_set(value, '{email}', '"contato.bauerlab@gmail.com"') where key = 'owner';
  insert into public.contacts (wa_id, name) values ('5531900000101', 'Indicador') returning id into v_a;
  insert into public.contacts (wa_id, name) values ('5531900000102', 'Indicado') returning id into v_b;
  select sku into v_sku from public.catalogo where vendavel and active and custo > 0 order by md5(sku) limit 1;
  select sku into v_sku2 from public.catalogo where vendavel and active and custo > 0 and sku <> v_sku order by md5(sku) limit 1;

  -- C: sem fórmula validada não há custo (não gera oferta definitiva)
  perform pg_temp.chk(private.custo_por_dimensao(v_sku, 600, 900) is null, 'C: sem fórmula validada o custo por dimensão é nulo');
  insert into public.catalogo_formulas (sku, custo_m2, custo_minimo, origem, erro_max_amostras_pct, ativo, largura_min_mm, largura_max_mm) values (v_sku, 40, 10, 'amostras_validadas', 0.4, true, 100, 2000);
  v_custo := private.custo_por_dimensao(v_sku, 1000, 1000);
  perform pg_temp.chk(v_custo = 40, 'C: fórmula por m² validada calcula o custo (1 m² = R$ 40)');
  perform pg_temp.chk(private.custo_por_dimensao(v_sku, 200, 100) = 10, 'C: respeita o mínimo');
  perform pg_temp.chk(private.custo_por_dimensao(v_sku, 5000, 100) is null, 'C: fora dos limites de dimensão não gera custo');
  update public.catalogo_formulas set erro_max_amostras_pct = 3 where sku = v_sku;
  perform pg_temp.chk(private.custo_por_dimensao(v_sku, 1000, 1000) is null, 'C: fórmula com erro acima de 1% não vale');
  perform pg_temp.chk(has_function_privilege('anon', 'private.custo_por_dimensao(text,integer,integer)', 'execute') = false, 'C: anon não executa o custo por dimensão');

  -- D3: complementares
  insert into public.produtos_complementares (grupo_base, sku_complementar, quantidade_minima, motivo) values ((select grupo_produto from public.catalogo where sku = v_sku), v_sku2, 500, 'divulgação junto');
  perform pg_temp.chk(not (public.complementar_sugerir(v_sku, 100) ->> 'sugerir')::boolean, 'D3: quantidade pequena não gera sugestão');
  perform pg_temp.chk((public.complementar_sugerir(v_sku, 1000) ->> 'sugerir')::boolean is not null, 'D3: com oportunidade real a regra responde');

  -- D5: melhorias sugeridas nunca mudam o que é crítico sem autorização
  perform pg_temp.chk(pg_temp.erro_ok('insert into public.melhorias_sugeridas (alvo, problema, evidencia, melhoria, exige_autorizacao) values (''desconto'', ''x'', ''y'', ''z'', false)'), 'D5: alvo crítico exige autorização do dono');
  perform pg_temp.chk(pg_temp.erro_ok('insert into public.melhorias_sugeridas (alvo, problema, evidencia, melhoria, exige_autorizacao) values (''prompt'', ''x'', ''y'', ''z'', false)'), 'D5: prompt exige autorização do dono');
  insert into public.melhorias_sugeridas (alvo, problema, evidencia, melhoria, exige_autorizacao) values ('conhecimento', 'dúvida repetida', '5 conversas', 'novo trecho', false);
  perform pg_temp.chk(true, 'D5: ajuste de conhecimento pode ser marcado como baixo risco');
  perform pg_temp.chk((public.estudo_diario_coletar() ->> 'dia') is not null, 'D5: coleta dos dados do dia funciona');

  -- D6: experimentos
  perform pg_temp.chk(pg_temp.erro_ok('insert into public.experimentos (hipotese, tipo, variantes) values (''x'', ''preco'', ''["a","b"]''::jsonb)'), 'D6: nunca experimenta regra crítica (só texto e momento)');
  insert into public.experimentos (hipotese, tipo, variantes, status, amostra_minima) values ('saudação curta converte mais', 'texto', '["curta","longa"]', 'rodando', 100) returning id into v_exp;
  perform pg_temp.chk(public.experimento_variante(v_exp, v_a) = public.experimento_variante(v_exp, v_a), 'D6: o mesmo contato sempre cai na mesma variante');
  perform public.experimento_variante(v_exp, v_b);
  r := public.experimento_resultado(v_exp);
  perform pg_temp.chk(r ->> 'vencedor' is null and r ->> 'conclusao' like 'inconclusivo%', 'D6: amostra pequena nunca declara vencedor');

  -- D7: indicações
  v_cod := public.indicacao_codigo(v_a);
  perform pg_temp.chk(v_cod like 'SG%' and public.indicacao_codigo(v_a) = v_cod, 'D7: código de indicação estável por cliente');
  perform pg_temp.chk((public.indicacao_registrar(v_cod, v_b) ->> 'ok')::boolean and not (public.indicacao_registrar(v_cod, v_a) ->> 'ok')::boolean, 'D7: registra quem indicou e impede autoindicação');
  insert into public.orders (contact_id, title, payment_method) values (v_b, 'compra do indicado', 'pix') returning id into v_o;
  update public.orders set payment_status = 'aprovado' where id = v_o;
  perform pg_temp.chk((select compra_valida_em from public.indicacoes where indicado_id = v_b) is not null and (select custo_beneficio from public.indicacoes where indicado_id = v_b) = 0, 'D7: compra válida registrada e sem recompensa até o dono definir');

  -- D1/D4: painel e rentabilidade só para o dono
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  r := public.painel_comercial();
  perform pg_temp.chk(r ? 'aquisicao' and r ? 'conversao' and r ? 'rentabilidade' and r ? 'fidelizacao' and r ? 'operacao', 'D1: painel Comercial traz os cinco grupos de indicadores');
  perform pg_temp.chk((select count(*) from public.rentabilidade_cliente(10)) >= 1, 'D4: rentabilidade por cliente lista quem comprou');
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  perform pg_temp.chk(pg_temp.erro_ok('select public.painel_comercial()'), 'D1: quem não é o dono não vê o painel');
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
