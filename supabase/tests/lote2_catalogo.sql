-- Testes do Lote 2 (catálogo, sinônimos, acabamento, gêmeos, anúncio). Rodam em transação desfeita:
-- o bloco termina com um raise exception que traz o resultado ("LOTE2_OK ..." quando tudo passa).
do $t$
declare
  r jsonb; v_skus text[]; v_falhas text[] := '{}'; v_conv uuid; v_res jsonb := '{}'::jsonb;
begin
  -- 1) raspadinha -> RASP*
  r := public.buscar_produto('raspadinha', 300, '{}');
  select array_agg(o ->> 'sku') into v_skus from jsonb_array_elements(r -> 'opcoes') o;
  v_res := v_res || jsonb_build_object('raspadinha', v_skus);
  if v_skus is null or not (v_skus[1] ~ '^RASP') then v_falhas := v_falhas || 'raspadinha nao retornou RASP*'; end if;

  -- 2) carteirinha pvc e plaquinha pvc
  r := public.buscar_produto('carteirinha pvc', 100, '{}');
  select array_agg(o ->> 'sku') into v_skus from jsonb_array_elements(r -> 'opcoes') o;
  v_res := v_res || jsonb_build_object('carteirinha', v_skus);
  if v_skus is null then v_falhas := v_falhas || 'carteirinha sem resultado'; end if;
  r := public.buscar_produto('plaquinha pvc', 1, '{}');
  select array_agg(o ->> 'sku') into v_skus from jsonb_array_elements(r -> 'opcoes') o;
  v_res := v_res || jsonb_build_object('plaquinha', v_skus);
  if v_skus is null or not (v_skus[1] ~ '^PLACA') then v_falhas := v_falhas || 'plaquinha nao retornou PLACA*'; end if;

  -- 3) verniz localizado frente e verso, 1000 -> CVL1000 no topo, com acabamento aplicado
  r := public.buscar_produto('cartao de visita verniz localizado frente e verso', 1000, '{}');
  select array_agg(o ->> 'sku') into v_skus from jsonb_array_elements(r -> 'opcoes') o;
  v_res := v_res || jsonb_build_object('verniz_fv', v_skus, 'verniz_com_acab', r -> 'acabamento_aplicado', 'verniz_nao_encontrado', r -> 'acabamento_nao_encontrado');
  if v_skus is null or v_skus[1] <> 'CVL1000' then v_falhas := v_falhas || 'verniz FV 1000 nao trouxe CVL1000 no topo'; end if;
  if coalesce((r ->> 'acabamento_nao_encontrado')::boolean, true) then v_falhas := v_falhas || 'verniz marcado como nao encontrado'; end if;

  -- 4) acabamento inexistente: sinal explícito e orientação
  r := public.buscar_produto('cartao de visita holografica frente e verso', 1000, '{}');
  v_res := v_res || jsonb_build_object('holo_nao_encontrado', r -> 'acabamento_nao_encontrado');
  -- (se existir holografia no catálogo o sinal fica false; só exigimos coerência com a orientação)
  if coalesce((r ->> 'acabamento_nao_encontrado')::boolean, false) and (r ->> 'orientacao_acabamento') is null then v_falhas := v_falhas || 'sem orientacao quando acabamento nao encontrado'; end if;
  r := public.buscar_produto('cartao de visita', 1000, jsonb_build_object('acabamento', 'soft touch'));
  v_res := v_res || jsonb_build_object('soft_filtro', r -> 'acabamento_aplicado');

  -- 5) hot stamping pelo filtro: só cartões com hot stamping
  r := public.buscar_produto('cartao de visita', 1000, jsonb_build_object('acabamento', 'hot stamping'));
  select array_agg(o ->> 'sku') into v_skus from jsonb_array_elements(r -> 'opcoes') o;
  v_res := v_res || jsonb_build_object('hot_filtro', v_skus);
  if v_skus is null then v_falhas := v_falhas || 'hot stamping sem opcoes';
  elsif exists (select 1 from unnest(v_skus) s where not exists (select 1 from public.catalogo_acabamento a where a.sku = s and 'hot_stamping' = any (a.tags))) then
    v_falhas := v_falhas || 'hot stamping retornou card sem hot stamping';
  end if;

  -- 6) hot stamping pelo anúncio da conversa (determinístico, sem depender do prompt)
  select cv.id into v_conv from public.conversations cv limit 1;
  if v_conv is not null then
    update public.conversations set last_referral = jsonb_build_object('headline', 'Cartao de visita com Hot Stamping', 'source_id', 'teste-lote2') where id = v_conv;
    r := public.buscar_produto('cartao de visita', 1000, jsonb_build_object('conversation_id', v_conv));
    select array_agg(o ->> 'sku') into v_skus from jsonb_array_elements(r -> 'opcoes') o;
    v_res := v_res || jsonb_build_object('hot_anuncio', v_skus, 'hot_origem', r -> 'acabamento_origem');
    if r ->> 'acabamento_origem' is distinct from 'anuncio' then v_falhas := v_falhas || 'anuncio nao aplicou o acabamento';
    elsif exists (select 1 from unnest(v_skus) s where not exists (select 1 from public.catalogo_acabamento a where a.sku = s and 'hot_stamping' = any (a.tags))) then
      v_falhas := v_falhas || 'anuncio hot stamping retornou card sem hot stamping';
    end if;
  end if;

  -- 7) gêmeos: rollup estrutura completa diferencia ROLLUP001 x COM0013
  r := public.buscar_produto('rollup estrutura completa', 1, '{}');
  select array_agg((o ->> 'sku') || '=' || coalesce(o ->> 'diferencial', '?')) into v_skus from jsonb_array_elements(r -> 'opcoes') o;
  v_res := v_res || jsonb_build_object('rollup', v_skus);
  if not exists (select 1 from jsonb_array_elements(r -> 'opcoes') o where o ->> 'sku' = 'ROLLUP001' and (o ->> 'diferencial') ilike '%KIT COMPLETO%') then v_falhas := v_falhas || 'ROLLUP001 sem rotulo de kit completo'; end if;
  r := public.buscar_produto('rollup estrutura completa', 1, '{}');
  if not exists (select 1 from jsonb_array_elements(r -> 'opcoes') o where o ->> 'sku' = 'COM0013' and (o ->> 'diferencial') ilike '%SEM ESTRUTURA%' and (o ->> 'preco')::numeric = 204.23) then v_falhas := v_falhas || 'COM0013 ausente ou sem rotulo SO A LONA'; end if;

  -- 8) regressão obrigatória: panfleto 10x15cm frente e verso 1000 -> PA65G6 no topo
  r := public.buscar_produto('panfleto 10x15cm frente e verso', 1000, '{}');
  select array_agg(o ->> 'sku') into v_skus from jsonb_array_elements(r -> 'opcoes') o;
  v_res := v_res || jsonb_build_object('panfleto', v_skus);
  if v_skus is null or v_skus[1] <> 'PA65G6' then v_falhas := v_falhas || 'regressao panfleto: PA65G6 nao esta no topo'; end if;

  -- 9) cobertura da base de acabamento
  v_res := v_res || jsonb_build_object('acabamentos_com_tag', (select count(*) from public.catalogo_acabamento where cardinality(tags) > 0), 'gemeos', (select count(*) from public.catalogo_gemeos));

  if cardinality(v_falhas) > 0 then raise exception 'LOTE2_FALHA % || %', v_falhas, v_res; end if;
  raise exception 'LOTE2_OK %', v_res;
end;
$t$;
