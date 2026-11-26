-- Lote 1 (26/11/2026): blindagem da API do WhatsApp. Roda no banco real como service_role e desfaz tudo ao final.
-- Casos: Rafael Noronha (recusa), trava diária global, opt-out, orcamento_pronto velho, Wesley/Waner (margem),
-- Paulo (pós-pagamento), loop de buscas (Carlos x Alice) e rodada lenta. Fluxos saudáveis também são conferidos.
begin;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $t$
declare
  v_agora timestamptz := '2026-11-27 13:00:00+00';  -- sexta 10h em São Paulo, dentro da janela dos follow-ups
  v_ct uuid; v_cv uuid; v_ct2 uuid; v_cv2 uuid; v_ct3 uuid; v_cv3 uuid; v_o1 uuid; v_o2 uuid; v_o3 uuid;
  v_q1 uuid; v_q2 uuid; v_f2 uuid; v_ex uuid; v_ex2 uuid; v_msg uuid; r jsonb; m jsonb; v_n int; v_st text; v_mot text; v_seg text[];
begin
  -- ============ fixtures ============
  insert into public.contacts (wa_id, name, is_teste) values ('55990' || lpad((random() * 1e8)::int::text, 8, '0'), 'Teste Lote1 A', true) returning id into v_ct;
  insert into public.conversations (contact_id, last_inbound_at) values (v_ct, v_agora - interval '1 hour') returning id into v_cv;
  insert into public.contacts (wa_id, name, is_teste) values ('55991' || lpad((random() * 1e8)::int::text, 8, '0'), 'Teste Lote1 B', true) returning id into v_ct2;
  insert into public.conversations (contact_id, last_inbound_at) values (v_ct2, v_agora - interval '1 hour') returning id into v_cv2;
  insert into public.contacts (wa_id, name, is_teste, marketing_consent, marketing_consent_at, marketing_consent_source) values ('55992' || lpad((random() * 1e8)::int::text, 8, '0'), 'Teste Lote1 C', true, 'opted_out', now(), 'manual') returning id into v_ct3;
  insert into public.conversations (contact_id, last_inbound_at) values (v_ct3, v_agora - interval '1 hour') returning id into v_cv3;

  -- ============ 1) Rafael: "Agora não" + emoji + "Obrigado" cancela Q1/Q2 ============
  -- última proativa (reativação manual) 3 h antes; o cliente respondeu depois dela
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, status, enviado_em, criado_em)
    values (v_ct, v_cv, 'F1', 'lote1:f1:' || v_ct, v_agora - interval '4 hours', 'enviado', v_agora - interval '3 hours', v_agora - interval '5 hours');
  insert into public.messages (conversation_id, wa_message_id, direction, type, body, created_at) values
    (v_cv, 'lote1.' || gen_random_uuid(), 'in', 'text', 'Agora não', v_agora - interval '2 hours'),
    (v_cv, 'lote1.' || gen_random_uuid(), 'in', 'text', '🤍', v_agora - interval '119 minutes'),
    (v_cv, 'lote1.' || gen_random_uuid(), 'in', 'text', 'Muito obrigado! Uma ótima semana!', v_agora - interval '118 minutes');
  update public.conversations set last_inbound_at = v_agora - interval '118 minutes' where id = v_cv;
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, criado_em)
    values (v_ct, v_cv, 'Q1', 'lote1:q1:' || v_ct, v_agora - interval '1 hour', v_agora - interval '90 minutes') returning id into v_q1;
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, criado_em)
    values (v_ct, v_cv, 'Q2', 'lote1:q2:' || v_ct, v_agora - interval '1 hour', v_agora - interval '90 minutes') returning id into v_q2;
  perform public.followup_reservar('cadencia', 500, v_agora);
  select status, motivo into v_st, v_mot from public.followup_fila where id = v_q1;
  if v_st <> 'cancelado' or v_mot <> 'cliente_recusou' then raise exception 'Rafael: Q1 deveria ser cancelado por recusa, veio % / %', v_st, v_mot; end if;
  select status, motivo into v_st, v_mot from public.followup_fila where id = v_q2;
  if v_st <> 'cancelado' or v_mot <> 'cliente_recusou' then raise exception 'Rafael: Q2 deveria ser cancelado por recusa, veio % / %', v_st, v_mot; end if;

  -- cancelamento imediato: chegou "agora nao" (sem acento) com Q1, F2 e PAG pendentes
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para) values (v_ct2, v_cv2, 'Q1', 'lote1:q1:' || v_ct2, v_agora + interval '1 hour') returning id into v_q1;
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para) values (v_ct2, v_cv2, 'F2', 'lote1:f2:' || v_ct2, v_agora + interval '1 hour') returning id into v_f2;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body, created_at) values (v_cv2, 'lote1.' || gen_random_uuid(), 'in', 'text', 'agora nao, obrigado', v_agora);
  select count(*) into v_n from public.followup_fila where id in (v_q1, v_f2) and status = 'cancelado' and motivo = 'cliente_recusou';
  if v_n <> 2 then raise exception 'recusa imediata deveria cancelar Q1 e F2 na hora (cancelou %)', v_n; end if;
  -- fluxo saudável: mensagem normal não cancela
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para) values (v_ct2, v_cv2, 'Q1', 'lote1:q1b:' || v_ct2, v_agora + interval '1 hour') returning id into v_q1;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body, created_at) values (v_cv2, 'lote1.' || gen_random_uuid(), 'in', 'text', 'Quero 1000 cartões, qual o valor?', v_agora);
  if (select status from public.followup_fila where id = v_q1) <> 'pendente' then raise exception 'mensagem normal não pode cancelar follow-up'; end if;
  -- todas as variações pedidas
  foreach v_mot in array array['Agora não', 'agora nao', 'Depois eu vejo', 'No momento não', 'no momento nao', 'Por enquanto não', 'por enquanto nao', 'Não quero', 'nao quero mais', 'Não tenho interesse', 'nao tenho interesse'] loop
    if not private.msg_recusa_forte(v_mot) then raise exception 'recusa não reconhecida: %', v_mot; end if;
  end loop;
  foreach v_mot in array array['Quero 500 cartões', 'Pode mandar o link?', 'Ok, vou pagar agora', 'Qual o prazo de entrega?'] loop
    if private.msg_recusa_forte(v_mot) then raise exception 'falso positivo de recusa: %', v_mot; end if;
  end loop;

  -- ============ 2) Trava diária global ============
  -- B já recebeu uma proativa hoje (F1 enviado às 8h): Q1 vira trava_diaria, F2 é adiado para amanhã
  delete from public.followup_fila where contact_id = v_ct2;
  delete from public.messages where conversation_id = v_cv2;
  update public.conversations set last_inbound_at = v_agora - interval '2 hours' where id = v_cv2;
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, status, enviado_em, criado_em)
    values (v_ct2, v_cv2, 'F1', 'lote1:b1:' || v_ct2, v_agora - interval '5 hours', 'enviado', v_agora - interval '2 hours', v_agora - interval '6 hours');
  if private.proativas_hoje(v_ct2, v_agora) <> 1 then raise exception 'proativas_hoje deveria ser 1, veio %', private.proativas_hoje(v_ct2, v_agora); end if;
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, criado_em)
    values (v_ct2, v_cv2, 'Q1', 'lote1:b2:' || v_ct2, '2020-01-01', v_agora - interval '90 minutes') returning id into v_q1;
  perform public.followup_reservar('cadencia', 500, v_agora);
  select status, motivo into v_st, v_mot from public.followup_fila where id = v_q1;
  if v_st <> 'cancelado' or v_mot <> 'trava_diaria' then raise exception 'Q1 com proativa hoje deveria bloquear (veio % / %)', v_st, v_mot; end if;
  -- reativação manual no mesmo dia da proativa: bloqueada; e dedupe de 2 pedidos do mesmo contato
  -- a reativação usa o relógio real (now()): grava uma proativa de hoje para o contato B
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, status, enviado_em, criado_em)
    values (v_ct2, v_cv2, 'F3', 'lote1:b3:' || v_ct2, now() - interval '1 hour', 'enviado', now(), now() - interval '2 hours');
  insert into public.orders (contact_id, conversation_id, title, stage) values (v_ct2, v_cv2, 'Pedido lote1 1', 'cotando') returning id into v_o1;
  r := public.reativacao_reservar(v_o1, v_cv2, 'orcamento_pronto', 'template', null);
  if (r ->> 'ok')::boolean or r ->> 'motivo' <> 'trava_diaria' then raise exception 'reativação após proativa do dia deveria cair na trava_diaria: %', r; end if;
  -- contato limpo: 1ª reativação passa; 2ª (outro pedido do mesmo contato) bloqueia
  insert into public.contacts (wa_id, name, is_teste) values ('55993' || lpad((random() * 1e8)::int::text, 8, '0'), 'Teste Lote1 D', true) returning id into v_ct;
  insert into public.conversations (contact_id, last_inbound_at) values (v_ct, v_agora) returning id into v_cv;
  insert into public.orders (contact_id, conversation_id, title, stage) values (v_ct, v_cv, 'Pedido lote1 2', 'aguardando_pagamento') returning id into v_o2;
  insert into public.orders (contact_id, conversation_id, title, stage) values (v_ct, v_cv, 'Pedido lote1 3', 'aguardando_pagamento') returning id into v_o3;
  r := public.reativacao_reservar(v_o2, v_cv, 'pagamento_pendente', 'template', null);
  if not (r ->> 'ok')::boolean then raise exception 'primeira reativação do contato deveria passar: %', r; end if;
  r := public.reativacao_reservar(v_o3, v_cv, 'pagamento_pendente', 'template', null);
  if (r ->> 'ok')::boolean or r ->> 'motivo' <> 'trava_diaria' then raise exception '2º pedido do mesmo contato não pode gerar 2º envio: %', r; end if;
  -- e a reativação conta para a trava dos follow-ups: um F2 do mesmo contato é adiado, não enviado
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, criado_em)
    values (v_ct, v_cv, 'F2', 'lote1:d1:' || v_ct, '2020-01-01', v_agora - interval '90 minutes') returning id into v_f2;
  perform public.followup_reservar('cadencia', 500, now());
  select status into v_st from public.followup_fila where id = v_f2;
  if v_st = 'reservado' then raise exception 'F2 não pode ser reservado no mesmo dia de uma reativação'; end if;

  -- ============ 3) Opt-out: bloqueado em reativação, follow-up e orcamento_pronto ============
  insert into public.orders (contact_id, conversation_id, title, stage) values (v_ct3, v_cv3, 'Pedido lote1 opt-out', 'cotando') returning id into v_o1;
  if not private.contato_bloqueado_proativo(v_ct3) then raise exception 'opted_out deveria ser bloqueado'; end if;
  r := public.reativacao_reservar(v_o1, v_cv3, 'orcamento_pronto', 'template', null);
  if (r ->> 'ok')::boolean or r ->> 'motivo' <> 'opted_out' then raise exception 'reativação opted_out deveria ser bloqueada: %', r; end if;
  r := public.reativacao_reservar(v_o1, v_cv3, 'retomar_orcamento', 'template', null);
  if (r ->> 'ok')::boolean or r ->> 'motivo' <> 'opted_out' then raise exception 'qualquer template opted_out deveria ser bloqueado: %', r; end if;
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, criado_em)
    values (v_ct3, v_cv3, 'PAG_6H', 'lote1:c1:' || v_ct3, '2020-01-01', v_agora - interval '90 minutes') returning id into v_f2;
  perform public.followup_reservar('cadencia', 500, v_agora);
  if (select motivo from public.followup_fila where id = v_f2) <> 'optout' then raise exception 'follow-up de opted_out deveria cancelar por optout'; end if;

  -- ============ 4) orcamento_pronto só até 24 h ============
  select o.id, o.conversation_id into v_o1, v_cv from public.orders o join public.orcamentos oc on oc.order_id = o.id
   join public.contacts c on c.id = o.contact_id
   where o.stage = 'cotando' and o.conversation_id is not null and coalesce(oc.pdf_enviado_em, oc.criado_em) < now() - interval '30 hours'
     and not c.optout and c.marketing_consent <> 'opted_out' and private.proativas_hoje(o.contact_id) = 0 limit 1;
  if v_o1 is not null then
    r := public.reativacao_reservar(v_o1, v_cv, 'orcamento_pronto', 'template', null);
    if (r ->> 'ok')::boolean or r ->> 'motivo' <> 'orcamento_pronto_vencido' then raise exception 'orcamento_pronto com orçamento velho deveria ser barrado: %', r; end if;
  end if;

  -- ============ 5) Wesley/Waner: vazamento:margem só em contexto financeiro ============
  select id into v_ex from public.agente_execucoes where coalesce(teste, false) = false order by iniciado_em desc limit 1;
  if v_ex is null then raise exception 'sem execução real para testar a trava de saída'; end if;
  m := public.agente_saida_base_execucao(v_ex, 'Fique atento: a frente tem a margem diferente do verso.');
  if m -> 'motivos' ? 'vazamento:margem' then raise exception 'ficha técnica "margem diferente do verso" não pode ser bloqueada'; end if;
  m := public.agente_saida_base_execucao(v_ex, 'Deixe uma margem de segurança de 3 mm e a margem de corte livre.');
  if m -> 'motivos' ? 'vazamento:margem' then raise exception 'margem de segurança/corte não pode ser bloqueada'; end if;
  foreach v_mot in array array['Nossa margem de lucro é de 65 reais.', 'A nossa margem é pequena nesse item.', 'Meu lucro mínimo por pedido é 65.', 'A margem líquida desse pedido é 40%.'] loop
    m := public.agente_saida_base_execucao(v_ex, v_mot);
    if not (m -> 'motivos' ? 'vazamento:margem') then raise exception 'margem financeira deveria ser bloqueada: %', v_mot; end if;
  end loop;
  -- o bloqueio grava o rascunho e o motivo em agent_logs
  m := public.agente_saida_segura(v_ex, 'Nossa margem de lucro é de 65 reais.');
  if (m ->> 'ok')::boolean then raise exception 'saída com margem de lucro deveria ser bloqueada'; end if;
  select count(*) into v_n from public.agent_logs l where l.action = 'saida_rascunho_bloqueado' and l.detail ->> 'rascunho' = 'Nossa margem de lucro é de 65 reais.' and l.detail -> 'motivos' ? 'vazamento:margem' and l.created_at > now() - interval '1 minute';
  if v_n < 1 then raise exception 'rascunho bloqueado não foi gravado em agent_logs'; end if;
  -- fluxo saudável continua passando
  m := public.agente_saida_segura(v_ex, 'Oi! Qual quantidade você precisa?');
  if not (m ->> 'ok')::boolean then raise exception 'mensagem saudável não pode ser bloqueada: %', m; end if;

  -- ============ 6) Paulo: pedido pago ativo ============
  insert into public.contacts (wa_id, name, is_teste) values ('55994' || lpad((random() * 1e8)::int::text, 8, '0'), 'Teste Lote1 Paulo', true) returning id into v_ct;
  insert into public.conversations (contact_id, last_inbound_at) values (v_ct, v_agora) returning id into v_cv;
  insert into public.orders (contact_id, conversation_id, title, stage, payment_status) values (v_ct, v_cv, 'Pedido pago lote1', 'producao', 'aprovado');
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv, 'lote1.' || gen_random_uuid(), 'in', 'text', 'Posso mudar a cor?') returning id into v_msg;
  insert into public.agente_execucoes (conversation_id, contact_id, message_id, status, teste) values (v_cv, v_ct, v_msg, 'rodando', true) returning id into v_ex2;
  foreach v_mot in array array[
    'Já anotei aqui para priorizarmos a saída depois das 17h.',
    'Já estou organizando o envio das suas carteirinhas.',
    'Vamos priorizar a sua entrega, pode ficar tranquilo.',
    'Confirmei com a produção para saírem sem furo.',
    'Já alterei a cor do texto na arte.',
    'Já troquei o logo e ajustei o endereço de impressão.'] loop
    if not (private.saida_travas_extra(v_ex2, v_mot) @> array['promessa:alteracao_pos_pagamento']) then raise exception 'pós-pagamento deveria bloquear: %', v_mot; end if;
  end loop;
  foreach v_mot in array array[
    'Vou verificar com o responsável se ainda dá tempo.',
    'Vou verificar com o responsável se ainda é possível alterar a cor.',
    'Seu pedido já entrou na fila e te aviso quando estiver pronto.',
    'Assim que sair pra entrega eu te mando o link por aqui.'] loop
    if private.saida_travas_extra(v_ex2, v_mot) @> array['promessa:alteracao_pos_pagamento'] then raise exception 'pós-pagamento não deveria bloquear: %', v_mot; end if;
  end loop;
  -- sem pedido pago, a mesma frase é normal de venda
  if private.saida_travas_extra(v_ex, 'Já estou organizando o orçamento do seu pedido.') @> array['promessa:alteracao_pos_pagamento'] and not exists (
       select 1 from public.orders o join public.agente_execucoes e on e.contact_id = o.contact_id where e.id = v_ex and (o.payment_status = 'aprovado' or o.payment_manual) and coalesce(o.stage, '') not in ('entregue', 'perdido', 'cancelado')) then
    raise exception 'sem pedido pago a trava pós-pagamento não pode agir';
  end if;

  -- ============ 7) Loop de buscas (Carlos) sem atrapalhar lista grande (Alice) ============
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv, 'lote1.' || gen_random_uuid(), 'in', 'text', 'Lista grande') returning id into v_msg;
  insert into public.agente_execucoes (conversation_id, contact_id, message_id, status, teste) values (v_cv, v_ct, v_msg, 'rodando', true) returning id into v_ex2;
  -- 3 buscas idênticas passam, a 4ª é barrada
  for v_n in 1 .. 3 loop
    r := public.agente_tool_inicio(p_execucao := v_ex2, p_ferramenta := 'buscar_produto', p_args := '{"termo":"Cartão de visita verniz localizado","quantidade":"1000"}'::jsonb);
    if not (r ->> 'permitido')::boolean then raise exception 'busca idêntica % deveria passar', v_n; end if;
    perform public.agente_tool_fim(v_ex2, 'buscar_produto', 100, true, array['X' || v_n || 'A'], '{}', 'opcoes');
  end loop;
  r := public.agente_tool_inicio(p_execucao := v_ex2, p_ferramenta := 'buscar_produto', p_args := '{"termo":"cartao de visita  verniz localizado!","quantidade":"1000"}'::jsonb);
  if (r ->> 'permitido')::boolean or r ->> 'motivo' <> 'busca_repetida' then raise exception '4ª busca idêntica deveria ser barrada: %', r; end if;
  -- 3 buscas seguidas vazias barram a próxima
  insert into public.agente_execucoes (conversation_id, contact_id, message_id, status, teste) values (v_cv, v_ct, (select id from public.messages where conversation_id = v_cv order by created_at desc limit 1), 'rodando', true) returning id into v_ex2;
  for v_n in 1 .. 3 loop
    r := public.agente_tool_inicio(p_execucao := v_ex2, p_ferramenta := 'buscar_produto', p_args := jsonb_build_object('termo', 'produto inexistente ' || v_n * 7, 'quantidade', '10'));
    if not (r ->> 'permitido')::boolean then raise exception 'busca vazia % deveria passar', v_n; end if;
    perform public.agente_tool_fim(v_ex2, 'buscar_produto', 100, true, '{}', '{}', 'opcoes');
  end loop;
  r := public.agente_tool_inicio(p_execucao := v_ex2, p_ferramenta := 'buscar_produto', p_args := '{"termo":"outra coisa qualquer","quantidade":"10"}'::jsonb);
  if (r ->> 'permitido')::boolean or r ->> 'motivo' <> 'buscas_sem_retorno' then raise exception '4ª busca vazia seguida deveria ser barrada: %', r; end if;
  -- buscas diferentes COM resultado: lista grande (até o teto global) passa inteira
  insert into public.agente_execucoes (conversation_id, contact_id, message_id, status, teste) values (v_cv, v_ct, (select id from public.messages where conversation_id = v_cv order by created_at desc limit 1), 'rodando', true) returning id into v_ex2;
  foreach v_mot in array array['cartão de visita','adesivo redondo','panfleto a5','banner lona','caneca branca','camiseta algodão','cardápio wire-o','plaquinha pvc','crachá pvc','cordão','sacola kraft','imã de geladeira','calendário de mesa','bloco de notas','pasta com bolso'] loop
    r := public.agente_tool_inicio(p_execucao := v_ex2, p_ferramenta := 'buscar_produto', p_args := jsonb_build_object('termo', v_mot, 'quantidade', '100'));
    if not (r ->> 'permitido')::boolean then raise exception 'lista grande (Alice) não pode ser barrada: % -> %', v_mot, r; end if;
    perform public.agente_tool_fim(v_ex2, 'buscar_produto', 100, true, array['S' || v_mot], '{}', 'opcoes');
  end loop;
  -- 5 buscas quase iguais (Carlos) barram a 6ª
  insert into public.agente_execucoes (conversation_id, contact_id, message_id, status, teste) values (v_cv, v_ct, (select id from public.messages where conversation_id = v_cv order by created_at desc limit 1), 'rodando', true) returning id into v_ex2;
  foreach v_mot in array array['cartão visita verniz localizado frente verso','cartão visita verniz localizado frente e verso','cartao de visita verniz localizado 4x4','cartão verniz localizado frente verso 1000','cartão de visita verniz localizado fosco'] loop
    r := public.agente_tool_inicio(p_execucao := v_ex2, p_ferramenta := 'buscar_produto', p_args := jsonb_build_object('termo', v_mot, 'quantidade', '1000'));
    if not (r ->> 'permitido')::boolean then raise exception 'busca parecida deveria passar até a 5ª: % -> %', v_mot, r; end if;
    perform public.agente_tool_fim(v_ex2, 'buscar_produto', 100, true, array['Z' || length(v_mot)], '{}', 'opcoes');
  end loop;
  r := public.agente_tool_inicio(p_execucao := v_ex2, p_ferramenta := 'buscar_produto', p_args := '{"termo":"cartão de visita verniz localizado frente e verso 4x4","quantidade":"1000"}'::jsonb);
  if (r ->> 'permitido')::boolean or r ->> 'motivo' <> 'busca_sem_progresso' then raise exception '6ª busca quase igual deveria ser barrada: %', r; end if;
  -- chamada com 2 nomes (p_execucao, p_ferramenta), como o despachante fazia antes de enviar p_args, continua valendo
  insert into public.agente_execucoes (conversation_id, contact_id, message_id, status, teste) values (v_cv, v_ct, (select id from public.messages where conversation_id = v_cv order by created_at desc limit 1), 'rodando', true) returning id into v_ex2;
  if not (public.agente_tool_inicio(p_execucao := v_ex2, p_ferramenta := 'verificar_frete') ->> 'permitido')::boolean then raise exception 'chamada com 2 argumentos deveria continuar funcionando'; end if;

  -- ============ 8) Rodada acima de 90 s ============
  insert into public.agente_execucoes (conversation_id, contact_id, message_id, status, teste, iniciado_em)
    values (v_cv, v_ct, (select id from public.messages where conversation_id = v_cv order by created_at desc limit 1), 'rodando', false, now() - interval '100 seconds') returning id into v_ex2;
  perform public.agente_finalizar(v_ex2, 'concluida', null);
  select count(*) into v_n from public.alertas where chave = 'agente_lento:' || v_ex2;
  if v_n <> 1 then raise exception 'rodada de 100 s deveria gerar 1 alerta agente_lento (gerou %)', v_n; end if;
  insert into public.agente_execucoes (conversation_id, contact_id, message_id, status, teste, iniciado_em)
    values (v_cv, v_ct, (select id from public.messages where conversation_id = v_cv order by created_at desc limit 1), 'rodando', false, now() - interval '400 seconds') returning id into v_ex2;
  perform private.agente_vigia_rodadas();
  select status, motivo into v_st, v_mot from public.agente_execucoes where id = v_ex2;
  if v_st <> 'erro' or v_mot <> 'timeout_vigia' then raise exception 'rodada parada há 400 s deveria ser destravada (veio % / %)', v_st, v_mot; end if;
end
$t$;
rollback;
