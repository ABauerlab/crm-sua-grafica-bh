-- Etapa 6: alertas, push, pós-pagamento (WF5) e chamar_dono real. Desfaz tudo no fim.
begin;
create temp table _t (n int, ok boolean, nome text);
create or replace function pg_temp.chk(p_ok boolean, p_nome text) returns void language plpgsql as $$
begin insert into _t values ((select count(*) + 1 from _t), coalesce(p_ok, false), p_nome); end $$;

do $$
declare
  v_ct uuid; v_cv uuid; v_r jsonb; v_o uuid; v_ev uuid; v_n int; v_a uuid; v_ct2 uuid; v_cv2 uuid; v_pa uuid; v_s1 text; v_s2 text;
begin
  select sku into v_s1 from public.catalogo order by sku limit 1; select sku into v_s2 from public.catalogo order by sku offset 1 limit 1;
  perform set_config('request.jwt.claim.role', 'service_role', true);
  insert into public.contacts (wa_id, name) values ('5531900000077', 'Maria Souza') returning id into v_ct;
  insert into public.conversations (contact_id, last_inbound_at, modo_atendimento) values (v_ct, now(), 'ia') returning id into v_cv;

  -- configuração padrão
  perform pg_temp.chk((private.notif_cfg() #>> '{silencio,inicio}') = '22:00', 'config: padrão de silêncio 22:00');
  perform pg_temp.chk(private.em_silencio('{"silencio":{"ativo":true,"inicio":"22:00","fim":"07:00"}}', '2026-11-02 05:00:00+00'), 'silêncio: 02h em Brasília está dentro (22h a 7h)');
  perform pg_temp.chk(not private.em_silencio('{"silencio":{"ativo":true,"inicio":"22:00","fim":"07:00"}}', '2026-11-02 15:00:00+00'), 'silêncio: 12h em Brasília está fora');
  perform pg_temp.chk(not private.em_silencio('{"silencio":{"ativo":false,"inicio":"22:00","fim":"07:00"}}', '2026-11-02 05:00:00+00'), 'silêncio: desligado nunca silencia');
  perform pg_temp.chk(private.brl_milhar(1234.5) = 'R$ 1.234,50' and private.brl_milhar(89.9) = 'R$ 89,90', 'formato: moeda brasileira');

  -- chamar_dono real: alta = pendente nos dois canais; mesma conversa em 30 min não repete; baixa fica agrupada
  v_r := public.agente_chamar_dono(v_cv, 'Cliente reclamou do prazo', 'alta');
  perform pg_temp.chk((v_r ->> 'ok')::boolean and v_r ->> 'status_whatsapp' = 'pendente' and v_r ->> 'status_push' = 'pendente', 'chamar_dono: alta sai pelos dois canais');
  perform pg_temp.chk((public.agente_chamar_dono(v_cv, 'Cliente reclamou do prazo', 'alta') ->> 'ja_alertado')::boolean, 'chamar_dono: mesmo alerta em 30 min não repete');
  perform pg_temp.chk((select dados ->> 'url' like '%/inbox/' || v_cv::text from public.alertas where id = (v_r ->> 'alerta_id')::uuid), 'alerta: o toque abre a conversa');
  v_r := public.agente_chamar_dono(v_cv, 'Cliente perguntou de brinde', 'baixa');
  perform pg_temp.chk(v_r ->> 'status_whatsapp' = 'agrupado' and v_r ->> 'status_push' = 'agrupado', 'chamar_dono: baixa fica agrupada para o resumo');

  -- dispatcher: fila e resultado por canal
  v_r := public.alertas_proximos(10);
  perform pg_temp.chk(jsonb_array_length(v_r) = 1 and (v_r -> 0 ->> 'enviar_push')::boolean and (v_r -> 0 ->> 'enviar_whatsapp')::boolean, 'fila: só a alta e nos dois canais');
  v_a := (v_r -> 0 ->> 'id')::uuid;
  perform public.alerta_resultado(v_a, 'push', 'enviado');
  v_r := public.alerta_resultado(v_a, 'whatsapp', 'falhou', 'erro 131026');
  perform pg_temp.chk(v_r ->> 'status' = 'pendente', 'resultado: falha de um canal tenta de novo');
  update public.alertas set ultima_tentativa_em = now() - interval '1 hour' where id = v_a;
  perform public.alerta_resultado(v_a, 'whatsapp', 'falhou', 'erro 131026');
  update public.alertas set ultima_tentativa_em = now() - interval '1 hour' where id = v_a;
  v_r := public.alerta_resultado(v_a, 'whatsapp', 'falhou', 'erro 131026');
  perform pg_temp.chk(v_r ->> 'status' = 'falhou' and v_r -> 'aviso_outro_canal' ->> 'ok' = 'true', 'resultado: 3 falhas esgotam o canal e avisam pelo outro');
  perform pg_temp.chk((select canais = array['push'] from public.alertas where chave = 'canal_falhou:' || v_a::text || ':whatsapp'), 'resultado: o aviso de falha vai só pelo canal que funciona');
  perform pg_temp.chk((select status_push from public.alertas where id = v_a) = 'enviado', 'resultado: canal que enviou fica enviado');

  -- resumo: junta as baixas e marca como resumidas
  v_r := public.alertas_resumo_montar();
  perform pg_temp.chk((v_r ->> 'criado')::boolean, 'resumo: cria um alerta com as gravidades baixas');
  perform pg_temp.chk((select count(*) from public.alertas where status_whatsapp = 'resumido') = 1, 'resumo: o aviso de baixa gravidade foi resumido');
  perform pg_temp.chk(not (public.alertas_resumo_montar() ->> 'criado')::boolean, 'resumo: não repete antes de 2 horas');

  -- pós-pagamento (WF5)
  insert into public.orders (contact_id, conversation_id, title, payment_method, due_date) values (v_ct, v_cv, 'Cartões', 'pix', current_date + 3) returning id into v_o;
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) values (v_o, v_s1, 'Cartão de visita 500un', 1, 40, 120);
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price, fora_catalogo) values (v_o, null, 'Item manual', 1, 10, 30, true);
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para) values (v_ct, v_cv, 'F2', 'teste-f2', now() + interval '2 hours');
  perform pg_temp.chk(private.confirmar_pagamento(v_o, 'manual', null, null, now(), null), 'pagamento: confirmação manual passa pelo mesmo caminho');
  select id into v_ev from public.eventos_pagamento where order_id = v_o and tipo = 'pagamento_confirmado';
  perform pg_temp.chk(v_ev is not null, 'evento: pagamento_confirmado gravado');
  perform pg_temp.chk(jsonb_array_length(public.pagamento_pos_pendentes()) = 1, 'fila WF5: evento pendente aparece');
  v_r := public.pagamento_pos_processar(v_ev);
  perform pg_temp.chk((v_r ->> 'ok')::boolean and (v_r ->> 'followups_cancelados')::int = 1, 'WF5: cancela follow-ups pendentes');
  perform pg_temp.chk((select modo_atendimento = 'humano' and needs_human from public.conversations where id = v_cv), 'WF5: o agente para (modo humano)');
  perform pg_temp.chk(v_r -> 'problemas' @> '"item_sem_sku"', 'WF5: item sem SKU vira alerta de fora das regras');
  perform pg_temp.chk(exists (select 1 from public.alertas where chave = 'fora_das_regras:' || v_o::text and gravidade = 'alta'), 'WF5: alerta alta de fora das regras, pagamento mantido');
  perform pg_temp.chk((select payment_status from public.orders where id = v_o) = 'aprovado', 'WF5: não desfaz o pagamento');
  perform pg_temp.chk((select dados ->> 'itens' like '%' || v_s1 || '%' and dados ->> 'previsao' ~ '^\d\d/\d\d$' and dados ->> 'url' like '%/kanban?pedido=%' from public.alertas where chave = 'pedido_pago:' || v_o::text), 'WF5: alerta ao dono com itens e SKUs, previsão e link do pedido');
  perform pg_temp.chk((select lucro_liquido_real is not null from public.orders where id = v_o), 'WF5: lucro líquido real gravado');
  perform pg_temp.chk((public.pagamento_pos_processar(v_ev) ->> 'ja_processado')::boolean, 'WF5: idempotente (segunda chamada não repete)');
  perform pg_temp.chk((select count(*) from public.alertas where chave = 'pedido_pago:' || v_o::text) = 1, 'WF5: um só alerta de pedido pago');

  -- mensagem ao cliente: reserva única, 3 tentativas
  v_r := public.pagamento_pos_reservar_msg(v_o);
  perform pg_temp.chk((v_r ->> 'enviar')::boolean and v_r ->> 'nome' = 'Maria' and v_r ->> 'pedido' like 'SG-%', 'cliente: reserva devolve o primeiro nome e o pedido');
  perform pg_temp.chk(not (public.pagamento_pos_reservar_msg(v_o) ->> 'enviar')::boolean, 'cliente: segunda reserva simultânea não envia (sem mensagem dupla)');
  perform public.pagamento_pos_msg_resultado(v_o, 'falhou_temp', 'timeout');
  perform pg_temp.chk((select processado_em is null from public.eventos_pagamento where id = v_ev), 'cliente: falha temporária mantém o evento na fila');
  v_r := public.pagamento_pos_reservar_msg(v_o); perform public.pagamento_pos_msg_resultado(v_o, 'falhou_temp', 'timeout');
  v_r := public.pagamento_pos_reservar_msg(v_o); v_r := public.pagamento_pos_msg_resultado(v_o, 'falhou_temp', 'timeout');
  perform pg_temp.chk(v_r ->> 'msg_status' = 'falhou' and exists (select 1 from public.alertas where chave = 'msg_cliente_falhou:' || v_o::text), 'cliente: 3 falhas avisam o dono');
  perform pg_temp.chk((select processado_em is not null from public.eventos_pagamento where id = v_ev), 'cliente: depois da 3ª falha o evento é concluído');

  -- sucesso na primeira tentativa em outro pedido
  insert into public.orders (contact_id, conversation_id, title, payment_method) values (v_ct, v_cv, 'Panfletos', 'cartao_credito') returning id into v_o;
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) values (v_o, v_s2, 'Panfleto', 1, 20, 150);
  perform private.confirmar_pagamento(v_o, 'manual', null, null, now(), null);
  select id into v_ev from public.eventos_pagamento where order_id = v_o and tipo = 'pagamento_confirmado';
  perform public.pagamento_pos_processar(v_ev);
  perform public.pagamento_pos_reservar_msg(v_o);
  perform public.pagamento_pos_msg_resultado(v_o, 'enviado');
  perform pg_temp.chk((select processado_em is not null from public.eventos_pagamento where id = v_ev) and (select msg_status = 'enviado' from public.pagamento_pos where order_id = v_o), 'cliente: enviado conclui o evento');

  -- pedido de teste não escreve ao cliente
  insert into public.orders (contact_id, conversation_id, title, teste) values (v_ct, v_cv, 'Teste', true) returning id into v_o;
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) values (v_o, v_s1, 'x', 1, 1, 50);
  perform private.confirmar_pagamento(v_o, 'manual', null, null, now(), null);
  select id into v_ev from public.eventos_pagamento where order_id = v_o and tipo = 'pagamento_confirmado';
  perform public.pagamento_pos_processar(v_ev);
  perform pg_temp.chk((select msg_status = 'ignorado_teste' from public.pagamento_pos where order_id = v_o), 'teste: pedido de teste não envia mensagem ao cliente');

  -- estorno ou contestação viram alerta alto sem mexer no pedido
  insert into public.pagamentos_alertas (chave, tipo, order_id, mensagem) values ('t-estorno', 'estorno', v_o, 'Pagamento estornado.') returning id into v_pa;
  perform pg_temp.chk(exists (select 1 from public.alertas where chave = 'pagalerta:' || v_pa::text and gravidade = 'alta' and tipo = 'pagamento_problema'), 'estorno: vira alerta de gravidade alta');
  perform pg_temp.chk((select payment_status from public.orders where id = v_o) = 'aprovado', 'estorno: o pedido não é alterado');

  -- nova mensagem em modo humano
  insert into public.contacts (wa_id, name) values ('5531900000078', 'João') returning id into v_ct2;
  insert into public.conversations (contact_id, modo_atendimento) values (v_ct2, 'humano') returning id into v_cv2;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv2, 'w-h1', 'in', 'text', 'oi');
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv2, 'w-h2', 'in', 'text', 'tem?');
  perform pg_temp.chk((select count(*) from public.alertas where conversation_id = v_cv2 and tipo = 'nova_mensagem_humano') = 1, 'mensagem humana: um aviso por conversa a cada 30 min');
  perform pg_temp.chk((select status_whatsapp = 'desligado' and status_push = 'pendente' from public.alertas where conversation_id = v_cv2 and tipo = 'nova_mensagem_humano'), 'mensagem humana: só push por padrão');
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv, 'w-ia1', 'in', 'text', 'oi');
  perform pg_temp.chk(not exists (select 1 from public.alertas where conversation_id = v_cv and tipo = 'nova_mensagem_humano' and criado_em > now() - interval '1 minute' and false), 'mensagem humana: gatilho não quebra a gravação da mensagem');

  -- silêncio empurra push de baixa prioridade para o resumo e deixa passar o que fura
  update public.app_settings set value = jsonb_set(value, '{silencio}', '{"ativo":true,"inicio":"00:00","fim":"23:59"}') where key = 'notificacoes';
  perform public.alerta_criar('padrao_desconto', 'alta', v_ct2, null, null, 'teste silencio');
  perform public.alerta_criar('pedido_pago', 'alta', v_ct2, null, null, 'teste fura', '{}', 'furar-1');
  v_r := public.alertas_proximos(50);
  perform pg_temp.chk(exists (select 1 from jsonb_array_elements(v_r) e where e ->> 'tipo' = 'pedido_pago' and (e ->> 'enviar_push')::boolean), 'silêncio: pedido pago fura o silêncio');
  perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(v_r) e where e ->> 'tipo' = 'padrao_desconto' and (e ->> 'enviar_push')::boolean), 'silêncio: desconto incomum não faz popup no silêncio');

  -- preferências por tipo
  update public.app_settings set value = jsonb_set(value, '{tipos,pagamento_pendente,push}', 'false') where key = 'notificacoes';
  v_r := public.alerta_criar('pagamento_pendente_demora', 'baixa', v_ct, null, null, 'teste pref');
  perform pg_temp.chk(v_r ->> 'status_push' = 'desligado', 'preferências: tipo desligado não envia push');

  -- o número do dono nunca é atendido pelo agente
  update public.agente_config set ia_ligada = true, atende_24h = true where id = 1;
  update public.app_settings set value = jsonb_set(value, '{enabled}', 'true') where key = 'agent';
  insert into public.contacts (wa_id, name) values ((select whatsapp_dono from public.agente_config where id = 1), 'Dono') returning id into v_ct2;
  insert into public.conversations (contact_id, modo_atendimento) values (v_ct2, 'ia') returning id into v_cv2;
  perform pg_temp.chk(public.agente_bloqueio(v_cv2) = 'numero_do_dono', 'agente: não responde o número do dono');

  -- varredura
  perform pg_temp.chk((public.alertas_varredura() ->> 'ok')::boolean, 'varredura: roda sem erro');
end $$;

-- permissões: só a service role; usuário logado e anon não executam as funções de envio
do $$
declare v_auth boolean := false; v_anon boolean := false;
begin
  set local role authenticated;
  begin perform public.alertas_proximos(1); v_auth := true; exception when others then v_auth := false; end;
  reset role;
  set local role anon;
  begin perform public.alerta_criar('x', 'alta', null, null, null, 'x'); v_anon := true; exception when others then v_anon := false; end;
  reset role;
  perform pg_temp.chk(not v_auth, 'permissão: usuário logado não executa alertas_proximos');
  perform pg_temp.chk(not v_anon, 'permissão: anon não cria alerta');
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
