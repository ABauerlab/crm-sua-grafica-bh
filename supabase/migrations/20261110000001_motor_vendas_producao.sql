-- Motor de vendas: reflete as alterações já aplicadas em produção (10/11/2026).
-- Conteúdo idêntico ao da produção (conferido por hash do corpo das funções).
-- Idempotente: create or replace / if not exists. Não altera dados.
--   - montar_orcamento: acabamento lido em variáveis escalares com valores padrão (0.00 e 0 dias); sem records não atribuídos.
--   - agente_debounce: sem pg_sleep; sobreposição de mensagens nunca descarta nem devolve lote vazio.
--   - agente_iniciar: trava de conversa com teto de 60 s e auto-cura de execuções órfãs.
--   - agente_watchdog_reconciliar: varre leads parados (mais de 90 s sem resposta da IA) e destrava execuções órfãs.
--   - private.order_items_validar e definir_preco_item_pedido: custo unitário editável, com conferência de piso.
--   - calcular_acabamento_seguro: ATENÇÃO, consulta public.acabamentos, que não existe em produção. Não é chamada por montar_orcamento; fica para revisão.
--   - pg_trgm e índice GIN na descrição do catálogo.

create extension if not exists pg_trgm;

create index if not exists idx_catalogo_descricao_trgm on public.catalogo using gin (descricao gin_trgm_ops);

CREATE OR REPLACE FUNCTION public.calcular_acabamento_seguro(p_sku text, p_acabamento text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_dias integer := 0;
  v_preco numeric := 0;
begin
  if p_acabamento is not null and trim(p_acabamento) <> '' then
    select coalesce(dias, 0), coalesce(preco, 0)
    into v_dias, v_preco
    from public.acabamentos
    where (sku = p_sku or sku is null)
      and lower(nome) = lower(trim(p_acabamento))
    order by sku nulls last
    limit 1;

    if not found then
      v_dias := 0;
      v_preco := 0;
    end if;
  end if;

  return jsonb_build_object('dias', v_dias, 'preco', v_preco);
end;
$function$;

CREATE OR REPLACE FUNCTION private.order_items_validar()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  pr public.parametros_comerciais%rowtype;
  v_pct numeric;
  v_custo_cat numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  if pr.exigir_sku_pedidos and not new.fora_catalogo and tg_op = 'INSERT' and (new.code is null or btrim(new.code) = '') then
    raise exception 'Item sem SKU não pode entrar no pedido. Marque "item fora do catálogo" se for um item manual.' using errcode = 'P0001';
  end if;

  -- Se o custo unitário não foi informado (ou veio zerado), busca do catálogo. Se o usuário informou custo, respeita o digitado!
  if new.code is not null and not new.fora_catalogo and coalesce(new.unit_cost, 0) <= 0 then
    select c.custo into v_custo_cat from public.catalogo c where c.sku = new.code and c.active;
    if v_custo_cat is not null then
      new.unit_cost := v_custo_cat;
    end if;
  end if;

  -- Validação de piso duro: só avalia quando o preço unitário for maior que zero
  if new.unit_price > 0 and (tg_op = 'INSERT' or new.unit_price is distinct from old.unit_price or new.unit_cost is distinct from old.unit_cost or new.qty is distinct from old.qty) then
    v_pct := (private.taxa_pagamento(null) ->> 'pct')::numeric;
    -- Se for o dono (staff) ou se a flag de aprovação estiver ligada, não bloqueia
    if coalesce(current_setting('gbh.preco_aprovado', true), '') <> 'on' and not private.is_staff() then
      if new.unit_cost > 0 and new.unit_price * (1 - pr.imposto_pct / 100 - v_pct / 100) < new.unit_cost then
        raise exception 'Preço abaixo do piso duro (%): o item daria prejuízo.', private.brl(round(new.unit_cost / (1 - pr.imposto_pct / 100 - v_pct / 100), 2))
          using errcode = 'P0001';
      end if;
    end if;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.agente_debounce(p_message uuid, p_esperar boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  m record; v_corte timestamptz; v_msgs jsonb;
begin
  select * into m from public.messages where id = p_message;
  if not found then return jsonb_build_object('ultima', false); end if;

  if exists (
    select 1 from public.messages x
    where x.conversation_id = m.conversation_id
      and x.direction = 'in'
      and (x.created_at, x.id) > (m.created_at, m.id)
  ) then
    update public.agente_execucoes
    set status = 'agrupada', motivo = 'agrupada_com_mensagem_seguinte', finalizado_em = now()
    where message_id = p_message;
    return jsonb_build_object('ultima', false);
  end if;

  select max(created_at) into v_corte
  from public.messages
  where conversation_id = m.conversation_id and direction = 'out';

  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'tipo', t.type, 'corpo', t.body, 'media_id', t.media_id) order by t.created_at), '[]'::jsonb)
  into v_msgs
  from (
    select id, type, body, media_id, created_at
    from public.messages
    where conversation_id = m.conversation_id
      and direction = 'in'
      and (
        case
          when v_corte is not null and v_corte >= m.created_at then created_at >= m.created_at
          else created_at > coalesce(v_corte, '-infinity'::timestamptz)
        end
        or id = m.id
      )
    order by created_at desc
    limit 10
  ) t;

  if v_msgs = '[]'::jsonb or jsonb_array_length(v_msgs) = 0 then
    v_msgs := jsonb_build_array(jsonb_build_object('id', m.id, 'tipo', m.type, 'corpo', m.body, 'media_id', m.media_id));
  end if;

  return jsonb_build_object('ultima', true, 'mensagens', v_msgs, 'conversation_id', m.conversation_id, 'prolongou', false);
end;
$function$;

CREATE OR REPLACE FUNCTION public.agente_iniciar(p_message uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_ex record;
begin
  select * into v_ex from public.agente_execucoes where message_id = p_message;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'sem_execucao'); end if;
  perform pg_advisory_xact_lock(hashtext(v_ex.conversation_id::text));

  -- Destrava automaticamente execuções órfãs/travadas que estejam em 'rodando' há mais de 60 segundos
  update public.agente_execucoes
  set status = 'erro', motivo = 'timeout_auto_destravado', finalizado_em = now()
  where conversation_id = v_ex.conversation_id
    and status = 'rodando'
    and id <> v_ex.id
    and iniciado_em <= now() - interval '60 seconds';

  -- Se ainda houver execução rodando recentemente (< 60 segundos), retorna ocupado
  if exists (
    select 1 from public.agente_execucoes x
    where x.conversation_id = v_ex.conversation_id and x.status = 'rodando' and x.id <> v_ex.id and x.iniciado_em > now() - interval '60 seconds'
  ) then
    return jsonb_build_object('ok', false, 'motivo', 'ocupado');
  end if;

  update public.agente_execucoes set status = 'rodando', iniciado_em = now() where id = v_ex.id;
  return jsonb_build_object('ok', true, 'execucao_id', v_ex.id, 'conversation_id', v_ex.conversation_id, 'contact_id', v_ex.contact_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.agente_watchdog_reconciliar()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_rec record;
  v_recuperadas integer := 0;
  v_destravadas integer := 0;
begin
  with travadas as (
    update public.agente_execucoes
    set status = 'erro', motivo = 'timeout_watchdog_auto_destravado', finalizado_em = now()
    where status = 'rodando' and iniciado_em <= now() - interval '60 seconds'
    returning id
  )
  select count(*) into v_destravadas from travadas;

  for v_rec in (
    select c.id as conversation_id, c.contact_id, max(m.id) as last_in_id
    from public.conversations c
    join public.messages m on m.conversation_id = c.id and m.direction = 'in'
    where c.modo_atendimento = 'ia'
      and coalesce(c.ai_handled, true) = true
      and coalesce(c.optout, false) = false
      and m.created_at > now() - interval '12 hours'
      and m.created_at <= now() - interval '90 seconds'
      and not exists (
        select 1 from public.messages out_m
        where out_m.conversation_id = c.id
          and out_m.direction = 'out'
          and out_m.created_at >= m.created_at
      )
      and not exists (
        select 1 from public.agente_execucoes ex
        where ex.conversation_id = c.id
          and ex.status = 'rodando'
      )
    group by c.id, c.contact_id
  ) loop
    insert into public.agente_logs (conversation_id, actor, action, result, detail, workflow)
    values (v_rec.conversation_id, 'sistema', 'watchdog_detectou_lead_parado', 'alerta',
            jsonb_build_object('message_id', v_rec.last_in_id, 'atraso_segundos', 90), 'Watchdog Reconciliador');
    v_recuperadas := v_recuperadas + 1;
  end loop;

  return jsonb_build_object('ok', true, 'execucoes_destravadas', v_destravadas, 'conversas_pendentes_detectadas', v_recuperadas);
end;
$function$;

CREATE OR REPLACE FUNCTION public.definir_preco_item_pedido(p_item uuid, p_preco numeric, p_confirmar boolean DEFAULT false, p_motivo text DEFAULT NULL::text, p_apenas_simular boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  it public.order_items%rowtype; o public.orders%rowtype; calc jsonb; v_piso numeric; v_duro numeric; v_lucro numeric; v_faixa text; v_total numeric; v_custo numeric;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into it from public.order_items where id = p_item for update;
  if not found then raise exception 'Item não encontrado.' using errcode = 'P0001'; end if;
  select * into o from public.orders where id = it.order_id;
  if p_preco is null or p_preco < 0 then raise exception 'Preço inválido.' using errcode = 'P0001'; end if;
  v_total := p_preco * it.qty; v_custo := it.unit_cost * it.qty;
  calc := case when it.code is not null then public.calcular_preco(it.code, it.qty, '{}'::jsonb) else null end;
  if calc is not null and coalesce((calc ->> 'ok')::boolean, false) then
    v_piso := (calc ->> 'piso')::numeric; v_duro := (calc ->> 'piso_duro')::numeric;
  else  -- item digitado à mão ou fora do catálogo: pisos pelo custo informado
    v_duro := ceil(private.receita_para_lucro(v_custo, 0, 0, null) * 100) / 100;
    v_piso := ceil(greatest(v_custo * (select multiplicador_piso from public.parametros_comerciais where id = 1),
                            private.receita_para_lucro(v_custo, 0, (select lucro_liquido_minimo from public.parametros_comerciais where id = 1), null)) * 100) / 100;
  end if;
  v_lucro := private.lucro(v_total, v_custo, 0, null);
  v_faixa := case when v_custo > 0 and v_total < v_duro then 'abaixo_piso_duro' when v_custo > 0 and v_total < v_piso then 'entre_pisos' else 'ok' end;

  if p_apenas_simular then
    return jsonb_build_object('ok', v_faixa = 'ok' or (v_faixa in ('entre_pisos', 'abaixo_piso_duro') and p_confirmar),
                              'faixa', v_faixa, 'lucro_liquido', v_lucro, 'piso', v_piso / it.qty, 'piso_duro', v_duro / it.qty,
                              'total_linha', v_total, 'requer_confirmacao', v_faixa in ('entre_pisos', 'abaixo_piso_duro'));
  end if;

  -- Se estiver fora dos limites (entre pisos ou abaixo do piso duro), exige confirmação e motivo
  if v_faixa in ('entre_pisos', 'abaixo_piso_duro') and not p_confirmar then
    return jsonb_build_object('ok', false, 'requer_confirmacao', true, 'faixa', v_faixa, 'lucro_liquido', v_lucro, 'piso', v_piso / it.qty, 'piso_duro', v_duro / it.qty);
  end if;

  perform set_config('gbh.preco_aprovado', 'on', true);
  update public.order_items set unit_price = p_preco where id = p_item;
  insert into public.precos_manuais_log (order_id, order_item_id, sku, preco_antes, preco_depois, faixa, piso, piso_duro, lucro_liquido, motivo, usuario)
  values (it.order_id, it.id, it.code, it.unit_price, p_preco, v_faixa, v_piso / it.qty, v_duro / it.qty, v_lucro, left(p_motivo, 300), auth.uid());
  if v_faixa in ('entre_pisos', 'abaixo_piso_duro') then
    update public.orders set price_override_reason = coalesce(nullif(left(p_motivo, 300), ''), 'Preço manual aprovado pelo responsável: ' || v_faixa) where id = it.order_id;
  end if;
  return jsonb_build_object('ok', true, 'faixa', v_faixa, 'lucro_liquido', v_lucro, 'piso', v_piso / it.qty, 'piso_duro', v_duro / it.qty);
end;
$function$;

CREATE OR REPLACE FUNCTION public.montar_orcamento(p_contact uuid, p_itens jsonb, p_opcoes jsonb DEFAULT '{}'::jsonb)
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
  v_sku text; v_qtd integer; v_i integer; v_acab_nome text;
  v_acab_custo numeric := 0; v_acab_dia integer := 0; v_acab_real text := '';
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

    -- Busca acabamento de forma 100% segura usando variáveis escalares
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

    v_unid := v_unid + v_qtd * coalesce((select c.quantidade from public.catalogo c where c.sku = v_sku), 1);
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
