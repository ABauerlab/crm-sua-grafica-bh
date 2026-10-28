-- Tabela de validação da Etapa 3: preço sugerido por especificação e exemplos da escada de condição especial.
-- Rodar: psql -h ... -f supabase/tests/tabela-etapa3.sql   (usa BEGIN/ROLLBACK: nada fica gravado).
-- Em produção (depois de aplicar as migrations) a mesma consulta mostra o catálogo real; o mercado vem das pesquisas gravadas em precos_mercado.
-- No ambiente local o catálogo é FICTÍCIO e o mercado é SIMULADO (quantas fontes, quanto mais barato/caro que o custo). Isto prova a fórmula, não o mercado real.
begin;
select set_config('request.jwt.claim.role', 'service_role', true);

create function pg_temp.brl(n numeric) returns text language sql immutable as $f$ select replace(replace(replace(to_char(n, 'FM999G990D00'), ',', '_'), '.', ','), '_', '.') $f$;

create temp table _cen (sku text, mult numeric[], rotulo text);
insert into _cen values
  ('CFV02',  array[2.6, 2.7, 2.8],       '3 fontes consistentes'),
  ('CFV02B', array[2.4, 2.5],            '2 fontes'),
  ('CFV02D', array[2.2],                 '1 fonte'),
  ('CFV10',  '{}'::numeric[],                    'sem mercado'),
  ('CFV20',  array[0.5, 0.55, 0.6],      'mercado muito abaixo do piso'),
  ('PFL01',  array[2.9, 3.0, 3.1, 9.0],  '3 fontes e 1 outlier'),
  ('PFL02B', array[2.3, 2.4, 2.5],       '3 fontes consistentes'),
  ('ADV01',  array[2.8, 3.0],            '2 fontes'),
  ('ADV01C', '{}'::numeric[],                    'sem mercado'),
  ('ADV02B', array[1.1, 1.2, 1.25],      'mercado abaixo do piso'),
  ('BAN01',  array[3.2, 3.4, 3.6],       '3 fontes consistentes'),
  ('TAG01B', array[2.1, 2.2],            '2 fontes'),
  ('IMG01',  array[1.9],                 '1 fonte');
insert into public.precos_mercado (sku, chave_especificacao, fonte, preco, confianca)
  select c.sku, coalesce(nullif(k.especificacao_normalizada, ''), c.sku), 'concorrente' || g.n, round(k.custo * g.m, 2), 'alta'
    from _cen c join public.catalogo k on k.sku = c.sku
    cross join lateral unnest(c.mult) with ordinality as g (m, n);
update public.precos_mercado set outlier = true, motivo_descarte = 'outlier' where sku = 'PFL01' and fonte = 'concorrente4';   -- mesma regra de registrar_pesquisa_mercado

do $$
declare r record; j jsonb; t0 timestamptz; ms numeric; n integer := 0;
begin
  raise notice '| SKU | Quantidade | Cenário de mercado | Custo | Mediana de mercado | Fontes | Preço sugerido | Piso | Piso duro | Margem líquida | Confiança | Regra | Não competitivo | Cálculo (ms) |';
  raise notice '|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|---:|';
  for r in select c.sku, c.rotulo, k.custo, k.quantidade from _cen c join public.catalogo k on k.sku = c.sku order by c.sku loop
    t0 := clock_timestamp();
    j := public.calcular_preco(r.sku, 1, '{}'::jsonb);
    ms := round(extract(epoch from (clock_timestamp() - t0)) * 1000, 1);
    raise notice '| % | % | % | R$ % | % | % | R$ % | R$ % | R$ % | % %% | % | % | % | % |', r.sku, r.quantidade, r.rotulo, pg_temp.brl(r.custo),
      coalesce('R$ ' || pg_temp.brl((j ->> 'mercado_mediana')::numeric), 'n/d'), j ->> 'fontes_mercado', pg_temp.brl((j ->> 'preco_total')::numeric),
      pg_temp.brl((j ->> 'piso')::numeric), pg_temp.brl((j ->> 'piso_duro')::numeric), replace(j ->> 'margem_liquida_pct', '.', ','), j ->> 'confianca', j ->> 'regra',
      case when (j ->> 'nao_competitivo')::boolean then 'sim' else 'não' end, ms;
  end loop;
end $$;

-- Escada da condição especial: cada caso é um orçamento criado para o exemplo (acima do piso por valores diferentes)
do $$
declare
  v_c uuid; v_o uuid; v_piso numeric; j jsonb; v_cont integer := 0; r record; v_preco numeric; v_duro numeric; v_f jsonb;
begin
  raise notice '';
  raise notice '| Exemplo | Gatilho | Preço do orçamento | Piso | Gordura | Resultado | Valor | Degrau | Lucro líquido depois |';
  raise notice '|---|---|---:|---:|---:|---|---:|---:|---:|';
  for r in
    select * from (values
      ('Degrau 2 (G1) em cartões', 'CFV02', 'G1', 300::numeric, null::text, 0::numeric),
      ('Degrau 3 (G3), teto de R$ 80', 'CFV02', 'G3', 3000::numeric, null::text, 0::numeric),
      ('Degrau 1 (G1): frete grátis sem mínimo', 'CFV02', 'G1', 40::numeric, 'Savassi', 25::numeric),
      ('Gordura zero (preço no piso)', 'CFV02', 'G1', 0::numeric, null::text, 0::numeric),
      ('Desconto calculado abaixo de R$ 5', 'CFV02', 'G1', 6::numeric, null::text, 0::numeric),
      ('Degrau 2 (G2) em adesivos', 'ADV01', 'G2', 150::numeric, null::text, 0::numeric)
    ) t (nome, sku, gat, folga, bairro, frete)
  loop
    v_cont := v_cont + 1;
    insert into public.contacts (wa_id, name) values ('55119000' || lpad(v_cont::text, 5, '0'), 'Exemplo ' || v_cont) returning id into v_c;
    v_piso := ceil(greatest((select custo from public.catalogo where sku = r.sku) * 1.5,
                             private.receita_para_lucro((select custo from public.catalogo where sku = r.sku), private.custos_operacionais(case when r.frete > 0 then 'uber' else null end), 60, null)) * 100) / 100;
    insert into public.orcamentos (contact_id, status, bairro, frete_valor, entrega) values (v_c, 'rascunho', r.bairro, r.frete, case when r.frete > 0 then 'uber' else null end) returning id into v_o;
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_o, r.sku, 'Exemplo', 1, v_piso + r.folga);
    update public.orcamentos set status = 'enviado' where id = v_o;
    j := public.oferecer_condicao_especial(v_o, r.gat);
    raise notice '| % | % | R$ % | R$ % | R$ % | % | % | % | % |', r.nome, r.gat, pg_temp.brl(v_piso + r.folga), pg_temp.brl(v_piso), pg_temp.brl(r.folga),
      case when j ->> 'tipo' = 'sem_condicao' then 'sem condição (' || coalesce(j ->> 'motivo', '') || ')' else j ->> 'texto_curto' end,
      coalesce('R$ ' || pg_temp.brl((j ->> 'valor')::numeric), '-'), coalesce(j ->> 'degrau', '-'),
      coalesce('R$ ' || pg_temp.brl((private.orcamento_financeiro((j ->> 'orcamento_id')::uuid) ->> 'lucro')::numeric), '-');
  end loop;
end $$;
rollback;
