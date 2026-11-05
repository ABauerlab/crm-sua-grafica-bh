-- Ajustes comerciais de produção (04/11/2026).
-- Reflete exatamente as funções já atualizadas em produção: calcular_preco (agrupamento por parênteses para m²),
-- montar_orcamento (add_business_days para o acabamento), calcular_prazo, private.inicio_contagem (corte às 10h30),
-- public.agente_bloqueio (pós-pagamento automático em modo IA), private.categoria_bate (filtra acabamentos) e public.add_business_days.
-- Idempotente: a divisão de custos é guardada em app_settings e roda uma única vez, mesmo se a migration for reaplicada.

-- 1) Custos de produtos por m² gravados 100x maiores: divide por 100 os itens de quantidade 1 com custo acima de 500.
--    Os critérios de categoria são os mesmos que calcular_preco usa para detectar m² (BACKDROP, BANNER, LONA, ADESIVO).
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'migracao_custo_m2_100x') then
    update public.catalogo
       set custo = custo / 100
     where quantidade = 1
       and custo > 500
       and (categoria ilike '%BACKDROP%' or categoria ilike '%BANNER%' or categoria ilike '%LONA%' or categoria ilike '%ADESIVO%');
    insert into public.app_settings (key, value) values ('migracao_custo_m2_100x', jsonb_build_object('aplicada_em', now()));
  end if;
end $$;

create or replace function private.categoria_bate(p_categoria text, p_toks text[])
 returns boolean
 language sql
 immutable
 set search_path to ''
as $function$
  select exists (
    select 1 from unnest(p_toks) t
    where t not in ('fosco', 'brilho', 'digital', 'laser', 'offset', 'frente', 'verso', 'cor', 'cores', 'colorido', 'preto', 'branco', 'personalizado', 'simples', 'duplo', 'express', 'papel', 'fino', 'grosso', 'pesado', 'leve')
      and (position(t in private.norm_busca(p_categoria)) > 0
           or position((case when t ~ 'ao$' then regexp_replace(t, 'ao$', 'oes')
                             when t ~ 'oes$' then regexp_replace(t, 'oes$', 'ao')
                             when t ~ 's$' then regexp_replace(t, 's$', '')
                             else t || 's' end) in private.norm_busca(p_categoria)) > 0));
$function$;

create or replace function private.inicio_contagem(p_momento timestamp with time zone)
 returns date
 language plpgsql
 stable
 set search_path to ''
as $function$
declare
  v_local timestamp := p_momento at time zone 'America/Sao_Paulo';
  v_dia date := (p_momento at time zone 'America/Sao_Paulo')::date;
begin
  -- Regra do fornecedor 12h com margem de segurança da Sua Gráfica BH: 10h30
  if public.is_business_day(v_dia) and v_local::time < '10:30:00'::time then
    return v_dia;
  end if;
  return public.add_business_days(v_dia, 1);
end;
$function$;

create or replace function public.add_business_days(p_start date, p_days integer)
 returns date
 language plpgsql
 stable
 set search_path to ''
as $function$
declare
  d date := p_start;
  n integer := greatest(coalesce(p_days, 0), 0);
begin
  while n > 0 loop
    d := d + 1;
    if public.is_business_day(d) then
      n := n - 1;
    end if;
  end loop;
  return d;
end;
$function$;

create or replace function public.calcular_prazo(p_sku text, p_agora timestamp with time zone default now(), p_arte_aprovada boolean default false)
 returns jsonb
 language plpgsql
 stable
 set search_path to ''
as $function$
declare
  pr public.parametros_comerciais%rowtype;
  v_lead integer;
  v_inicio date; v_pronto date;
  v_hoje date := (p_agora at time zone 'America/Sao_Paulo')::date;
  dias text[] := array['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado'];
  chaves text[] := array['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sab'];
  v_dow integer; v_expediente jsonb;
  v_pronto_txt text; v_quando text; v_frase text;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select p.lead_days into v_lead from public.products p where p.code = p_sku and p.active;
  if not found then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  if v_lead is null then return jsonb_build_object('ok', false, 'erro', 'prazo_nao_informado'); end if;

  v_inicio := private.inicio_contagem(p_agora);
  v_pronto := private.prazo_data(v_lead, p_agora);
  v_dow := extract(dow from v_pronto)::integer;
  v_expediente := pr.horario_atendimento -> chaves[v_dow + 1];
  v_pronto_txt := dias[v_dow + 1] || ', dia ' || extract(day from v_pronto)::integer;
  v_quando := case when v_inicio = v_hoje then 'hoje'
                   else dias[extract(dow from v_inicio)::integer + 1] || ', dia ' || extract(day from v_inicio)::integer end;
  v_frase := format('se pagar%s até 10h30 de %s, fica pronto %s %s',
                    case when p_arte_aprovada then '' else ' e mandar a arte' end,
                    v_quando,
                    case when v_dow in (0, 6) then 'no' else 'na' end, v_pronto_txt);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku,
    'data_pronto', v_pronto, 'data_pronto_texto', v_pronto_txt, 'dia_semana', dias[v_dow + 1],
    'inicio_contagem', v_inicio, 'pagar_ate_hora', '10h30',
    'depende_da_arte', not p_arte_aprovada,
    'retirada_abre', v_expediente ->> 'abre', 'retirada_fecha', v_expediente ->> 'fecha',
    'frase', v_frase);
end;
$function$;

create or replace function public.agente_bloqueio(p_conversation uuid)
 returns text
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  cfg record; v_global boolean; v_conv record; v_hora time; v_dow int; v_dias jsonb;
  v_auto boolean := coalesce((private.persona_cfg() ->> 'pos_pagamento_automatico')::boolean, true);
  v_piloto text[];
begin
  select * into cfg from public.agente_config where id = 1;
  select coalesce((value ->> 'enabled')::boolean, false) into v_global from public.app_settings where key = 'agent';
  if not coalesce(cfg.ia_ligada, false) or not coalesce(v_global, false) then return 'ia_pausada'; end if;

  if not coalesce(cfg.atende_24h, true) then
    v_hora := (now() at time zone 'America/Sao_Paulo')::time;
    v_dow := extract(dow from now() at time zone 'America/Sao_Paulo')::int;
    v_dias := coalesce(cfg.horario_ia -> 'dias', '[0,1,2,3,4,5,6]'::jsonb);
    if not (v_dias @> to_jsonb(v_dow)) or v_hora < coalesce((cfg.horario_ia ->> 'inicio')::time, '00:00'::time)
       or v_hora > coalesce((cfg.horario_ia ->> 'fim')::time, '23:59'::time) then
      return 'fora_do_horario';
    end if;
  end if;

  select cv.contact_id, cv.modo_atendimento, cv.ai_handled, cv.setor, ct.optout, ct.wa_id, ct.tags into v_conv
  from public.conversations cv join public.contacts ct on ct.id = cv.contact_id where cv.id = p_conversation;
  if not found then return 'conversa_inexistente'; end if;
  if v_conv.wa_id = any (private.wa_variantes(cfg.whatsapp_dono)) then return 'numero_do_dono'; end if;
  if coalesce(cfg.piloto_ativo, false) and not ('teste' = any (coalesce(v_conv.tags, '{}'))) then
    select coalesce(array_agg(x), '{}') into v_piloto from unnest(cfg.piloto_wa_ids) n, lateral unnest(private.wa_variantes(n)) x;
    if not (v_conv.wa_id = any (v_piloto))
       and (abs(hashtext(coalesce(v_conv.wa_id, ''))) % 100) >= coalesce(cfg.piloto_percentual, 0) then
      return 'fora_do_piloto';
    end if;
  end if;
  if coalesce(v_conv.optout, false) then return 'optout'; end if;
  if coalesce(v_conv.modo_atendimento, 'ia') <> 'ia' or not coalesce(v_conv.ai_handled, true) then return 'modo_humano'; end if;

  -- Se houver pedido em andamento, só bloqueia se o pós-pagamento automático estiver desligado ou se o setor for explicitamente arte/dono (humano)
  if exists (select 1 from public.orders o where o.contact_id = v_conv.contact_id and o.excluido_em is null and o.stage in ('pago', 'arte', 'prova', 'producao')) then
    if not v_auto then return 'pedido_pago'; end if;
    if v_conv.setor in ('arte', 'dono') then
      return 'aguardando_dono';
    end if;
  end if;
  return null;
end;
$function$;

create or replace function public.calcular_preco(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 stable
 set search_path to ''
as $function$
declare
  pr public.parametros_comerciais%rowtype;
  prod record;
  v_qtd integer := greatest(coalesce(p_quantidade, 1), 1);
  v_metodo text := case when p_contexto ->> 'simular_metodo' = 'true' then p_contexto ->> 'metodo' end;
  v_outros_receita numeric := coalesce((p_contexto ->> 'receita_outros')::numeric, 0);
  v_outros_custo numeric := coalesce((p_contexto ->> 'custo_outros')::numeric, 0);
  v_largura_mm integer := nullif((p_contexto ->> 'largura_mm')::integer, 0);
  v_altura_mm integer := nullif((p_contexto ->> 'altura_mm')::integer, 0);
  v_area_m2 numeric := 1.000;
  v_e_m2 boolean := false;
  v_custo_item numeric; v_custo_total numeric; v_extra numeric;
  v_base numeric; v_piso numeric; v_piso_duro numeric;
  v_mediana numeric; v_n integer; v_fator numeric; v_alvo numeric; v_preco numeric;
  v_ancora numeric; v_n_vendas integer; v_consulta uuid;
  v_regra text; v_conf text; v_nao_comp boolean := false; v_receita numeric; v_lucro numeric;
  v_avisos text[] := '{}';
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select c.sku, c.custo, c.active, c.vendavel, c.grupo_produto, c.especificacao_normalizada, c.tamanho_mm, c.categoria, c.descricao 
    into prod from public.catalogo c where c.sku = p_sku;
  if not found or not prod.active then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  if not prod.vendavel then return jsonb_build_object('ok', false, 'erro', 'item_nao_vendavel'); end if;

  -- Detecta se é produto cobrado por Metro Quadrado (m²)
  if (prod.tamanho_mm ilike '%metro%' 
      or prod.descricao ilike '%metro quadrado%' 
      or prod.descricao ilike '%(m²)%'
      or p_sku ilike '%M2%'
      or prod.tamanho_mm = '1000 x 1000'
      or prod.categoria ilike '%BANNER%' 
      or prod.categoria ilike '%LONA%' 
      or prod.categoria ilike '%BACKDROP%'
      or (prod.categoria ilike '%ADESIVO%' and (prod.descricao ilike '%METRO%' or prod.tamanho_mm ilike '%1000 x 1000%'))) then
    v_e_m2 := true;
    if v_largura_mm is not null and v_altura_mm is not null then
      v_area_m2 := round((v_largura_mm::numeric * v_altura_mm::numeric) / 1000000.0, 3);
      -- Regra do fornecedor: faturamento mínimo de 1 m² por peça
      if v_area_m2 < 1.000 then
        v_area_m2 := 1.000;
        v_avisos := array_append(v_avisos, 'faturamento_minimo_1m2');
      end if;
    else
      v_area_m2 := 1.000;
    end if;
    v_custo_item := prod.custo * v_area_m2 * v_qtd;
  else
    v_custo_item := prod.custo * v_qtd;
  end if;

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
    v_alvo := v_mediana * v_qtd * (case when v_e_m2 then v_area_m2 else 1 end) * v_fator;
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
    'calculado_por_m2', v_e_m2, 'area_m2_por_unidade', v_area_m2,
    'largura_mm', v_largura_mm, 'altura_mm', v_altura_mm,
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
 language plpgsql
 security definer
 set search_path to ''
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
  v_data_evento date := nullif(btrim(v_opc ->> 'data_evento'), '')::date;
  v_seg text;
  it jsonb; r jsonb; fr jsonb; pz jsonb;
  v_skus text[] := '{}'; v_qtds integer[] := '{}'; v_calcs jsonb[] := '{}';
  v_acabs text[] := '{}'; v_acab_custos numeric[] := '{}'; v_acab_dias integer[] := '{}';
  v_larguras integer[] := '{}'; v_alturas integer[] := '{}'; v_areas numeric[] := '{}';
  v_sku text; v_qtd integer; v_i integer; v_acab_nome text; v_acab_rec record;
  v_larg integer; v_alt integer;
  v_valor_itens numeric := 0; v_itens_frete jsonb := '[]'::jsonb;
  v_frete_modo text := 'retirada'; v_entrega text := 'retirada';
  v_avisos text[] := '{}'; v_arte_valor numeric := 0;
  v_pronto date; v_frase text; v_up jsonb;
  v_id uuid; v_num bigint; v_val jsonb; v_fin jsonb; v_unit numeric;
  v_pior text := 'alta'; v_tem_baixa boolean := false; v_tem_media boolean := false;
  v_itens_out jsonb := '[]'::jsonb; v_cep text; v_validade timestamptz; v_total numeric; v_frete_txt text;
  v_pub_avisos text[]; v_exib jsonb; v_dias_max_acab integer := 0;
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
    v_sku := btrim(coalesce(it ->> 'sku', ''));
    v_qtd := coalesce((it ->> 'quantidade')::integer, 1);
    v_acab_nome := nullif(btrim(it ->> 'acabamento'), '');
    v_larg := nullif((it ->> 'largura_mm')::integer, 0);
    v_alt := nullif((it ->> 'altura_mm')::integer, 0);

    if v_sku = '' or v_qtd < 1 or v_qtd > v_max_pacotes then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'alternativa', 'Cada item precisa de SKU e quantidade de 1 a ' || v_max_pacotes || '.');
    end if;

    r := public.calcular_preco(v_sku, v_qtd, jsonb_build_object('metodo', v_metodo, 'largura_mm', v_larg, 'altura_mm', v_alt));
    if not coalesce((r ->> 'ok')::boolean, false) then
      if r ->> 'erro' = 'sku_nao_encontrado' then
        return jsonb_build_object('status', 'bloqueado', 'motivo', 'sku_nao_encontrado',
                                  'alternativa', 'Esse item não está no catálogo: não informe valor; diga que vai conferir e chame o dono.');
      end if;
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'item_indisponivel', 'alternativa', 'Ofereça outro item do catálogo ou confirme com o dono.');
    end if;

    -- Busca acabamento se informado
    v_acab_rec := null;
    if v_acab_nome is not null then
      select * into v_acab_rec from public.produto_acabamentos
       where ativo and (nome ilike '%' || v_acab_nome || '%' or v_acab_nome ilike '%' || nome || '%') limit 1;
    end if;

    v_unid := v_unid + v_qtd * coalesce((select c.quantidade from public.catalogo c where c.sku = v_sku), 1);
    v_skus := v_skus || v_sku; 
    v_qtds := v_qtds || v_qtd;
    v_acabs := v_acabs || coalesce(v_acab_rec.nome, v_acab_nome, '');
    v_acab_custos := v_acab_custos || coalesce(v_acab_rec.custo_adicional, 0.00);
    v_acab_dias := v_acab_dias || coalesce(v_acab_rec.dias_uteis_adicionais, 0);
    v_larguras := v_larguras || coalesce(v_larg, 0);
    v_alturas := v_alturas || coalesce(v_alt, 0);
    v_areas := v_areas || coalesce((r ->> 'area_m2_por_unidade')::numeric, 0.000);
    

    if coalesce(v_acab_rec.dias_uteis_adicionais, 0) > v_dias_max_acab then
      v_dias_max_acab := v_acab_rec.dias_uteis_adicionais;
    end if;

    v_valor_itens := v_valor_itens + (r ->> 'preco_total')::numeric + (coalesce(v_acab_rec.custo_adicional, 0.00) * v_qtd);
    v_itens_frete := v_itens_frete || jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', v_qtd));
  end loop;

  if v_unid > v_max_unid then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'quantidade_irreal',
                              'alternativa', 'Quantidade acima do que a produção atende de uma vez: não informe valor; diga que vai conferir e chame o dono.');
  end if;

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

  v_cep := case when v_local ~ '^\s*\d{5}-?\d{3}\s*$' then regexp_replace(v_local, '\D', '', 'g') end;
  v_validade := now() + make_interval(hours => pr.validade_orcamento_horas);

  for v_i in 1 .. cardinality(v_skus) loop
    r := public.calcular_preco(v_skus[v_i], v_qtds[v_i], jsonb_build_object('metodo', v_metodo, 'entrega', case when v_entrega = 'bike' then 'bike' end, 'largura_mm', v_larguras[v_i], 'altura_mm', v_alturas[v_i]));
    v_calcs := v_calcs || r;
    if (r ->> 'confianca') = 'baixa' then v_tem_baixa := true; elsif (r ->> 'confianca') = 'media' then v_tem_media := true; end if;
  end loop;
  v_pior := case when v_tem_baixa then 'baixa' when v_tem_media then 'media' else 'alta' end;

  for v_i in 1 .. cardinality(v_skus) loop
    pz := public.calcular_prazo(v_skus[v_i], now(), false);
    if coalesce((pz ->> 'ok')::boolean, false) and (v_pronto is null or (pz ->> 'data_pronto')::date > v_pronto) then
      v_pronto := (pz ->> 'data_pronto')::date; v_frase := pz ->> 'frase';
    end if;
  end loop;

  -- Se acabamento tiver dias úteis adicionais, soma em DIAS ÚTEIS reais
  if v_dias_max_acab > 0 and v_pronto is not null then
    v_pronto := public.add_business_days(v_pronto, v_dias_max_acab);
    v_frase := coalesce(v_frase, '') || ' (+ ' || v_dias_max_acab || ' dia útil do acabamento)';
  end if;

  if v_pronto is null then v_avisos := array_append(v_avisos, 'prazo_a_confirmar'); end if;

  -- Alerta crítico de Data do Evento
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
  values (p_contact, v_conv, 'rascunho', v_entrega, case when v_cep is null then v_local end, v_cep, v_metodo, v_arte, v_arte_valor, 0,
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
                              'alternativa', 'Sugira uma especificação mais simples ou outra quantidade, ou chame o dono para decidir.');
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
    when 'uber_cliente' then 'Entrega por Uber Entrega, por conta do cliente. A retirada é grátis.'
    else 'Retirada grátis no centro de BH.' end;
  v_pub_avisos := array(select a from unnest(v_avisos) a where a in ('arte_com_frete_indisponivel', 'frete_a_confirmar', 'prazo_a_confirmar', 'prazo_estoura_data_evento', 'prazo_no_limite_do_evento', 'faturamento_minimo_1m2'));

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
