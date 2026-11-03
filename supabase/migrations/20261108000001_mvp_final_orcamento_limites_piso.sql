-- MVP final: limites do orçamento, trava de R$ 5.000 removida, alerta acima de R$ 10.000, piso por bloco e exibição consolidada.
-- Aditiva e idempotente. Reverter: restaurar montar_orcamento e calcular_preco da migration anterior e remover a coluna markup_minimo_bloco.
--
-- 1) Linha do orçamento: de 1 a 100 pacotes por SKU (cabe 500 + 250 + 50). Teto de 50.000 unidades no total do orçamento.
-- 2) SKU fora do catálogo continua bloqueado, agora com o motivo claro `sku_nao_encontrado` (chamar o dono). Nada de preço sem custo.
-- 3) Trava de R$ 5.000 removida. Acima de R$ 10.000 o orçamento sai normal e o dono recebe um alerta silencioso no WhatsApp.
-- 4) Piso do bloco: sem dado de mercado, o preço nunca fica abaixo do custo + R$ 1,80 por bloco (parametros_comerciais.markup_minimo_bloco).
-- 5) Quando um mesmo produto vem em sub-lotes (ex.: 500 + 250 + 50), o PDF mostra uma linha só (orcamentos.itens_exibicao).

alter table public.parametros_comerciais add column if not exists markup_minimo_bloco numeric not null default 1.80 check (markup_minimo_bloco >= 0);

insert into public.app_settings (key, value)
values ('orcamento_agente', jsonb_build_object('valor_alerta', 10000, 'unidades_max', 50000, 'pacotes_max_linha', 100))
on conflict (key) do update
  set value = (public.app_settings.value - 'valor_max_agente') || jsonb_build_object('valor_alerta', 10000, 'unidades_max', 50000, 'pacotes_max_linha', 100);

-- alerta do orçamento de valor alto: só WhatsApp, sem push, respeitando o silêncio noturno
create or replace function private.alerta_categoria(p_tipo text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_tipo = 'pedido_pago' then 'pedido_pago'
    when p_tipo = 'nova_mensagem_humano' then 'nova_mensagem_humano'
    when p_tipo = 'pagamento_pendente_demora' then 'pagamento_pendente'
    when p_tipo = 'pedido_sem_arte' then 'pedido_sem_arte'
    when p_tipo like 'padrao_desconto%' then 'politica_desconto'
    when p_tipo = 'resumo' then 'resumo'
    when p_tipo = 'pagamento_problema' then 'pagamento_problema'
    when p_tipo = 'erro_workflow' then 'erro_sistema'
    when p_tipo = 'pedido_fora_das_regras' then 'pedido_regras'
    when p_tipo = 'orcamento_valor_alto' then 'orcamento_valor_alto'
    else 'atencao_agente' end;
$$;

update public.app_settings
   set value = jsonb_set(value, '{tipos,orcamento_valor_alto}', '{"push":false,"whatsapp":true,"fura_silencio":false}'::jsonb, true)
 where key = 'notificacoes';

-- piso do bloco no fallback (sem pesquisa de mercado nem histórico de vendas)
create or replace function public.calcular_preco(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable set search_path = ''
as $function$
declare
  pr public.parametros_comerciais%rowtype;
  prod record;
  v_qtd integer := greatest(coalesce(p_quantidade, 1), 1);
  v_metodo text := case when p_contexto ->> 'simular_metodo' = 'true' then p_contexto ->> 'metodo' end;
  v_outros_receita numeric := coalesce((p_contexto ->> 'receita_outros')::numeric, 0);
  v_outros_custo numeric := coalesce((p_contexto ->> 'custo_outros')::numeric, 0);
  v_custo_item numeric; v_custo_total numeric; v_extra numeric;
  v_base numeric; v_piso numeric; v_piso_duro numeric;
  v_mediana numeric; v_n integer; v_fator numeric; v_alvo numeric; v_preco numeric;
  v_ancora numeric; v_n_vendas integer; v_consulta uuid;
  v_regra text; v_conf text; v_nao_comp boolean := false; v_receita numeric; v_lucro numeric;
  v_avisos text[] := '{}';
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select c.custo, c.active, c.vendavel, c.grupo_produto, c.especificacao_normalizada into prod from public.catalogo c where c.sku = p_sku;
  if not found or not prod.active then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  if not prod.vendavel then return jsonb_build_object('ok', false, 'erro', 'item_nao_vendavel'); end if;

  v_custo_item := prod.custo * v_qtd;
  v_custo_total := v_custo_item + v_outros_custo;
  v_extra := private.custos_operacionais(p_contexto ->> 'entrega');
  v_piso := ceil(greatest(v_custo_item * pr.multiplicador_piso,
                          private.receita_para_lucro(v_custo_total, v_extra, pr.lucro_liquido_minimo, v_metodo) - v_outros_receita) * 100) / 100;
  v_piso_duro := ceil((private.receita_para_lucro(v_custo_total, v_extra, 0, v_metodo) - v_outros_receita) * 100) / 100;
  v_base := private.arredonda_90(v_custo_item * private.multiplicador_faixa(v_custo_item));

  select percentile_cont(0.5) within group (order by m.preco), count(distinct m.fonte) into v_mediana, v_n
    from public.precos_mercado m
   where (m.chave_especificacao = coalesce(nullif(prod.especificacao_normalizada, ''), p_sku) or m.sku = p_sku)
     and m.normalizado and not m.outlier and m.invalidado_em is null
     and m.coletado_em >= now() - make_interval(days => pr.idade_max_pesquisa_dias);
  if v_n > 0 then
    select m.consulta_id into v_consulta from public.precos_mercado m
     where (m.chave_especificacao = coalesce(nullif(prod.especificacao_normalizada, ''), p_sku) or m.sku = p_sku)
       and m.normalizado and not m.outlier and m.invalidado_em is null and m.consulta_id is not null
     order by m.coletado_em desc limit 1;
  end if;

  select coalesce(f.fator, pr.fator_competitivo) into v_fator from (select 1) x left join public.fatores_competitivos f on f.grupo_produto = prod.grupo_produto;
  v_fator := least(greatest(coalesce(v_fator, pr.fator_competitivo), pr.fator_competitivo_min), pr.fator_competitivo_max);

  select count(*), sum((p.preco_total / p.quantidade) * w) / nullif(sum(w), 0) into v_n_vendas, v_ancora
    from (select pp.preco_total, pp.quantidade, 1.0 / (1 + extract(epoch from (now() - pp.criado_em)) / 86400 / 30) as w
            from public.precos_praticados pp
           where pp.sku = p_sku and pp.resultado = 'ganho' and pp.criado_em >= now() - interval '90 days' and pp.preco_total > 0) p;
  if coalesce(v_n_vendas, 0) < 3 then v_ancora := null; end if;

  if v_n > 0 then
    v_alvo := v_mediana * v_qtd * v_fator;
    v_regra := 'mercado';
    if v_ancora is not null then
      v_alvo := (v_alvo + least(v_ancora, v_mediana) * v_qtd) / 2;
      v_regra := 'mercado_com_ancora_vendas';
    end if;
    v_alvo := private.arredonda_90(v_alvo);
    v_conf := case when v_n >= 3 then 'alta' when v_n = 2 then 'media' else 'baixa' end;
    if v_n = 1 then v_avisos := array_append(v_avisos, 'mercado_com_uma_fonte'); end if;
  elsif v_ancora is not null then
    v_alvo := private.arredonda_90(v_ancora * v_qtd);
    v_regra := 'historico_vendas'; v_conf := 'media';
  else
    -- sem mercado: custo x faixa, nunca abaixo do custo + markup mínimo por bloco (cada bloco é uma unidade vendida)
    v_alvo := greatest(v_base, private.arredonda_90(v_custo_item + pr.markup_minimo_bloco * v_qtd));
    v_regra := 'custo_x_multiplicador'; v_conf := 'baixa';
    v_avisos := array_append(v_avisos, 'sem_dado_de_mercado');
  end if;

  if v_alvo >= v_piso then
    v_preco := v_alvo;
  else
    v_preco := private.teto_90(v_piso);
    v_regra := 'piso';
    v_nao_comp := v_n > 0;
    if v_nao_comp then v_avisos := array_append(v_avisos, 'mercado_abaixo_do_piso'); end if;
  end if;
  if v_preco < v_piso_duro then v_preco := private.teto_90(v_piso_duro); end if;

  v_receita := v_preco + v_outros_receita;
  v_lucro := private.lucro(v_receita, v_custo_total, v_extra, v_metodo);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku, 'quantidade', v_qtd,
    'preco_unitario', round(v_preco / v_qtd, 2), 'preco_total', v_preco,
    'regra', v_regra, 'confianca', v_conf,
    'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1), 'lucro_liquido', v_lucro,
    'piso', round(v_piso, 2), 'piso_duro', round(v_piso_duro, 2),
    'nao_competitivo', v_nao_comp, 'fontes_mercado', v_n, 'mercado_mediana', round(v_mediana * v_qtd, 2),
    'consulta_mercado_id', v_consulta, 'fator_competitivo', v_fator, 'ancora_vendas', round(v_ancora * v_qtd, 2),
    'avisos', to_jsonb(v_avisos));
end;
$function$;

create or replace function public.montar_orcamento(p_contact uuid, p_itens jsonb, p_opcoes jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $function$
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
  v_seg text;
  it jsonb; r jsonb; fr jsonb; pz jsonb;
  v_skus text[] := '{}'; v_qtds integer[] := '{}'; v_calcs jsonb[] := '{}';
  v_sku text; v_qtd integer; v_i integer;
  v_valor_itens numeric := 0; v_itens_frete jsonb := '[]'::jsonb;
  v_frete_modo text := 'retirada'; v_entrega text := 'retirada';
  v_avisos text[] := '{}'; v_arte_valor numeric := 0;
  v_pronto date; v_frase text; v_up jsonb;
  v_id uuid; v_num bigint; v_val jsonb; v_fin jsonb; v_unit numeric;
  v_pior text := 'alta'; v_tem_baixa boolean := false; v_tem_media boolean := false;
  v_itens_out jsonb := '[]'::jsonb; v_cep text; v_validade timestamptz; v_total numeric; v_frete_txt text;
  v_pub_avisos text[]; v_exib jsonb;
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

  -- 1) preço de cada SKU (primeira passada, sem entrega, só para saber o valor do pedido e o frete)
  for it in select * from jsonb_array_elements(p_itens) loop
    v_sku := btrim(coalesce(it ->> 'sku', ''));
    v_qtd := coalesce((it ->> 'quantidade')::integer, 1);
    if v_sku = '' or v_qtd < 1 or v_qtd > v_max_pacotes then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'alternativa', 'Cada item precisa de SKU e quantidade de 1 a ' || v_max_pacotes || '.');
    end if;
    r := public.calcular_preco(v_sku, v_qtd, jsonb_build_object('metodo', v_metodo));
    if not coalesce((r ->> 'ok')::boolean, false) then
      if r ->> 'erro' = 'sku_nao_encontrado' then
        return jsonb_build_object('status', 'bloqueado', 'motivo', 'sku_nao_encontrado',
                                  'alternativa', 'Esse item não está no catálogo: não informe valor; diga que vai conferir e chame o dono.');
      end if;
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'item_indisponivel', 'alternativa', 'Ofereça outro item do catálogo ou confirme com o dono.');
    end if;
    v_unid := v_unid + v_qtd * coalesce((select c.quantidade from public.catalogo c where c.sku = v_sku), 1);
    v_skus := v_skus || v_sku; v_qtds := v_qtds || v_qtd;
    v_valor_itens := v_valor_itens + (r ->> 'preco_total')::numeric;
    v_itens_frete := v_itens_frete || jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', v_qtd));
  end loop;
  if v_unid > v_max_unid then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'quantidade_irreal',
                              'alternativa', 'Quantidade acima do que a produção atende de uma vez: não informe valor; diga que vai conferir e chame o dono.');
  end if;

  -- 2) frete e arte
  if v_local is not null then
    fr := public.verificar_frete(v_local, v_itens_frete, v_valor_itens, v_arte = 'com_frete');
    if not coalesce((fr ->> 'ok')::boolean, false) then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'item_indisponivel', 'alternativa', 'Ofereça outro item do catálogo ou confirme com o dono.');
    end if;
    if coalesce((fr ->> 'frete_gratis')::boolean, false) then v_frete_modo := 'bike_gratis'; v_entrega := 'bike'; else v_frete_modo := 'uber_cliente'; end if;
    if (fr ->> 'dimensao_desconhecida')::boolean then v_avisos := array_append(v_avisos, 'frete_a_confirmar'); end if;
  end if;
  if v_arte = 'com_frete' and v_frete_modo <> 'bike_gratis' then
    v_arte := 'paga'; v_avisos := array_append(v_avisos, 'arte_com_frete_indisponivel');
  end if;
  v_arte_valor := case v_arte when 'paga' then pr.arte_valor when 'com_frete' then pr.arte_frete_valor else 0 end;

  -- 3) orçamento (rascunho) e itens, com o preço final calculado já considerando a entrega que é por nossa conta
  v_cep := case when v_local ~ '^\s*\d{5}-?\d{3}\s*$' then regexp_replace(v_local, '\D', '', 'g') end;
  v_validade := now() + make_interval(hours => pr.validade_orcamento_horas);
  for v_i in 1 .. cardinality(v_skus) loop
    r := public.calcular_preco(v_skus[v_i], v_qtds[v_i], jsonb_build_object('metodo', v_metodo, 'entrega', case when v_entrega = 'bike' then 'bike' end));
    v_calcs := v_calcs || r;
    if (r ->> 'confianca') = 'baixa' then v_tem_baixa := true; elsif (r ->> 'confianca') = 'media' then v_tem_media := true; end if;
  end loop;
  v_pior := case when v_tem_baixa then 'baixa' when v_tem_media then 'media' else 'alta' end;

  -- prazo: vale a data mais distante entre os itens
  for v_i in 1 .. cardinality(v_skus) loop
    pz := public.calcular_prazo(v_skus[v_i], now(), false);
    if coalesce((pz ->> 'ok')::boolean, false) and (v_pronto is null or (pz ->> 'data_pronto')::date > v_pronto) then
      v_pronto := (pz ->> 'data_pronto')::date; v_frase := pz ->> 'frase';
    end if;
  end loop;
  if v_pronto is null then v_avisos := array_append(v_avisos, 'prazo_a_confirmar'); end if;

  v_up := private.upsell_regra(v_skus, v_seg, v_arte);

  insert into public.orcamentos (contact_id, conversation_id, status, entrega, bairro, cep, metodo_previsto, arte_modo, arte_valor, frete_valor,
                                 validade_ate, frete_modo, upsell_tipo, upsell_texto, data_prevista, avisos, teste, regra_preco, confianca_preco)
  values (p_contact, v_conv, 'rascunho', v_entrega, case when v_cep is null then v_local end, v_cep, v_metodo, v_arte, v_arte_valor, 0,
          v_validade, v_frete_modo, v_up ->> 'tipo', v_up ->> 'texto', v_pronto, to_jsonb(v_avisos), v_teste,
          (v_calcs[1] ->> 'regra'), v_pior)
  returning id, numero into v_id, v_num;

  for v_i in 1 .. cardinality(v_skus) loop
    r := v_calcs[v_i];
    v_unit := ceil((r ->> 'preco_total')::numeric / v_qtds[v_i] * 100) / 100;     -- nunca arredonda para baixo do total calculado
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, regra_preco, confianca_preco, margem_liquida_pct,
                                        consulta_mercado_id, mercado_mediana, fontes_mercado, nao_competitivo, piso, piso_duro, lucro_liquido, especificacao)
    values (v_id, v_skus[v_i], (select descricao from public.catalogo where sku = v_skus[v_i]), v_qtds[v_i], v_unit,
            r ->> 'regra', r ->> 'confianca', (r ->> 'margem_liquida_pct')::numeric,
            nullif(r ->> 'consulta_mercado_id', '')::uuid, (r ->> 'mercado_mediana')::numeric, (r ->> 'fontes_mercado')::integer,
            coalesce((r ->> 'nao_competitivo')::boolean, false), (r ->> 'piso')::numeric, (r ->> 'piso_duro')::numeric, (r ->> 'lucro_liquido')::numeric,
            private.especificacao_publica(v_skus[v_i]));
  end loop;

  -- 4) trava final de lucro (defesa em profundidade)
  v_val := public.validar_margem(v_id);
  if v_val ->> 'status' <> 'ok' then
    delete from public.orcamentos where id = v_id;
    return jsonb_build_object('status', 'bloqueado', 'motivo', v_val ->> 'motivo',
                              'alternativa', 'Sugira uma especificação mais simples ou outra quantidade, ou chame o dono para decidir.');
  end if;
  v_fin := private.orcamento_financeiro(v_id);
  update public.orcamentos set custo_total = (v_fin ->> 'custo')::numeric + (v_fin ->> 'extra')::numeric,
         lucro_liquido = (v_fin ->> 'lucro')::numeric,
         margem_liquida_pct = round((v_fin ->> 'lucro')::numeric / nullif((v_fin ->> 'receita')::numeric, 0) * 100, 1)
   where id = v_id;
  select total into v_total from public.orcamentos where id = v_id;

  -- exibição consolidada: sub-lotes do mesmo produto viram uma linha só (unidades somadas, unitário médio e total do item)
  select jsonb_agg(jsonb_build_object('descricao', g.descricao, 'especificacao', g.especificacao, 'quantidade', g.unidades,
                                      'valor_unitario', round(g.total / g.unidades, 4), 'valor_total', round(g.total, 2)) order by g.ordem)
    into v_exib
    from (select i.descricao, regexp_replace(coalesce(i.especificacao, ''), '^\s*[0-9.]+\s*un\.?\s*·\s*', '') as especificacao, sum(i.quantidade * coalesce(c.quantidade, 1)) as unidades,
                 sum(i.quantidade * i.preco_unitario) as total, min(i.criado_em) as ordem, count(*) as linhas
            from public.orcamento_itens i left join public.catalogo c on c.sku = i.sku
           where i.orcamento_id = v_id group by 1, 2) g;
  if exists (select 1 from public.orcamento_itens i where i.orcamento_id = v_id group by i.descricao, regexp_replace(coalesce(i.especificacao, ''), '^\s*[0-9.]+\s*un\.?\s*·\s*', '') having count(*) > 1)
     and v_exib is not null and jsonb_array_length(v_exib) between 1 and 10 then
    update public.orcamentos set itens_exibicao = v_exib where id = v_id;
  end if;

  -- orçamento de valor alto sai normal; o dono recebe um alerta silencioso no WhatsApp
  if v_total > v_valor_alerta then
    perform public.alerta_criar('orcamento_valor_alto', 'alta', p_contact, v_conv, null,
                                'Orçamento de R$ ' || to_char(v_total, 'FM999G999G990D00') || ' montado pelo agente.',
                                jsonb_build_object('orcamento_id', v_id), 'valor_alto:' || v_id::text, array['whatsapp']);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'especificacao', i.especificacao, 'quantidade', i.quantidade,
                                               'valor_unitario', i.preco_unitario, 'valor_total', i.quantidade * i.preco_unitario) order by i.criado_em, i.id), '[]'::jsonb)
    into v_itens_out from public.orcamento_itens i where i.orcamento_id = v_id;
  v_frete_txt := case v_frete_modo
    when 'bike_gratis' then 'Entrega grátis na região central, em horário comercial.'
    when 'uber_cliente' then 'Entrega por Uber Entrega, por conta do cliente. A retirada é grátis.'
    else 'Retirada grátis no centro de BH.' end;
  v_pub_avisos := array(select a from unnest(v_avisos) a where a in ('arte_com_frete_indisponivel', 'frete_a_confirmar', 'prazo_a_confirmar'));

  return jsonb_build_object(
    'status', 'ok', 'orcamento_id', v_id, 'numero', private.orcamento_numero(v_num),
    'itens', v_itens_out, 'subtotal', (select subtotal from public.orcamentos where id = v_id),
    'arte', jsonb_build_object('modo', v_arte, 'valor', v_arte_valor),
    'opcoes_arte', case when v_arte = 'nenhuma' then jsonb_build_array(
        jsonb_build_object('modo', 'paga', 'valor', pr.arte_valor, 'texto', 'Só a arte'),
        jsonb_build_object('modo', 'com_frete', 'valor', pr.arte_frete_valor, 'texto', 'Arte com frete grátis na região central',
                           'disponivel', v_frete_modo = 'bike_gratis' or v_local is null)) end,
    'frete', jsonb_build_object('modo', case v_frete_modo when 'bike_gratis' then 'entrega_gratis' else v_frete_modo end, 'valor', 0, 'texto', v_frete_txt),
    'total', v_total, 'data_prevista', v_pronto, 'prazo', v_frase, 'validade_ate', v_validade,
    'upsell', v_up, 'avisos', to_jsonb(v_pub_avisos));
end;
$function$;
