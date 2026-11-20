-- Fase 1 (Plano de Ação): o piso de Lucro Bruto Mínimo (R$ 65) deixa de ser somado por ITEM em pedidos
-- compostos (crachá + cordão, cartão + panfleto, etc.) e passa a ser validado uma única vez sobre o
-- LUCRO BRUTO TOTAL do pedido. O piso de custo x 1,5 (multiplicador_piso) e o piso duro (lucro líquido
-- zero) continuam exatamente como antes, por item, sem nenhuma relaxação. Não altera `catalogo.preco_venda`.
--
-- Causa raiz: `private.montar_orcamento_base` chama `public.calcular_preco` uma vez por item, e cada
-- chamada aplicava o piso `greatest(custo x 1,5, custo + R$ 65)` isoladamente. Num pedido de 2 itens em
-- que ambos ficariam abaixo de custo + R$ 65 pela planilha, o pedido acabava exigindo R$ 130 de lucro
-- bruto em vez de R$ 65. Aditiva e idempotente (CREATE OR REPLACE).

-- 1) calcular_preco ganha dois parâmetros de contexto opcionais (compatíveis com todas as chamadas
--    existentes, que não os enviam):
--    - piso_sem_lucro_minimo = 'true': ignora o termo "custo + lucro_bruto_minimo" do piso, mantendo só
--      custo x multiplicador_piso. Usado pelo chamador quando o item faz parte de um pedido composto.
--    - preco_minimo_reais: piso adicional explícito em reais, imposto pelo chamador (usado para cobrir,
--      numa única linha do pedido, a diferença que falta para o conjunto chegar ao lucro bruto mínimo).
create or replace function public.calcular_preco(p_sku text, p_quantidade integer DEFAULT 1, p_contexto jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
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
  v_piso_sem_lbm boolean := coalesce(p_contexto ->> 'piso_sem_lucro_minimo', '') = 'true';
  v_piso_minimo_forcado numeric := coalesce((p_contexto ->> 'preco_minimo_reais')::numeric, 0);
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select c.sku, c.custo, c.active, c.vendavel, c.tamanho_mm, c.categoria, c.descricao, c.preco_venda, c.preco_mercado_ref
    into prod from public.catalogo c where c.sku = p_sku;
  if not found or not prod.active then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  if not prod.vendavel then return jsonb_build_object('ok', false, 'erro', 'item_nao_vendavel'); end if;

  if pr.fonte_preco <> 'planilha' or prod.preco_venda is null then
    j := private.calcular_preco_mercado(p_sku, p_quantidade, p_contexto);
    if pr.fonte_preco = 'planilha' and coalesce((j ->> 'ok')::boolean, false) then
      j := jsonb_set(j, '{avisos}', coalesce(j -> 'avisos', '[]'::jsonb) || '["sem_preco_de_planilha"]'::jsonb);
    end if;
    return j;
  end if;

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

  -- Piso por item: custo x multiplicador sempre; custo + lucro_bruto_minimo só quando NÃO for pedido
  -- composto (ou quando o chamador não disser o contrário); mais o piso explícito em reais, se enviado.
  v_piso := ceil(greatest(
              v_custo_item * pr.multiplicador_piso,
              case when v_piso_sem_lbm then 0 else v_custo_item + pr.lucro_bruto_minimo end,
              v_piso_minimo_forcado
            ) * 100) / 100;
  v_piso_duro := ceil((private.receita_para_lucro(v_custo_total, v_extra, 0, v_metodo) - v_outros_receita) * 100) / 100;
  if v_preco < v_piso then
    v_preco := private.teto_90(v_piso); v_regra := 'piso';
    v_avisos := array_append(v_avisos, case when v_piso_minimo_forcado > 0 then 'piso_pedido_composto' else 'planilha_abaixo_do_piso' end);
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

-- 2) private.montar_orcamento_base: em pedido com 2+ itens, cada item usa o piso relaxado (sem o termo
--    de R$ 65 por item); se a soma do lucro bruto do conjunto ainda ficar abaixo do mínimo, a diferença
--    é coberta em UMA ÚNICA linha (a de maior valor), nunca distribuída repetidamente. Pedido de 1 item
--    não muda em nada (continua com o piso cheio de sempre).
create or replace function private.montar_orcamento_base(p_contact uuid, p_itens jsonb, p_opcoes jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  pr public.parametros_comerciais%rowtype;
  v_cfg jsonb := coalesce((select value from public.app_settings where key = 'orcamento_agente'), '{}'::jsonb);
  v_max_pacotes integer := coalesce((v_cfg ->> 'pacotes_max_linha')::integer, 100);
  v_max_unid numeric := coalesce((v_cfg ->> 'unidades_max')::numeric, 50000);
  v_valor_alerta numeric := coalesce((v_cfg ->> 'valor_alerta')::numeric, 10000);
  v_unid numeric := 0;
  v_opc jsonb := coalesce(p_opcoes, '{}'::jsonb);
  v_local text := nullif(btrim(coalesce(v_opc ->> 'cep', v_opc ->> 'bairro', '')), '');
  v_arte text := coalesce(nullif(v_opc ->> 'arte', ''), 'nenhuma');
  v_metodo text := nullif(v_opc ->> 'metodo', '');
  v_conv uuid := nullif(v_opc ->> 'conversation_id', '')::uuid;
  v_teste boolean := coalesce((v_opc ->> 'teste')::boolean, false);
  v_data_evento date := nullif(btrim(v_opc ->> 'data_evento'), '')::date;
  v_seg text;
  it jsonb; r jsonb; fr jsonb; pz jsonb;
  v_skus text[] := '{}'; v_qtds integer[] := '{}'; v_calcs jsonb[] := '{}';
  v_acabs text[] := '{}'; v_acab_custos numeric[] := '{}'; v_acab_dias integer[] := '{}';
  v_larguras integer[] := '{}'; v_alturas integer[] := '{}'; v_areas numeric[] := '{}';
  v_sku text; v_qtd integer; v_lote_cat integer; v_i integer; v_acab_nome text;
  v_acab_custo numeric := 0; v_acab_dia integer := 0; v_frete_nac numeric := 0; v_acab_real text := '';
  v_larg integer; v_alt integer; v_bg record; v_rb jsonb;
  v_valor_itens numeric := 0; v_itens_frete jsonb := '[]'::jsonb;
  v_frete_modo text := 'retirada'; v_entrega text := 'retirada';
  v_avisos text[] := '{}'; v_arte_valor numeric := 0;
  v_pronto date; v_frase text; v_up jsonb;
  v_id uuid; v_num bigint; v_val jsonb; v_fin jsonb; v_unit numeric;
  v_pior text := 'alta'; v_tem_baixa boolean := false; v_tem_media boolean := false;
  v_itens_out jsonb := '[]'::jsonb; v_cep text; v_validade timestamptz; v_total numeric; v_frete_txt text;
  v_pub_avisos text[]; v_exib jsonb; v_dias_max_acab integer := 0;
  v_composto boolean; v_lucro_bruto_total numeric; v_idx_maior integer; v_maior_preco numeric;
  v_falta numeric; v_novo_min numeric;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  if not exists (select 1 from public.contacts where id = p_contact) then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'contato_nao_encontrado', 'alternativa', 'Confirme o contato antes de orçar.');
  end if;
  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) not between 1 and 10 then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'alternativa', 'Informe de 1 a 10 itens com SKU e quantidade.');
  end if;
  if v_arte not in ('nenhuma', 'cliente', 'paga', 'com_frete') then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'arte_invalida', 'alternativa', 'Escolha: nenhuma, cliente, paga ou com_frete.');
  end if;
  select segment into v_seg from public.contacts where id = p_contact;

  for it in select * from jsonb_array_elements(p_itens) loop
    v_sku := upper(btrim(coalesce(it ->> 'sku', '')));
    if nullif(btrim(coalesce(it ->> 'quantidade', '')), '') is not null and btrim(it ->> 'quantidade') !~ '^[1-9][0-9]*$' then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'quantidade_invalida', 'alternativa', 'A quantidade é o número INTEIRO de pacotes do SKU (cada SKU tem a sua quantidade fixa). Nunca use fração. Se a quantidade exata do cliente não existir, ofereça a opção mais próxima que a busca devolveu.');
    end if;
    v_qtd := coalesce((it ->> 'quantidade')::integer, 1);
    if exists (select 1 from public.catalogo cx where cx.sku = v_sku and cx.preco_venda is null) then /* preco_oficial_obrigatorio */
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'sem_preco_oficial', 'alternativa', 'Esse item não tem preço oficial na planilha. Ofereça o produto mais próximo que a busca devolveu e continue o atendimento.');
    end if;
    v_acab_nome := nullif(btrim(it ->> 'acabamento'), '');
    v_larg := nullif((it ->> 'largura_mm')::integer, 0);
    v_alt := nullif((it ->> 'altura_mm')::integer, 0);

    select coalesce(c.quantidade, 1) into v_lote_cat from public.catalogo c where c.sku = v_sku;
    if v_lote_cat >= 5 and v_qtd >= v_lote_cat and mod(v_qtd, v_lote_cat) = 0 then
      v_qtd := v_qtd / v_lote_cat;
    end if;

    if v_sku = '' or v_qtd < 1 or v_qtd > v_max_pacotes then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'alternativa', 'Cada item precisa de SKU e quantidade de 1 a ' || v_max_pacotes || ' pacotes.');
    end if;

    r := public.calcular_preco(v_sku, v_qtd, jsonb_build_object('metodo', v_metodo, 'largura_mm', v_larg, 'altura_mm', v_alt));
    if not coalesce((r ->> 'ok')::boolean, false) then
      if r ->> 'erro' = 'sku_nao_encontrado' then
        return jsonb_build_object('status', 'bloqueado', 'motivo', 'sku_nao_encontrado',
                                  'alternativa', 'Busque o SKU correto usando buscar_produto antes de chamar montar_orcamento.');
      end if;
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'item_indisponivel', 'alternativa', 'Ofereça outro item do catálogo.');
    end if;

    if v_larg is null and coalesce(v_opc ->> 'nao_otimizar_lote', '') <> 'true' then /* lote_maior_barato */
      -- Se o lote maior do mesmo produto custa menos que os pacotes pedidos, usa o lote maior (o cliente leva mais unidades por menos).
      select c2.sku, c2.quantidade into v_bg from public.catalogo c2 join public.catalogo c1 on c1.sku = v_sku
       where c2.active and c2.vendavel and c2.preco_venda is not null and c2.categoria = c1.categoria and c2.descricao = c1.descricao
         and c2.cores is not distinct from c1.cores and c2.tamanho_mm is not distinct from c1.tamanho_mm
         and c2.quantidade > coalesce(v_lote_cat, 1) * v_qtd and c2.quantidade <= greatest(coalesce(v_lote_cat, 1) * v_qtd * 3, 10)
       order by c2.quantidade asc limit 1;
      if found then
        v_rb := public.calcular_preco(v_bg.sku, 1, jsonb_build_object('metodo', v_metodo, 'largura_mm', v_larg, 'altura_mm', v_alt));
        if coalesce((v_rb ->> 'ok')::boolean, false) and (v_rb ->> 'preco_total')::numeric <= (r ->> 'preco_total')::numeric then
          v_avisos := array_append(v_avisos, 'lote_maior_mais_barato');
          v_sku := v_bg.sku; v_qtd := 1; v_lote_cat := v_bg.quantidade; r := v_rb;
        end if;
      end if;
    end if;
    v_acab_custo := 0.00;
    v_acab_dia := 0;
    v_acab_real := coalesce(v_acab_nome, '');
    if v_acab_nome is not null then
      select nome, coalesce(custo_adicional, 0.00), coalesce(dias_uteis_adicionais, 0)
        into v_acab_real, v_acab_custo, v_acab_dia
        from public.produto_acabamentos
       where ativo and (nome ilike '%' || v_acab_nome || '%' or v_acab_nome ilike '%' || nome || '%')
       limit 1;
      if not found then
        v_acab_custo := 0.00;
        v_acab_dia := 0;
        v_acab_real := v_acab_nome;
      end if;
    end if;

    v_unid := v_unid + v_qtd * coalesce(v_lote_cat, 1);
    v_skus := v_skus || v_sku;
    v_qtds := v_qtds || v_qtd;
    v_acabs := v_acabs || v_acab_real;
    v_acab_custos := v_acab_custos || v_acab_custo;
    v_acab_dias := v_acab_dias || v_acab_dia;
    v_larguras := v_larguras || coalesce(v_larg, 0);
    v_alturas := v_alturas || coalesce(v_alt, 0);
    v_areas := v_areas || coalesce((r ->> 'area_m2_por_unidade')::numeric, 0.000);

    if v_acab_dia > v_dias_max_acab then
      v_dias_max_acab := v_acab_dia;
    end if;

    v_valor_itens := v_valor_itens + (r ->> 'preco_total')::numeric + (v_acab_custo * v_qtd);
    v_itens_frete := v_itens_frete || jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', v_qtd));
  end loop;

  if v_unid > v_max_unid then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'quantidade_irreal',
                              'alternativa', 'Quantidade acima do que a produção atende de uma vez.');
  end if;

  if v_local is not null then
    fr := public.verificar_frete(v_local, v_itens_frete, v_valor_itens, v_arte = 'com_frete');
    if coalesce((fr ->> 'frete_gratis')::boolean, false) then v_frete_modo := 'bike_gratis'; v_entrega := 'bike'; else v_frete_modo := 'uber_cliente'; end if;
    if (fr ->> 'dimensao_desconhecida')::boolean then v_avisos := array_append(v_avisos, 'frete_a_confirmar'); end if;
  end if;

  if v_arte = 'com_frete' and v_frete_modo <> 'bike_gratis' then
    v_arte := 'paga'; v_avisos := array_append(v_avisos, 'arte_com_frete_indisponivel');
  end if;
  v_arte_valor := case v_arte when 'paga' then pr.arte_valor when 'com_frete' then pr.arte_frete_valor else 0 end;

  v_cep := case when v_local ~ '^\s*\d{5}-?\d{3}\s*$' then regexp_replace(v_local, '\D', '', 'g') end;
  v_validade := now() + make_interval(hours => pr.validade_orcamento_horas);
  if v_cep is not null then /* frete_correios */
    if nullif(v_opc ->> 'frete_servico', '') is not null then
      select c.valor into v_frete_nac from public.frete_cotacoes c where c.conversation_id = v_conv and c.cep = v_cep and c.servico = lower(v_opc ->> 'frete_servico') and c.criado_em > now() - interval '3 days' order by c.criado_em desc limit 1;
      if v_frete_nac is null then
        return jsonb_build_object('status', 'bloqueado', 'motivo', 'frete_sem_cotacao', 'alternativa', 'Consulte verificar_frete com o CEP do cliente e confirme PAC ou SEDEX antes de orçar.');
      end if;
      v_frete_modo := 'correios'; v_entrega := 'uber';
    elsif v_frete_modo <> 'bike_gratis' and exists (select 1 from public.frete_cotacoes c where c.conversation_id = v_conv and c.cep = v_cep and c.criado_em > now() - interval '3 days') then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'escolher_frete', 'alternativa', 'O cliente é de fora de BH: pergunte se prefere PAC ou SEDEX (valores de verificar_frete) e envie frete_servico em opcoes.');
    end if;
  end if;

  -- Pedido composto (2+ itens): cada item usa o piso relaxado (sem somar R$ 65 por item); o piso de
  -- custo x 1,5 e o piso duro continuam cheios, por item, sem nenhuma mudança.
  v_composto := cardinality(v_skus) > 1;
  for v_i in 1 .. cardinality(v_skus) loop
    r := public.calcular_preco(v_skus[v_i], v_qtds[v_i], jsonb_build_object('metodo', v_metodo, 'entrega', case when v_entrega = 'bike' then 'bike' end, 'largura_mm', v_larguras[v_i], 'altura_mm', v_alturas[v_i],
         'piso_sem_lucro_minimo', case when v_composto then 'true' else 'false' end));
    v_calcs := v_calcs || r;
    if (r ->> 'confianca') = 'baixa' then v_tem_baixa := true; elsif (r ->> 'confianca') = 'media' then v_tem_media := true; end if;
  end loop;
  v_pior := case when v_tem_baixa then 'baixa' when v_tem_media then 'media' else 'alta' end;

  -- Trava de R$ 65 por PEDIDO, nunca por item: se o lucro bruto do conjunto (com o piso relaxado) ainda
  -- não chegar ao mínimo, cobre a diferença numa ÚNICA linha (a de maior valor), reaproveitando o mesmo
  -- calcular_preco (mesma fórmula de lucro/margem de sempre), nunca em todas as linhas.
  if v_composto then
    v_lucro_bruto_total := 0;
    for v_i in 1 .. cardinality(v_skus) loop
      v_lucro_bruto_total := v_lucro_bruto_total + coalesce((v_calcs[v_i] ->> 'lucro_bruto')::numeric, 0);
    end loop;
    if v_lucro_bruto_total < pr.lucro_bruto_minimo - 0.05 then
      v_falta := pr.lucro_bruto_minimo - v_lucro_bruto_total;
      v_idx_maior := 1; v_maior_preco := (v_calcs[1] ->> 'preco_total')::numeric;
      for v_i in 2 .. cardinality(v_skus) loop
        if (v_calcs[v_i] ->> 'preco_total')::numeric > v_maior_preco then
          v_idx_maior := v_i; v_maior_preco := (v_calcs[v_i] ->> 'preco_total')::numeric;
        end if;
      end loop;
      v_novo_min := v_maior_preco + v_falta;
      v_calcs[v_idx_maior] := public.calcular_preco(v_skus[v_idx_maior], v_qtds[v_idx_maior],
        jsonb_build_object('metodo', v_metodo, 'entrega', case when v_entrega = 'bike' then 'bike' end,
                            'largura_mm', v_larguras[v_idx_maior], 'altura_mm', v_alturas[v_idx_maior],
                            'piso_sem_lucro_minimo', 'true', 'preco_minimo_reais', v_novo_min::text));
    end if;
  end if;

  for v_i in 1 .. cardinality(v_skus) loop
    pz := public.calcular_prazo(v_skus[v_i], now(), false);
    if coalesce((pz ->> 'ok')::boolean, false) and (v_pronto is null or (pz ->> 'data_pronto')::date > v_pronto) then
      v_pronto := (pz ->> 'data_pronto')::date; v_frase := pz ->> 'frase';
    end if;
  end loop;

  if v_dias_max_acab > 0 and v_pronto is not null then
    v_pronto := public.add_business_days(v_pronto, v_dias_max_acab);
    v_frase := coalesce(v_frase, '') || ' (+ ' || v_dias_max_acab || ' dia útil do acabamento)';
  end if;

  if v_pronto is null then v_avisos := array_append(v_avisos, 'prazo_a_confirmar'); end if;

  if v_data_evento is not null and v_pronto is not null then
    if v_pronto > v_data_evento then
      v_avisos := array_append(v_avisos, 'prazo_estoura_data_evento');
    elsif v_pronto = v_data_evento then
      v_avisos := array_append(v_avisos, 'prazo_no_limite_do_evento');
    end if;
  end if;

  v_up := private.upsell_regra(v_skus, v_seg, v_arte);

  insert into public.orcamentos (contact_id, conversation_id, status, entrega, bairro, cep, metodo_previsto, arte_modo, arte_valor, frete_valor,
                                 validade_ate, frete_modo, upsell_tipo, upsell_texto, data_prevista, data_evento, avisos, teste, regra_preco, confianca_preco)
  values (p_contact, v_conv, 'rascunho', v_entrega, case when v_cep is null then v_local end, v_cep, v_metodo, v_arte, v_arte_valor, v_frete_nac,
          v_validade, v_frete_modo, v_up ->> 'tipo', v_up ->> 'texto', v_pronto, v_data_evento, to_jsonb(v_avisos), v_teste,
          (v_calcs[1] ->> 'regra'), v_pior)
  returning id, numero into v_id, v_num;

  for v_i in 1 .. cardinality(v_skus) loop
    r := v_calcs[v_i];
    v_unit := ceil(((r ->> 'preco_total')::numeric + (v_acab_custos[v_i] * v_qtds[v_i])) / v_qtds[v_i] * 100) / 100;
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, acabamento, acabamento_custo, acabamento_dias_adicionais,
                                        largura_mm, altura_mm, area_m2,
                                        regra_preco, confianca_preco, margem_liquida_pct,
                                        consulta_mercado_id, mercado_mediana, fontes_mercado, nao_competitivo, piso, piso_duro, lucro_liquido, especificacao)
    values (v_id, v_skus[v_i], (select descricao from public.catalogo where sku = v_skus[v_i]), v_qtds[v_i], v_unit,
            nullif(v_acabs[v_i], ''), v_acab_custos[v_i], v_acab_dias[v_i],
            nullif(v_larguras[v_i], 0), nullif(v_alturas[v_i], 0), nullif(v_areas[v_i], 0),
            r ->> 'regra', r ->> 'confianca', (r ->> 'margem_liquida_pct')::numeric,
            nullif(r ->> 'consulta_mercado_id', '')::uuid, (r ->> 'mercado_mediana')::numeric, (r ->> 'fontes_mercado')::integer,
            coalesce((r ->> 'nao_competitivo')::boolean, false), (r ->> 'piso')::numeric, (r ->> 'piso_duro')::numeric, (r ->> 'lucro_liquido')::numeric,
            private.especificacao_publica(v_skus[v_i]));
  end loop;

  v_val := public.validar_margem(v_id);
  if v_val ->> 'status' <> 'ok' then
    delete from public.orcamentos where id = v_id;
    return jsonb_build_object('status', 'bloqueado', 'motivo', v_val ->> 'motivo',
                              'alternativa', 'Sugira uma especificação mais simples ou outra quantidade.');
  end if;

  v_fin := private.orcamento_financeiro(v_id);
  update public.orcamentos set custo_total = (v_fin ->> 'custo')::numeric + (v_fin ->> 'extra')::numeric,
         lucro_liquido = (v_fin ->> 'lucro')::numeric,
         margem_liquida_pct = round((v_fin ->> 'lucro')::numeric / nullif((v_fin ->> 'receita')::numeric, 0) * 100, 1)
   where id = v_id;
  select total into v_total from public.orcamentos where id = v_id;

  select jsonb_agg(jsonb_build_object('descricao', g.descricao, 'especificacao', g.especificacao, 'quantidade', g.unidades,
                                      'acabamento', g.acabamento,
                                      'area_m2', g.area_m2,
                                      'valor_unitario', round(g.total / g.unidades, 4), 'valor_total', round(g.total, 2)) order by g.ordem)
    into v_exib
    from (select i.descricao, regexp_replace(coalesce(i.especificacao, ''), '^\s*[0-9.]+\s*un\.?\s*·\s*', '') as especificacao,
                 i.acabamento, i.area_m2,
                 sum(i.quantidade * coalesce(c.quantidade, 1)) as unidades,
                 sum(i.quantidade * i.preco_unitario) as total, min(i.criado_em) as ordem, count(*) as linhas
            from public.orcamento_itens i left join public.catalogo c on c.sku = i.sku
           where i.orcamento_id = v_id group by 1, 2, 3, 4) g;

  if exists (select 1 from public.orcamento_itens i where i.orcamento_id = v_id group by i.descricao, regexp_replace(coalesce(i.especificacao, ''), '^\s*[0-9.]+\s*un\.?\s*·\s*', '') having count(*) > 1)
     and v_exib is not null and jsonb_array_length(v_exib) between 1 and 10 then
    update public.orcamentos set itens_exibicao = v_exib where id = v_id;
  end if;

  if v_total > v_valor_alerta then
    perform public.alerta_criar('orcamento_valor_alto', 'alta', p_contact, v_conv, null,
                                'Orçamento de R$ ' || to_char(v_total, 'FM999G999G990D00') || ' montado pelo agente.',
                                jsonb_build_object('orcamento_id', v_id), 'valor_alto:' || v_id::text, array['whatsapp']);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'especificacao', i.especificacao, 'quantidade', i.quantidade,
                                               'acabamento', i.acabamento, 'area_m2', i.area_m2,
                                               'valor_unitario', i.preco_unitario, 'valor_total', i.quantidade * i.preco_unitario) order by i.criado_em, i.id), '[]'::jsonb)
    into v_itens_out from public.orcamento_itens i where i.orcamento_id = v_id;

  v_frete_txt := case v_frete_modo
    when 'bike_gratis' then 'Entrega grátis na região central, em horário comercial.'
    when 'uber_cliente' then 'Entrega por Uber Entrega, por conta do cliente. A retirada é grátis.' when 'correios' then 'Envio pelos Correios (' || upper(coalesce(v_opc ->> 'frete_servico', '')) || '), por conta do cliente, somado ao total.'
    else 'Retirada grátis no centro de BH.' end;
  v_pub_avisos := array(select a from unnest(v_avisos) a where a in ('arte_com_frete_indisponivel', 'frete_a_confirmar', 'prazo_a_confirmar', 'prazo_estoura_data_evento', 'prazo_no_limite_do_evento', 'faturamento_minimo_1m2', 'lote_maior_mais_barato'));

  return jsonb_build_object(
    'status', 'ok', 'orcamento_id', v_id, 'numero', private.orcamento_numero(v_num),
    'itens', v_itens_out, 'subtotal', (select subtotal from public.orcamentos where id = v_id),
    'arte', jsonb_build_object('modo', v_arte, 'valor', v_arte_valor),
    'opcoes_arte', case when v_arte = 'nenhuma' then jsonb_build_array(
        jsonb_build_object('modo', 'paga', 'valor', pr.arte_valor, 'texto', 'Só a arte'),
        jsonb_build_object('modo', 'com_frete', 'valor', pr.arte_frete_valor, 'texto', 'Arte com frete grátis na região central',
                           'disponivel', v_frete_modo = 'bike_gratis' or v_local is null)) end,
    'frete', jsonb_build_object('modo', case v_frete_modo when 'bike_gratis' then 'entrega_gratis' else v_frete_modo end, 'valor', v_frete_nac, 'texto', v_frete_txt),
    'total', v_total, 'data_prevista', v_pronto, 'data_prevista_br', to_char(v_pronto, 'DD/MM'), 'prazo', v_frase, 'validade_ate', v_validade,
    'upsell', v_up, 'avisos', to_jsonb(v_pub_avisos),
    'resumo_composto', case when jsonb_array_length(v_itens_out) > 1 then private.resumo_composto(v_id) end /* resumo_composto */);
end;
$function$;
