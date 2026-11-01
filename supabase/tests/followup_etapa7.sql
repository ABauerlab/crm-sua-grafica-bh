-- Etapa 7: follow-ups, pós-venda, status do pedido, observabilidade. Relógio acelerado: toda função recebe p_agora. Desfaz tudo no fim.
-- Sucesso aparece como "OK: N testes passaram"; falha lista os casos.
begin;
create temp table _t (n int, ok boolean, nome text);
create or replace function pg_temp.chk(p_ok boolean, p_nome text) returns void language plpgsql as $$
begin insert into _t values ((select count(*) + 1 from _t), coalesce(p_ok, false), p_nome); end $$;

-- cenário base: contato, conversa, orçamento enviado em t0 (a cliente escreveu 30 min antes do envio)
create or replace function pg_temp.mk(p_wa text, p_t0 timestamptz, p_itens jsonb default '[{"sku":"PFL02","quantidade":1},{"sku":"CFV20","quantidade":1}]') returns jsonb
language plpgsql as $$
declare v_ct uuid; v_cv uuid; v_o jsonb; v_oid uuid;
begin
  insert into public.contacts (wa_id, name) values (p_wa, 'maria souza') returning id into v_ct;
  insert into public.conversations (contact_id, ai_handled, modo_atendimento, last_inbound_at) values (v_ct, true, 'ia', p_t0 - interval '30 minutes') returning id into v_cv;
  v_o := public.montar_orcamento(v_ct, p_itens, jsonb_build_object('conversation_id', v_cv, 'bairro', 'Centro', 'arte', 'nenhuma'));
  v_oid := (v_o ->> 'orcamento_id')::uuid;
  perform public.orcamento_marcar_enviado(v_oid);
  update public.orcamentos set pdf_enviado_em = p_t0 where id = v_oid;
  return jsonb_build_object('ct', v_ct, 'cv', v_cv, 'orc', v_oid);
end $$;

do $$
declare
  t0 timestamptz := (date_trunc('day', now() at time zone 'America/Sao_Paulo') - interval '6 days' + interval '13 hours') at time zone 'America/Sao_Paulo';
  a jsonb; b jsonb; c jsonb; v_r jsonb; v_it jsonb; v_m jsonb; v_f uuid; v_n int; v_ct uuid; v_cv uuid; v_orc uuid; v_cond jsonb; v_s text;
  v_ord uuid; v_ord2 uuid; v_pag uuid; v_av uuid; v_staff uuid := gen_random_uuid(); v_sab timestamptz;
begin
  perform set_config('request.jwt.claim.role', 'service_role', true);
  update public.agente_config set ia_ligada = true, atende_24h = true where id = 1;
  update public.app_settings set value = jsonb_set(value, '{enabled}', 'true') where key = 'agent';
  perform pg_temp.chk((select validade_orcamento_horas from public.parametros_comerciais) = 168, 'validade do orçamento cobre a cadência (168 h)');

  -- ===================================================================================================================
  -- A. Cadência completa COM condição no F3 (janela fechada), F4 sem benefício (a política permite 1 condição por orçamento)
  -- ===================================================================================================================
  a := pg_temp.mk('5531977000001', t0);
  v_r := public.followup_agendar(t0 + interval '1 minute');
  perform pg_temp.chk((select count(*) from public.followup_fila where contact_id = (a ->> 'ct')::uuid and regra_codigo ~ '^F[1-4]$') = 4, 'A: agendador cria F1 a F4 uma vez');
  perform public.followup_agendar(t0 + interval '2 minutes');
  perform pg_temp.chk((select count(*) from public.followup_fila where contact_id = (a ->> 'ct')::uuid) = 4, 'A: agendador é idempotente');
  perform pg_temp.chk((public.followup_reservar('cadencia', 20, t0 + interval '1 hour') -> 'itens') = '[]'::jsonb, 'A: nada vence antes de 2 horas');

  v_r := public.followup_reservar('cadencia', 20, t0 + interval '2 hours 10 minutes');
  perform pg_temp.chk(jsonb_array_length(v_r -> 'itens') = 1 and v_r #>> '{itens,0,regra}' = 'F1' and not (v_r #>> '{itens,0,precisa_condicao}')::boolean, 'A: F1 reservado, sem condição');
  v_f := (v_r #>> '{itens,0,fila_id}')::uuid;
  v_m := public.followup_montar(v_f, t0 + interval '2 hours 10 minutes');
  perform pg_temp.chk(v_m ->> 'acao' = 'enviar' and v_m ->> 'via' = 'livre' and v_m ->> 'texto' like 'Oi, Maria! %SG-%', 'A: F1 é mensagem livre com o nome e o número do orçamento');
  perform pg_temp.chk(v_m ->> 'texto' !~ '[—–]' and v_m ->> 'texto' !~* 'custo|margem|piso|sku', 'A: F1 sem travessão nem termo interno');
  perform public.followup_resultado(v_f, true, 'livre', 'wamid.A1', null, false, t0 + interval '2 hours 11 minutes');
  perform pg_temp.chk((select status from public.followup_fila where id = v_f) = 'enviado', 'A: F1 enviado');
  perform pg_temp.chk((public.followup_resultado(v_f, true, 'livre', 'wamid.A1x') ->> 'ja_registrado')::boolean, 'A: resultado repetido não duplica');

  v_r := public.followup_reservar('cadencia', 20, t0 + interval '20 hours 30 minutes');
  perform pg_temp.chk(v_r #>> '{itens,0,regra}' = 'F2', 'A: F2 cerca de 20 horas depois');
  v_f := (v_r #>> '{itens,0,fila_id}')::uuid;
  v_m := public.followup_montar(v_f, t0 + interval '20 hours 30 minutes');
  perform pg_temp.chk(v_m ->> 'via' = 'livre' and v_m ->> 'texto' like '%vale até%' and v_m ->> 'texto' like '%fica pronto dia%', 'A: F2 livre cita validade e data de pronto, sem condição');
  perform public.followup_resultado(v_f, true, 'livre', 'wamid.A2', null, false, t0 + interval '20 hours 31 minutes');

  v_r := public.followup_reservar('cadencia', 20, t0 + interval '2 days');
  perform pg_temp.chk(v_r #>> '{itens,0,regra}' = 'F3' and (v_r #>> '{itens,0,precisa_condicao}')::boolean and v_r #>> '{itens,0,gatilho}' = 'G2', 'A: F3 pede a condição G2 à ferramenta');
  v_f := (v_r #>> '{itens,0,fila_id}')::uuid;
  v_cond := public.oferecer_condicao_especial((a ->> 'orc')::uuid, 'G2');
  perform pg_temp.chk(v_cond ->> 'tipo' <> 'sem_condicao', 'A: a função de condição devolveu benefício (' || coalesce(v_cond ->> 'tipo', '?') || ')');
  v_m := public.followup_montar(v_f, t0 + interval '2 days');
  perform pg_temp.chk(v_m ->> 'via' = 'template' and v_m ->> 'template' = 'condicao_especial_orcamento' and jsonb_array_length(v_m -> 'params') = 4, 'A: janela fechada usa o template condicao_especial_orcamento com 4 variáveis');
  perform pg_temp.chk((v_m ->> 'com_condicao')::boolean and v_m ->> 'texto' like '%condição especial%', 'A: texto livre traz a condição (texto_curto do banco)');
  perform pg_temp.chk((select condicao_id from public.followup_fila where id = v_f) is not null, 'A: fila guarda a condição usada');
  perform public.followup_resultado(v_f, true, 'template', 'wamid.A3', null, false, t0 + interval '2 days 1 minute');
  perform pg_temp.chk((select followup_codigo from public.condicoes_especiais where orcamento_id = (a ->> 'orc')::uuid limit 1) = 'F3', 'A: resultado gravado em condicoes_especiais');
  perform pg_temp.chk(exists (select 1 from public.precos_praticados where orcamento_id = (a ->> 'orc')::uuid and followup_codigo = 'F3'), 'A: resultado gravado em precos_praticados');

  v_r := public.followup_reservar('cadencia', 20, t0 + interval '5 days');
  perform pg_temp.chk(v_r #>> '{itens,0,regra}' = 'F4' and v_r #>> '{itens,0,gatilho}' = 'G3', 'A: F4 no dia 5 (G3)');
  v_f := (v_r #>> '{itens,0,fila_id}')::uuid;
  v_cond := public.oferecer_condicao_especial((a ->> 'orc')::uuid, 'G3');
  perform pg_temp.chk(v_cond ->> 'tipo' = 'sem_condicao', 'A: segunda condição no mesmo orçamento não existe (uma por orçamento)');
  v_m := public.followup_montar(v_f, t0 + interval '5 days');
  perform pg_temp.chk(v_m ->> 'template' = 'ultima_chance_orcamento' and jsonb_array_length(v_m -> 'params') = 2 and not (v_m ->> 'com_condicao')::boolean, 'A: sem condição, F4 vira ultima_chance_orcamento sem benefício');
  perform public.followup_resultado(v_f, true, 'template', 'wamid.A4', null, false, t0 + interval '5 days 1 minute');
  perform pg_temp.chk((select status_lead from public.contacts where id = (a ->> 'ct')::uuid) = 'frio', 'A: depois do F4 o contato vira lead frio');
  perform pg_temp.chk(not exists (select 1 from public.followup_fila where contact_id = (a ->> 'ct')::uuid and status in ('pendente', 'reservado')), 'A: a cadência para (nada pendente)');

  -- ===================================================================================================================
  -- B. Sem condição disponível (usou condição há menos de 30 dias): lembretes simples; janela aberta usa texto livre
  -- ===================================================================================================================
  b := pg_temp.mk('5531977000002', t0);
  insert into public.orcamentos (contact_id, status, teste) values ((b ->> 'ct')::uuid, 'pago', true) returning id into v_orc;
  insert into public.condicoes_especiais (orcamento_id, contact_id, degrau, gatilho, tipo, valor, texto_curto, valida_ate, resultado)
  values (v_orc, (b ->> 'ct')::uuid, 2, 'G1', 'desconto', 10, 'condição antiga', now() - interval '3 days', 'expirada');
  perform public.followup_agendar(t0 + interval '1 minute');
  update public.followup_fila set status = 'enviado', enviado_em = t0 + interval '3 hours' where contact_id = (b ->> 'ct')::uuid and regra_codigo in ('F1', 'F2');
  v_r := public.followup_reservar('cadencia', 50, t0 + interval '2 days');
  select x into v_it from jsonb_array_elements(v_r -> 'itens') x where x ->> 'contact_id' = b ->> 'ct' and x ->> 'regra' = 'F3';
  perform pg_temp.chk(v_it is not null, 'B: F3 reservado');
  v_f := (v_it ->> 'fila_id')::uuid;
  v_cond := public.oferecer_condicao_especial((b ->> 'orc')::uuid, 'G2');
  perform pg_temp.chk(v_cond ->> 'tipo' = 'sem_condicao', 'B: quem usou condição nos últimos 30 dias não recebe outra');
  v_m := public.followup_montar(v_f, t0 + interval '2 days');
  perform pg_temp.chk(v_m ->> 'template' = 'orcamento_vence_hoje' and v_m ->> 'via' = 'template', 'B: janela fechada e sem condição manda orcamento_vence_hoje');
  -- janela aberta (a cliente respondeu e o agente reabriu a linha): texto livre
  update public.conversations set last_inbound_at = t0 + interval '2 days' - interval '2 hours' where id = (b ->> 'cv')::uuid;
  v_m := public.followup_montar(v_f, t0 + interval '2 days');
  perform pg_temp.chk(v_m ->> 'via' = 'livre' and v_m ->> 'texto' like '%vale até%' and v_m ->> 'texto' !~ 'condição especial', 'B: janela aberta e sem condição manda texto livre simples');
  -- F1 com janela fechada não gasta template
  update public.conversations set last_inbound_at = t0 - interval '3 days' where id = (b ->> 'cv')::uuid;
  update public.followup_fila set regra_codigo = 'F1' where id = v_f;
  v_m := public.followup_montar(v_f, t0 + interval '2 days');
  perform pg_temp.chk(v_m ->> 'acao' = 'pular' and v_m ->> 'motivo' = 'janela_fechada', 'B: F1 sem janela é pulado (não paga template)');
  update public.followup_fila set regra_codigo = 'F3' where id = v_f;

  -- ===================================================================================================================
  -- C. F4 com condição (política com 2 condições por orçamento) e lead frio
  -- ===================================================================================================================
  update public.politica_desconto set max_condicoes_por_orcamento = 2;
  c := pg_temp.mk('5531977000003', t0);
  perform public.followup_agendar(t0 + interval '1 minute');
  update public.followup_fila set status = 'enviado', enviado_em = t0 + interval '3 hours' where contact_id = (c ->> 'ct')::uuid and regra_codigo in ('F1', 'F2', 'F3');
  v_r := public.followup_reservar('cadencia', 50, t0 + interval '5 days');
  select x into v_it from jsonb_array_elements(v_r -> 'itens') x where x ->> 'contact_id' = c ->> 'ct' and x ->> 'regra' = 'F4';
  v_f := (v_it ->> 'fila_id')::uuid;
  v_cond := public.oferecer_condicao_especial((c ->> 'orc')::uuid, 'G3');
  perform pg_temp.chk(v_cond ->> 'tipo' <> 'sem_condicao', 'C: F4 recebe a última condição (degrau 3) quando a função permite (' || coalesce(v_cond ->> 'tipo', '?') || ')');
  v_m := public.followup_montar(v_f, t0 + interval '5 days');
  perform pg_temp.chk(v_m ->> 'template' = 'condicao_especial_orcamento' and v_m ->> 'texto' like '%Última chamada%', 'C: F4 com condição usa condicao_especial_orcamento');
  perform public.followup_resultado(v_f, true, 'template', 'wamid.C4', null, false, t0 + interval '5 days 1 minute');
  perform pg_temp.chk((select status_lead from public.contacts where id = (c ->> 'ct')::uuid) = 'frio', 'C: marca lead frio e para');
  update public.politica_desconto set max_condicoes_por_orcamento = 1;

  -- ===================================================================================================================
  -- D. Condição expirada: link invalidado, orçamento atualizado vence, não oferece de novo e o último lembrete não cita mais
  -- ===================================================================================================================
  select orcamento_novo_id into v_orc from public.condicoes_especiais where orcamento_id = (c ->> 'orc')::uuid and resultado = 'oferecida' limit 1;
  update public.condicoes_especiais set valida_ate = now() - interval '1 hour' where orcamento_id = (c ->> 'orc')::uuid;
  perform public.expirar_condicoes_e_orcamentos();
  perform pg_temp.chk((select count(*) from public.condicoes_especiais where orcamento_id = (c ->> 'orc')::uuid and resultado = 'expirada') >= 1, 'D: condição vencida vira expirada');
  perform pg_temp.chk(v_orc is null or (select status from public.orcamentos where id = v_orc) = 'expirado', 'D: orçamento atualizado vence junto');
  perform pg_temp.chk((public.calcular_condicao_especial((c ->> 'orc')::uuid, 'G3') ->> 'tipo') = 'sem_condicao', 'D: depois de expirar a condição não se repete (volta ao preço normal)');

  -- ===================================================================================================================
  -- E. Optout, pago no meio da cadência, modo humano, IA pausada, fora do horário e limite de 1 por dia
  -- ===================================================================================================================
  a := pg_temp.mk('5531977000010', t0);   -- optout
  b := pg_temp.mk('5531977000011', t0);   -- pago no meio
  c := pg_temp.mk('5531977000012', t0);   -- modo humano
  perform public.followup_agendar(t0 + interval '1 minute');
  update public.contacts set marketing_consent = 'opted_out', marketing_consent_at = now(), marketing_consent_source = 'whatsapp' where id = (a ->> 'ct')::uuid;
  insert into public.orders (contact_id, conversation_id, title) values ((b ->> 'ct')::uuid, (b ->> 'cv')::uuid, 'Pedido') returning id into v_ord;
  update public.orders set payment_status = 'aprovado', stage = 'pago', paid_at = t0 + interval '3 hours' where id = v_ord;
  update public.conversations set modo_atendimento = 'humano', ai_handled = false where id = (c ->> 'cv')::uuid;
  v_r := public.followup_reservar('cadencia', 100, t0 + interval '5 days');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(v_r -> 'itens') x where x ->> 'contact_id' in (a ->> 'ct', b ->> 'ct', c ->> 'ct')), 'E: optout, pago e modo humano não recebem nada');
  perform pg_temp.chk((select count(*) from public.followup_fila where contact_id = (a ->> 'ct')::uuid and status = 'cancelado' and motivo = 'optout') = 4, 'E: optout cancela toda a cadência');
  perform pg_temp.chk((select count(*) from public.followup_fila where contact_id = (b ->> 'ct')::uuid and status = 'cancelado' and motivo = 'pago') = 4, 'E: pagamento no meio cancela tudo');
  perform pg_temp.chk((select count(*) from public.followup_fila where contact_id = (c ->> 'ct')::uuid and status = 'pulado' and motivo = 'modo_humano') = 4, 'E: modo humano pula tudo');

  -- IA pausada, horário e limite diário
  a := pg_temp.mk('5531977000020', t0);
  b := pg_temp.mk('5531977000021', t0, '[{"sku":"CFV20","quantidade":1}]');
  perform public.followup_agendar(t0 + interval '1 minute');
  update public.app_settings set value = jsonb_set(value, '{enabled}', 'false') where key = 'agent';
  v_r := public.followup_reservar('cadencia', 100, t0 + interval '2 hours 10 minutes');
  perform pg_temp.chk(jsonb_array_length(v_r -> 'itens') = 0 and (select status from public.followup_fila where contact_id = (a ->> 'ct')::uuid and regra_codigo = 'F1') = 'pendente', 'E: Pausar IA segura os follow-ups (continuam pendentes)');
  update public.app_settings set value = jsonb_set(value, '{enabled}', 'true') where key = 'agent';
  -- 23h BRT (fora das 8h às 20h)
  v_r := public.followup_reservar('cadencia', 100, (date_trunc('day', t0 at time zone 'America/Sao_Paulo') + interval '23 hours') at time zone 'America/Sao_Paulo');
  perform pg_temp.chk(jsonb_array_length(v_r -> 'itens') = 0, 'E: fora das 8h às 20h nada sai');
  perform pg_temp.chk((select extract(hour from agendado_para at time zone 'America/Sao_Paulo') from public.followup_fila where contact_id = (a ->> 'ct')::uuid and regra_codigo = 'F1') = 8, 'E: o envio fica para as 8h seguintes');
  -- limite de 1 por dia: dois lembretes do mesmo contato no mesmo dia
  update public.followup_fila set agendado_para = t0 + interval '2 hours' where contact_id = (a ->> 'ct')::uuid and regra_codigo in ('F1', 'F2');
  v_r := public.followup_reservar('cadencia', 100, t0 + interval '2 hours 10 minutes');
  perform pg_temp.chk((select count(*) from jsonb_array_elements(v_r -> 'itens') x where x ->> 'contact_id' = a ->> 'ct') = 1, 'E: no máximo 1 mensagem proativa por dia por contato');
  perform pg_temp.chk((select agendado_para from public.followup_fila where contact_id = (a ->> 'ct')::uuid and status = 'pendente' and regra_codigo in ('F1', 'F2') order by agendado_para limit 1) > t0 + interval '10 hours', 'E: a segunda fica para o dia seguinte');

  -- ===================================================================================================================
  -- F. Pagamento pendente: 1 h, 6 h e 24 h; condição vigente é avisada no último; pago cancela
  -- ===================================================================================================================
  b := pg_temp.mk('5531977000030', t0);
  select orcamento_id into v_orc from (select (b ->> 'orc')::uuid as orcamento_id) z;
  v_ord := (select (public.preparar_link_pagamento(v_orc) ->> 'order_id')::uuid);
  if v_ord is null then
    insert into public.orders (contact_id, conversation_id, title) values ((b ->> 'ct')::uuid, (b ->> 'cv')::uuid, 'Pedido do orçamento') returning id into v_ord;
    update public.orcamentos set order_id = v_ord where id = v_orc;
  end if;
  update public.pagamentos set link_ativo = false where order_id = v_ord;
  insert into public.pagamentos (order_id, eh_link, link_ativo, link, valor, status, modo, criado_em)
  values (v_ord, true, true, 'https://pagamento.exemplo/abc', 100, 'pendente', 'teste', t0) returning id into v_pag;
  perform public.followup_agendar(t0 + interval '1 minute');
  update public.followup_fila set status = 'cancelado', motivo = 'teste' where contact_id = (b ->> 'ct')::uuid and regra_codigo ~ '^F[1-4]$';
  perform pg_temp.chk((select count(*) from public.followup_fila where order_id = v_ord and regra_codigo like 'PAG_%') = 3, 'F: três lembretes de pagamento (1, 6 e 24 horas)');
  update public.conversations set last_inbound_at = t0 where id = (b ->> 'cv')::uuid;
  v_r := public.followup_reservar('cadencia', 100, t0 + interval '1 hour 5 minutes');
  select x into v_it from jsonb_array_elements(v_r -> 'itens') x where x ->> 'contact_id' = b ->> 'ct' and x ->> 'regra' = 'PAG_1H';
  perform pg_temp.chk(v_it is not null, 'F: PAG_1H reservado');
  v_m := public.followup_montar((v_it ->> 'fila_id')::uuid, t0 + interval '1 hour 5 minutes');
  perform pg_temp.chk(v_m ->> 'via' = 'livre' and v_m ->> 'texto' like '%https://pagamento.exemplo/abc%', 'F: lembrete livre leva o link ativo');
  perform public.followup_resultado((v_it ->> 'fila_id')::uuid, true, 'livre', 'wamid.P1', null, false, t0 + interval '1 hour 6 minutes');
  -- 6 h, mesmo dia: o limite diário adia
  v_r := public.followup_reservar('cadencia', 100, t0 + interval '6 hours 5 minutes');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(v_r -> 'itens') x where x ->> 'contact_id' = b ->> 'ct'), 'F: PAG_6H no mesmo dia espera o dia seguinte (1 por dia)');
  update public.followup_fila set agendado_para = t0 + interval '1 day' where order_id = v_ord and regra_codigo = 'PAG_6H';
  -- 24 h com condição vigente: avisa que expira
  insert into public.condicoes_especiais (orcamento_id, contact_id, degrau, gatilho, tipo, valor, texto_curto, valida_ate, resultado)
  values (v_orc, (b ->> 'ct')::uuid, 2, 'G2', 'desconto', 8, 'R$ 8,00 de desconto', t0 + interval '3 days', 'oferecida');
  update public.followup_fila set agendado_para = t0 + interval '2 days' where order_id = v_ord and regra_codigo = 'PAG_24H';
  update public.followup_fila set status = 'enviado', enviado_em = t0 + interval '1 day' where order_id = v_ord and regra_codigo = 'PAG_6H';
  v_r := public.followup_reservar('cadencia', 100, t0 + interval '2 days');
  select x into v_it from jsonb_array_elements(v_r -> 'itens') x where x ->> 'contact_id' = b ->> 'ct' and x ->> 'regra' = 'PAG_24H';
  v_m := public.followup_montar((v_it ->> 'fila_id')::uuid, t0 + interval '2 days');
  perform pg_temp.chk(v_m ->> 'texto' like '%condição especial vale só até%', 'F: último lembrete avisa que a condição expira');
  perform pg_temp.chk(v_m ->> 'template' = 'pagamento_pendente' and v_m ->> 'via' = 'template', 'F: janela fechada usa pagamento_pendente');
  -- pagamento aprovado cancela o que falta
  update public.followup_fila set status = 'pendente' where id = (v_it ->> 'fila_id')::uuid;
  update public.orders set payment_status = 'aprovado', stage = 'pago', paid_at = t0 + interval '2 days' where id = v_ord;
  v_r := public.followup_reservar('cadencia', 100, t0 + interval '2 days 5 minutes');
  perform pg_temp.chk((select status from public.followup_fila where id = (v_it ->> 'fila_id')::uuid) = 'cancelado', 'F: pedido pago cancela o lembrete pendente');

  -- ===================================================================================================================
  -- G. Falhas: tentativas e erro
  -- ===================================================================================================================
  a := pg_temp.mk('5531977000040', t0);
  perform public.followup_agendar(t0 + interval '1 minute');
  v_r := public.followup_reservar('cadencia', 100, t0 + interval '2 hours 10 minutes');
  select x into v_it from jsonb_array_elements(v_r -> 'itens') x where x ->> 'contact_id' = a ->> 'ct';
  v_f := (v_it ->> 'fila_id')::uuid;
  perform public.followup_resultado(v_f, false, null, null, 'meta_131047', false, t0 + interval '2 hours 11 minutes');
  perform pg_temp.chk((select status from public.followup_fila where id = v_f) = 'pendente' and (select agendado_para from public.followup_fila where id = v_f) > t0 + interval '2 hours 15 minutes', 'G: falha temporária volta para a fila com espera');
  update public.followup_fila set status = 'reservado', reservado_em = t0, tentativas = 3 where id = v_f;
  perform public.followup_liberar_travados(t0 + interval '1 hour');
  perform pg_temp.chk((select status from public.followup_fila where id = v_f) = 'erro', 'G: reserva travada na terceira tentativa vira erro');
  update public.followup_fila set status = 'reservado', reservado_em = t0, tentativas = 1 where id = v_f;
  perform public.followup_liberar_travados(t0 + interval '1 hour');
  perform pg_temp.chk((select status from public.followup_fila where id = v_f) = 'pendente', 'G: reserva travada com tentativas sobrando é liberada (reprocesso seguro)');
  perform public.followup_resultado(v_f, false, null, null, 'sem_optin_marketing', true);
  perform pg_temp.chk((select status from public.followup_fila where id = v_f) = 'pulado', 'G: falha permanente pula sem repetir');

  -- ===================================================================================================================
  -- H. Re-armar depois da resposta ("vou pensar")
  -- ===================================================================================================================
  b := pg_temp.mk('5531977000050', t0);
  perform public.followup_agendar(t0 + interval '1 minute');
  update public.followup_fila set status = 'cancelado', motivo = 'cliente_respondeu' where contact_id = (b ->> 'ct')::uuid;
  v_r := public.agente_agendar_followup((b ->> 'cv')::uuid, 'orcamento', 'dia2');
  perform pg_temp.chk((v_r ->> 'ok')::boolean and (select status from public.followup_fila where contact_id = (b ->> 'ct')::uuid and regra_codigo = 'F3') = 'pendente', 'H: o agente reabre o F3 depois da resposta do cliente');

  -- ===================================================================================================================
  -- I. Pós-venda e recompra
  -- ===================================================================================================================
  insert into public.contacts (wa_id, name) values ('5531977000060', 'joão pedro') returning id into v_ct;
  insert into public.conversations (contact_id, ai_handled, modo_atendimento, last_inbound_at) values (v_ct, false, 'humano', t0 - interval '10 days') returning id into v_cv;
  insert into public.orders (contact_id, conversation_id, title, stage, payment_status, paid_at, delivery_method)
  values (v_ct, v_cv, 'Cartões', 'producao', 'aprovado', t0 - interval '5 days', 'retirada') returning id into v_ord;
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) values (v_ord, 'CFV20', 'Cartão de visita 1000 un', 1, 50, 120);
  v_r := public.pedido_marcar_entregue(v_ord);
  perform pg_temp.chk((v_r ->> 'ok')::boolean and (select stage from public.orders where id = v_ord) = 'entregue', 'I: marcar entregue move para Entregue');
  perform pg_temp.chk((select count(*) from public.followup_fila where order_id = v_ord and regra_codigo in ('POS_ENTREGA', 'RECOMPRA_CARTAO')) = 2, 'I: entrega agenda satisfação e recompra do cartão');
  perform pg_temp.chk(not exists (select 1 from public.followup_fila where order_id = v_ord and regra_codigo in ('RECOMPRA_ADESIVO', 'RECOMPRA_PANFLETO')), 'I: só o ciclo do produto comprado');
  select delivered_at into t0 from public.orders where id = v_ord;   -- a entrega aconteceu agora
  v_r := public.followup_reservar('pos', 20, t0 + interval '1 day 2 hours');
  perform pg_temp.chk(jsonb_array_length(v_r -> 'itens') = 1 and v_r #>> '{itens,0,regra}' = 'POS_ENTREGA', 'I: no dia seguinte sai só a satisfação, mesmo em modo humano');
  v_f := (v_r #>> '{itens,0,fila_id}')::uuid;
  v_m := public.followup_montar(v_f, t0 + interval '1 day 2 hours');
  perform pg_temp.chk(v_m ->> 'template' = 'pos_venda_satisfacao' and v_m ->> 'via' = 'template', 'I: janela fechada usa pos_venda_satisfacao');
  update public.conversations set last_inbound_at = t0 + interval '1 day' where id = v_cv;
  v_m := public.followup_montar(v_f, t0 + interval '1 day 2 hours');
  perform pg_temp.chk(v_m ->> 'via' = 'livre' and v_m ->> 'texto' like '%adesivos ou panfletos%', 'I: janela aberta manda texto livre com upsell relevante');
  perform public.followup_resultado(v_f, true, 'livre', 'wamid.I1', null, false, t0 + interval '1 day 2 hours');
  v_r := public.followup_reservar('pos', 20, t0 + interval '60 days 1 hour');
  perform pg_temp.chk(v_r #>> '{itens,0,regra}' = 'RECOMPRA_CARTAO', 'I: recompra do cartão em cerca de 60 dias');
  v_f := (v_r #>> '{itens,0,fila_id}')::uuid;
  v_m := public.followup_montar(v_f, t0 + interval '60 days 1 hour');
  perform pg_temp.chk(v_m ->> 'template' = 'recompra_lembrete' and jsonb_array_length(v_m -> 'params') = 2, 'I: recompra usa recompra_lembrete (nome e produto)');
  perform public.followup_resultado(v_f, true, 'template', 'wamid.I2', null, false, t0 + interval '60 days 2 hours');
  perform pg_temp.chk(((public.recompra_disparar(v_f)) ->> 'motivo') = 'ja_enviado', 'I: recompra uma vez por ciclo (disparo manual recusa)');
  -- lista e disparo manual de outro ciclo, com optout
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  insert into auth.users (id, email) values (v_staff, 'contato.bauerlab@gmail.com');
  insert into public.profiles (id, name, role) values (v_staff, 'Dono', 'admin');
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('email', 'contato.bauerlab@gmail.com', 'role', 'authenticated')::text, true);
  perform pg_temp.chk(jsonb_array_length(public.recompra_lista()) >= 1, 'I: lista Recompra aparece para o dono');
  perform set_config('request.jwt.claim.role', 'service_role', true);
  update public.contacts set marketing_consent = 'opted_out', marketing_consent_at = now(), marketing_consent_source = 'whatsapp' where id = v_ct;
  update public.followup_fila set status = 'cancelado', motivo = 'x' where id = v_f;
  perform pg_temp.chk(((public.recompra_disparar(v_f)) ->> 'motivo') = 'optout', 'I: disparo manual respeita optout');
  update public.contacts set marketing_consent = 'none', marketing_consent_at = null, marketing_consent_source = null where id = v_ct;
  v_r := public.recompra_disparar(v_f);
  perform pg_temp.chk((v_r ->> 'ok')::boolean and (select manual from public.followup_fila where id = v_f), 'I: disparo manual reagenda para o próximo horário permitido');

  -- ===================================================================================================================
  -- J. Status do pedido (WF8): retirada, entrega, idempotência
  -- ===================================================================================================================
  insert into public.contacts (wa_id, name) values ('5531977000070', 'ana lima') returning id into v_ct;
  insert into public.conversations (contact_id, ai_handled, modo_atendimento, last_inbound_at) values (v_ct, false, 'humano', now() - interval '2 hours') returning id into v_cv;
  insert into public.orders (contact_id, conversation_id, title, stage, payment_status, paid_at, delivery_method)
  values (v_ct, v_cv, 'Panfletos', 'producao', 'aprovado', now() - interval '1 day', 'retirada') returning id into v_ord;
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) values (v_ord, 'PFL01', 'Panfleto', 1, 50, 120);
  perform pg_temp.chk((select subestatus_pedido from public.orders where id = v_ord) = 'em_producao' or (select subestatus_pedido from public.orders where id = v_ord) is null, 'J: card em Produção começa em produção (ou sem subestatus em pedido antigo)');
  v_r := public.pedido_definir_subestatus(v_ord, 'pronto_retirada');
  perform pg_temp.chk((v_r ->> 'ok')::boolean and v_r ->> 'aviso' = 'agendado', 'J: pronto para retirada agenda o aviso');
  perform pg_temp.chk((public.pedido_definir_subestatus(v_ord, 'pronto_retirada') ->> 'ok')::boolean, 'J: repetir o clique não cria outro aviso');
  perform pg_temp.chk((select count(*) from public.pedido_avisos where order_id = v_ord) = 1, 'J: um aviso por pedido e tipo');
  -- segunda-feira 10h (aberto) e sábado 10h (fechado)
  v_sab := (date_trunc('week', now() at time zone 'America/Sao_Paulo') + interval '1 week' + interval '5 days 10 hours') at time zone 'America/Sao_Paulo';
  v_r := public.pedido_avisos_reservar(10, v_sab);
  perform pg_temp.chk(jsonb_array_length(v_r -> 'itens') = 1, 'J: WF8 reserva o aviso pendente');
  v_av := (v_r #>> '{itens,0,aviso_id}')::uuid;
  update public.conversations set last_inbound_at = v_sab - interval '1 hour' where id = v_cv;
  v_m := public.pedido_aviso_montar(v_av, v_sab);
  perform pg_temp.chk(v_m ->> 'via' = 'livre' and v_m ->> 'texto' like '%Rio de Janeiro, 462%' and v_m ->> 'texto' like '%sexta das 9h às 18h30%', 'J: janela aberta manda texto livre com endereço e horário');
  perform pg_temp.chk(v_m ->> 'texto' like '%Estamos fora do horário agora%' and v_m ->> 'texto' like '%segunda%', 'J: fora do expediente informa o próximo horário disponível');
  update public.conversations set last_inbound_at = v_sab - interval '3 days' where id = v_cv;
  v_m := public.pedido_aviso_montar(v_av, v_sab);
  perform pg_temp.chk(v_m ->> 'via' = 'template' and v_m ->> 'template' = 'pedido_pronto_retirada' and jsonb_array_length(v_m -> 'params') = 2, 'J: janela fechada usa pedido_pronto_retirada');
  v_m := public.pedido_aviso_montar(v_av, (date_trunc('day', now() at time zone 'America/Sao_Paulo') - ((extract(dow from now() at time zone 'America/Sao_Paulo')::int + 6) % 7) * interval '1 day' + interval '10 hours') at time zone 'America/Sao_Paulo');
  perform pg_temp.chk(v_m ->> 'texto' like '%Pode retirar hoje até as 17h%', 'J: dentro do expediente informa até que horas pode retirar');
  perform public.pedido_aviso_resultado(v_av, false, null, null, 'rede', false);
  perform pg_temp.chk((select status from public.pedido_avisos where id = v_av) = 'pendente', 'J: falha temporária repete depois');
  perform public.pedido_aviso_resultado(v_av, true, 'template', 'wamid.J1');
  perform pg_temp.chk((select status from public.pedido_avisos where id = v_av) = 'enviado' and exists (select 1 from public.order_events where order_id = v_ord and message like 'Aviso de pronto%enviado%'), 'J: aviso enviado fica no histórico do pedido');
  perform pg_temp.chk(public.pedido_definir_subestatus(v_ord, 'pronto_retirada') ->> 'aviso' = 'ja_enviado', 'J: nunca duas vezes o mesmo aviso');
  -- saída para entrega com rastreio e sem
  insert into public.orders (contact_id, conversation_id, title, stage, payment_status, paid_at, delivery_method)
  values (v_ct, v_cv, 'Entrega', 'producao', 'aprovado', now() - interval '1 day', 'uber') returning id into v_ord2;
  perform pg_temp.chk(public.pedido_definir_subestatus(v_ord2, 'pronto_retirada') ->> 'motivo' = 'entrega_nao_e_retirada', 'J: pedido de entrega não vira "pronto para retirada"');
  perform public.pedido_definir_subestatus(v_ord2, 'saiu_entrega', 'https://rastreio.exemplo/XYZ');
  v_r := public.pedido_avisos_reservar(10, now());
  v_av := (v_r #>> '{itens,0,aviso_id}')::uuid;
  update public.conversations set last_inbound_at = now() - interval '1 hour' where id = v_cv;
  v_m := public.pedido_aviso_montar(v_av, now());
  perform pg_temp.chk(v_m ->> 'texto' like '%saiu para entrega%' and v_m ->> 'texto' like '%https://rastreio.exemplo/XYZ%', 'J: saída para entrega leva o link de rastreio');
  perform public.pedido_aviso_resultado(v_av, true, 'livre', 'wamid.J2');
  insert into public.orders (contact_id, conversation_id, title, stage, payment_status, paid_at, delivery_method)
  values (v_ct, v_cv, 'Bike', 'producao', 'aprovado', now() - interval '1 day', 'retirada') returning id into v_ord2;
  perform public.pedido_definir_subestatus(v_ord2, 'saiu_entrega');
  v_av := (select id from public.pedido_avisos where order_id = v_ord2);
  perform public.pedido_avisos_reservar(10, now());
  v_m := public.pedido_aviso_montar(v_av, now());
  perform pg_temp.chk(v_m ->> 'texto' like '%O entregador já está a caminho%', 'J: entrega sem rastreio avisa que o pedido está a caminho');
  -- não pago e fora da produção
  insert into public.orders (contact_id, conversation_id, title, stage, payment_status) values (v_ct, v_cv, 'Nao pago', 'producao', 'pendente') returning id into v_ord2;
  perform public.pedido_definir_subestatus(v_ord2, 'pronto_retirada');
  v_r := public.pedido_avisos_reservar(10, now());
  perform pg_temp.chk((select status from public.pedido_avisos where order_id = v_ord2) = 'pulado', 'J: pedido não pago nunca recebe aviso');
  insert into public.orders (contact_id, conversation_id, title, stage) values (v_ct, v_cv, 'Novo', 'novo') returning id into v_ord2;
  perform pg_temp.chk(public.pedido_definir_subestatus(v_ord2, 'saiu_entrega') ->> 'motivo' = 'fora_da_producao', 'J: subestatus só vale em Produção');

  -- ===================================================================================================================
  -- K. Painel de pedidos: lista para o fornecedor
  -- ===================================================================================================================
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_r := public.fornecedor_lista_pendente();
  perform pg_temp.chk(jsonb_array_length(v_r -> 'itens') >= 1 and (select bool_and(x ->> 'sku' <> '') from jsonb_array_elements(v_r -> 'itens') x), 'K: lista do fornecedor agrupa SKUs dos pedidos pagos');
  perform pg_temp.chk((select sum((x ->> 'quantidade')::int) from jsonb_array_elements(v_r -> 'itens') x where x ->> 'sku' = 'PFL01') >= 1, 'K: soma as quantidades por SKU');
  perform public.fornecedor_marcar_enviado(array(select (x ->> 'id')::uuid from jsonb_array_elements(v_r -> 'pedidos') x));
  perform pg_temp.chk(jsonb_array_length(public.fornecedor_lista_pendente() -> 'itens') = 0, 'K: depois de marcar como enviado à fábrica a lista zera');
  perform set_config('request.jwt.claim.role', 'service_role', true);

  -- ===================================================================================================================
  -- L. Observabilidade
  -- ===================================================================================================================
  v_r := public.agente_erro_registrar('GBH | WF6 | Follow-ups', 'wf6', 'Gravar no CRM', 'supabase rpc violates check', 'e1');
  perform pg_temp.chk((v_r ->> 'ok')::boolean and exists (select 1 from public.agent_logs where action = 'erro_workflow' and workflow = 'GBH | WF6 | Follow-ups'), 'L: erro do workflow vai para agent_logs');
  perform pg_temp.chk(exists (select 1 from public.alertas where tipo = 'erro_workflow' and gravidade = 'alta'), 'L: erro gera alerta de gravidade alta ao dono');
  perform public.agente_erro_registrar('GBH | WF6 | Follow-ups', 'wf6', 'Gravar no CRM', 'supabase rpc violates check', 'e2');
  perform pg_temp.chk((select count(*) from public.alertas where tipo = 'erro_workflow') = 1, 'L: o mesmo erro não repete alerta em 30 minutos');
  update public.app_settings set value = jsonb_set(value, '{teto_custo_dia_brl}', '0.01') where key = 'observabilidade';
  insert into public.conversations (contact_id) select id from public.contacts limit 1 on conflict do nothing;
  insert into public.agente_execucoes (conversation_id, message_id, status, custo_estimado)
  select cv.id, m.id, 'concluida', 0.50 from public.conversations cv join public.messages m on m.conversation_id = cv.id limit 1;
  if not exists (select 1 from public.agente_execucoes where custo_estimado = 0.50) then
    insert into public.messages (conversation_id, wa_message_id, direction, type, body) select id, 'obs1', 'in', 'text', 'oi' from public.conversations limit 1;
    insert into public.agente_execucoes (conversation_id, message_id, status, custo_estimado) select m.conversation_id, m.id, 'concluida', 0.50 from public.messages m where wa_message_id = 'obs1';
  end if;
  v_r := public.observabilidade_checar();
  perform pg_temp.chk((v_r ->> 'acima')::boolean and exists (select 1 from public.alertas where tipo = 'custo_dia'), 'L: custo do dia acima do teto avisa o dono');
  perform public.observabilidade_checar();
  perform pg_temp.chk((select count(*) from public.alertas where tipo = 'custo_dia') = 1, 'L: alerta de custo uma vez por dia');
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  v_r := public.painel_agente();
  perform pg_temp.chk(v_r ? 'conversas_ia' and v_r ? 'funil' and v_r ? 'custo_templates_mes' and v_r ? 'condicoes' and v_r ? 'margem_liquida_real_pct' and v_r ? 'erros_recentes' and v_r ? 'tempo_resposta_seg' and v_r ? 'custo_por_conversa', 'L: painel do agente devolve todas as métricas');
  perform pg_temp.chk(jsonb_array_length(v_r -> 'erros_recentes') >= 1, 'L: painel mostra erros recentes');
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  begin perform public.followup_reservar('cadencia'); perform pg_temp.chk(false, 'permissão: anon não reserva follow-up'); exception when others then perform pg_temp.chk(true, 'permissão: anon não reserva follow-up'); end;
  begin perform public.painel_agente(); perform pg_temp.chk(false, 'permissão: anon não vê o painel'); exception when others then perform pg_temp.chk(true, 'permissão: anon não vê o painel'); end;
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
