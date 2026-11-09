-- Ajustes da carga da planilha (09/11/2026):
-- 1) calcular_preco devolve o preço com 2 casas (antes saía 151.90000 por causa da área 1.000).
-- 2) SKU só com dígitos: a planilha traz "0001" e o catálogo guarda "1". A comparação usa o código sem zeros à esquerda.
create or replace function private.sku_planilha(p_sku text)
returns text language sql immutable set search_path = '' as $$
  select case when p_sku ~ '^0+[0-9]+$' then ltrim(p_sku, '0') else p_sku end;
$$;

create or replace function public.calcular_preco(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable set search_path = '' as $function$
declare
  pr public.parametros_comerciais%rowtype;
  prod record;
  j jsonb;
  v_qtd integer := greatest(coalesce(p_quantidade, 1), 1);
  v_metodo text := case when p_contexto ->> 'simular_metodo' = 'true' then p_contexto ->> 'metodo' end;
  v_outros_receita numeric := coalesce((p_contexto ->> 'receita_outros')::numeric, 0);
  v_outros_custo numeric := coalesce((p_contexto ->> 'custo_outros')::numeric, 0);
  v_largura_mm integer := nullif((p_contexto ->> 'largura_mm')::integer, 0);
  v_altura_mm integer := nullif((p_contexto ->> 'altura_mm')::integer, 0);
  v_area_m2 numeric := 1.000; v_e_m2 boolean := false;
  v_custo_item numeric; v_custo_total numeric; v_extra numeric;
  v_piso numeric; v_piso_duro numeric; v_preco numeric; v_receita numeric; v_lucro numeric;
  v_regra text := 'planilha';
  v_avisos text[] := '{}';
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select c.sku, c.custo, c.active, c.vendavel, c.tamanho_mm, c.categoria, c.descricao, c.preco_venda, c.preco_mercado_ref
    into prod from public.catalogo c where c.sku = p_sku;
  if not found or not prod.active then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  if not prod.vendavel then return jsonb_build_object('ok', false, 'erro', 'item_nao_vendavel'); end if;

  -- sem preço de planilha (ou dono voltou ao modo mercado): fórmula antiga, com aviso
  if pr.fonte_preco <> 'planilha' or prod.preco_venda is null then
    j := private.calcular_preco_mercado(p_sku, p_quantidade, p_contexto);
    if pr.fonte_preco = 'planilha' and coalesce((j ->> 'ok')::boolean, false) then
      j := jsonb_set(j, '{avisos}', coalesce(j -> 'avisos', '[]'::jsonb) || '["sem_preco_de_planilha"]'::jsonb);
    end if;
    return j;
  end if;

  -- produtos por m²: o preço da planilha é por 1 m², com faturamento mínimo de 1 m² por peça
  if prod.tamanho_mm = '1000 x 1000' or prod.tamanho_mm ilike '%metro%' or prod.descricao ilike '%metro quadrado%' or prod.descricao ilike '%(m²)%' then
    v_e_m2 := true;
    if v_largura_mm is not null and v_altura_mm is not null then
      v_area_m2 := round((v_largura_mm::numeric * v_altura_mm::numeric) / 1000000.0, 3);
      if v_area_m2 < 1.000 then v_area_m2 := 1.000; v_avisos := array_append(v_avisos, 'faturamento_minimo_1m2'); end if;
    end if;
  end if;

  v_custo_item := prod.custo * v_area_m2 * v_qtd;
  v_custo_total := v_custo_item + v_outros_custo;
  v_extra := private.custos_operacionais(p_contexto ->> 'entrega');
  v_preco := prod.preco_venda * v_area_m2 * v_qtd;
  if v_area_m2 <> 1 or v_qtd > 1 then v_preco := private.teto_90(v_preco); end if;
  v_preco := round(v_preco, 2);

  -- piso da planilha: custo x 1,5 e lucro bruto mínimo por pedido; piso duro: lucro líquido zero (nunca prejuízo)
  v_piso := ceil(greatest(v_custo_item * pr.multiplicador_piso, v_custo_item + pr.lucro_bruto_minimo) * 100) / 100;
  v_piso_duro := ceil((private.receita_para_lucro(v_custo_total, v_extra, 0, v_metodo) - v_outros_receita) * 100) / 100;
  if v_preco < v_piso then
    v_preco := private.teto_90(v_piso); v_regra := 'piso'; v_avisos := array_append(v_avisos, 'planilha_abaixo_do_piso');
  end if;
  if v_preco < v_piso_duro then
    v_preco := private.teto_90(v_piso_duro); v_regra := 'piso'; v_avisos := array_append(v_avisos, 'planilha_abaixo_do_piso_duro');
  end if;

  v_receita := v_preco + v_outros_receita;
  v_lucro := private.lucro(v_receita, v_custo_total, v_extra, v_metodo);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku, 'quantidade', v_qtd,
    'preco_unitario', round(v_preco / v_qtd, 2), 'preco_total', v_preco,
    'calculado_por_m2', v_e_m2, 'area_m2_por_unidade', v_area_m2,
    'largura_mm', v_largura_mm, 'altura_mm', v_altura_mm,
    'regra', v_regra, 'confianca', 'alta',
    'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1), 'lucro_liquido', v_lucro,
    'lucro_bruto', round(v_preco - v_custo_item, 2),
    'lucro_ok', v_lucro >= 0 and v_preco - v_custo_item >= pr.lucro_bruto_minimo - 0.05,
    'piso', round(v_piso, 2), 'piso_duro', round(v_piso_duro, 2),
    'nao_competitivo', false, 'fontes_mercado', 0,
    'mercado_mediana', round(prod.preco_mercado_ref * v_area_m2 * v_qtd, 2),
    'consulta_mercado_id', null, 'fator_competitivo', null, 'ancora_vendas', null,
    'avisos', to_jsonb(v_avisos));
end;
$function$;

create or replace function public.aplicar_planilha_precos(p_token text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_atualizados integer; v_custos integer; v_travas integer; v_sem_catalogo integer; v_sem_preco integer; v_vitrine jsonb;
  v_exemplos_trava jsonb; v_exemplos_sem jsonb;
begin
  if not private.pode_importar_precos(p_token) then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;

  -- linhas que furariam a trava (custo x 1,5 ou lucro bruto mínimo) não entram: o SKU fica com a fórmula antiga e vai ao relatório
  select count(*), coalesce(jsonb_agg(s.sku) filter (where s.rn <= 20), '[]'::jsonb) into v_travas, v_exemplos_trava
    from (select p.sku, row_number() over (order by p.sku) rn from public.planilha_precos_import p
           where p.preco_venda < p.custo * pr.multiplicador_piso - 0.005 or p.preco_venda - p.custo < pr.lucro_bruto_minimo - 0.005) s;

  select count(*), coalesce(jsonb_agg(s.sku) filter (where s.rn <= 20), '[]'::jsonb) into v_sem_catalogo, v_exemplos_sem
    from (select p.sku, row_number() over (order by p.sku) rn from public.planilha_precos_import p
           where not exists (select 1 from public.catalogo c where c.sku = private.sku_planilha(p.sku))) s;

  select count(*) into v_custos from public.catalogo c join public.planilha_precos_import p on private.sku_planilha(p.sku) = c.sku
   where abs(coalesce(c.custo, 0) - p.custo) > 0.005;

  update public.catalogo c set
    custo = p.custo,
    preco_venda = p.preco_venda,
    preco_mercado_ref = p.preco_mercado,
    prazo_cliente_dias = p.prazo_cliente_dias,
    peso_frete_kg = round(p.peso_g / 1000.0, 3),
    embalagem_cm = p.embalagem_cm,
    tipo_embalagem = p.tipo_embalagem,
    estrategia_preco = p.estrategia,
    preco_planilha_em = now()
  from public.planilha_precos_import p
  where private.sku_planilha(p.sku) = c.sku
    and p.preco_venda >= p.custo * pr.multiplicador_piso - 0.005
    and p.preco_venda - p.custo >= pr.lucro_bruto_minimo - 0.005;
  get diagnostics v_atualizados = row_count;

  select count(*) into v_sem_preco from public.catalogo c where c.active and c.preco_venda is null;
  v_vitrine := private.ecommerce_sincronizar_interno();

  return jsonb_build_object('ok', true, 'atualizados', v_atualizados, 'custos_alterados', v_custos,
    'barrados_pela_trava', v_travas, 'exemplos_barrados', v_exemplos_trava,
    'planilha_sem_catalogo', v_sem_catalogo, 'exemplos_sem_catalogo', v_exemplos_sem,
    'catalogo_sem_preco_de_planilha', v_sem_preco, 'vitrine', v_vitrine);
end $$;
revoke all on function public.aplicar_planilha_precos(text) from public;
grant execute on function public.aplicar_planilha_precos(text) to authenticated, service_role, anon;
