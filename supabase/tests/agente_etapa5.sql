-- Etapa 5: testes das funções do agente (WF1 e WF2). Desfaz tudo no fim.
-- Sucesso aparece como "OK: N testes passaram"; falha lista os casos.
begin;
create temp table _t (n int, ok boolean, nome text);
create or replace function pg_temp.chk(p_ok boolean, p_nome text) returns void language plpgsql as $$
begin insert into _t values ((select count(*) + 1 from _t), coalesce(p_ok, false), p_nome); end $$;

do $$
declare
  v_ct uuid; v_cv uuid; v_m1 uuid; v_m2 uuid; v_m3 uuid; v_r jsonb; v_ex uuid; v_o jsonb; v_ct2 uuid; v_cv2 uuid; v_ms uuid;
  v_caso uuid; v_p jsonb; v_ord uuid; v_n int;
begin
  perform set_config('request.jwt.claim.role', 'service_role', true);
  update public.agente_config set ia_ligada = true, atende_24h = true where id = 1;
  update public.app_settings set value = jsonb_set(value, '{enabled}', 'true') where key = 'agent';

  insert into public.contacts (wa_id, name, first_referral) values ('5531900000001', 'carlos souza silva', '{"source_id":"AD-1","headline":"Cartão de visita","body":"Peça já"}') returning id into v_ct;
  insert into public.conversations (contact_id, last_referral) values (v_ct, '{"source_id":"AD-1","headline":"Cartão de visita","body":"Peça já"}') returning id into v_cv;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body, created_at) values (v_cv, 't1', 'in', 'text', 'oi', now() - interval '20 seconds') returning id into v_m1;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body, created_at) values (v_cv, 't2', 'in', 'text', 'quero cartão', now() - interval '10 seconds') returning id into v_m2;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body, created_at) values (v_cv, 't3', 'in', 'text', '500 unidades', now()) returning id into v_m3;

  -- WF1: guarda de roteamento
  v_r := public.agente_entrada(v_m1);
  perform pg_temp.chk((v_r ->> 'processar')::boolean, 'entrada: mensagem normal segue');
  perform pg_temp.chk(v_r ->> 'modelo_padrao' = 'gemini-2.5-flash', 'entrada: devolve o modelo padrão');
  perform pg_temp.chk((select ai_handled and modo_atendimento = 'ia' from public.conversations where id = v_cv), 'entrada: conversa nova (nasce humana) é assumida pela IA no primeiro contato');
  perform pg_temp.chk((public.agente_entrada(v_m1) ->> 'motivo') = 'duplicada', 'entrada: mesma mensagem duas vezes é duplicada');
  perform pg_temp.chk((public.agente_entrada(gen_random_uuid()) ->> 'motivo') = 'mensagem_inexistente', 'entrada: mensagem inexistente');

  -- debounce: só a última do grupo segue
  perform public.agente_entrada(v_m2); perform public.agente_entrada(v_m3);
  perform pg_temp.chk(not (public.agente_debounce(v_m1) ->> 'ultima')::boolean, 'debounce: primeira mensagem do grupo não segue');
  perform pg_temp.chk(not (public.agente_debounce(v_m2) ->> 'ultima')::boolean, 'debounce: segunda mensagem do grupo não segue');
  v_r := public.agente_debounce(v_m3);
  perform pg_temp.chk((v_r ->> 'ultima')::boolean and jsonb_array_length(v_r -> 'mensagens') = 3, 'debounce: a última junta as 3 mensagens');
  perform pg_temp.chk((select status from public.agente_execucoes where message_id = v_m1) = 'agrupada', 'debounce: execução anterior fica agrupada');

  -- trava por conversa
  v_r := public.agente_iniciar(v_m3);
  perform pg_temp.chk((v_r ->> 'ok')::boolean, 'iniciar: primeira rodada começa');
  v_ex := (v_r ->> 'execucao_id')::uuid;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv, 't4', 'in', 'text', 'e aí?') returning id into v_ms;
  perform public.agente_entrada(v_ms);
  perform pg_temp.chk((public.agente_iniciar(v_ms) ->> 'motivo') = 'ocupado', 'iniciar: segunda rodada na mesma conversa espera (ocupado)');
  update public.agente_execucoes set status = 'concluida' where id = v_ex;
  perform pg_temp.chk((public.agente_iniciar(v_ms) ->> 'ok')::boolean, 'iniciar: depois de concluir, libera');
  update public.agente_execucoes set status = 'concluida' where message_id = v_ms;

  -- contexto
  v_r := public.agente_contexto(v_cv);
  perform pg_temp.chk(v_r -> 'contato' ->> 'primeiro_nome' = 'Carlos', 'contexto: primeiro nome');
  perform pg_temp.chk(v_r ->> 'agora' ~ '^(domingo|segunda-feira|terça-feira|quarta-feira|quinta-feira|sexta-feira|sábado), \d\d/\d\d/\d{4} às \d\d:\d\d$', 'contexto: data e hora em português');
  perform pg_temp.chk(v_r -> 'anuncio' ->> 'titulo' = 'Cartão de visita', 'contexto: origem do anúncio');
  perform pg_temp.chk((v_r ->> 'primeiro_contato')::boolean, 'contexto: primeiro contato');
  perform pg_temp.chk(jsonb_array_length(v_r -> 'ultimas_mensagens') = 0, 'contexto: mensagens pendentes não entram no histórico (vão como entrada)');
  perform pg_temp.chk(v_r::text !~* '(custo|piso|margem|fornecedor|lucro|Rio de Janeiro)', 'contexto: sem custo, piso, margem, fornecedor nem endereço');
  for v_n in 1 .. 9 loop
    insert into public.messages (conversation_id, wa_message_id, direction, type, body, created_at)
    values (v_cv, 'h' || v_n, case when v_n % 2 = 0 then 'in' else 'out' end, 'text', 'msg ' || v_n, now() - interval '5 minutes' + make_interval(secs => v_n));
  end loop;
  v_r := public.agente_contexto(v_cv);
  perform pg_temp.chk(jsonb_array_length(v_r -> 'ultimas_mensagens') = 6, 'contexto: no máximo as últimas 6 mensagens');
  perform pg_temp.chk(not (v_r ->> 'primeiro_contato')::boolean, 'contexto: já houve resposta');

  -- saída segura
  update public.agente_execucoes set skus_vistos = array['CFV02'], valores_vistos = array[189.90, 35.50] where id = v_ex;
  v_r := public.agente_saida_segura(v_ex, 'Fica **R$ 189,90** — pronto na quinta, dia 6.');
  perform pg_temp.chk((v_r ->> 'ok')::boolean and v_r ->> 'texto' = 'Fica R$ 189,90, pronto na quinta, dia 6.', 'saída: remove travessão e markdown e aceita valor da ferramenta');
  perform pg_temp.chk(not (public.agente_saida_segura(v_ex, 'Fica R$ 151,00 certinho') ->> 'ok')::boolean, 'saída: valor que nenhuma ferramenta devolveu é bloqueado');
  perform pg_temp.chk((public.agente_saida_segura(v_ex, 'A arte sai por R$ 39,90') ->> 'ok')::boolean, 'saída: valor fixo de arte é aceito');
  perform pg_temp.chk((public.agente_saida_segura(v_ex, 'Fica R$ 1.189,90 no total') ->> 'ok')::boolean = false, 'saída: milhar com ponto é interpretado (1.189,90 não foi devolvido)');
  perform pg_temp.chk(not (public.agente_saida_segura(v_ex, 'O custo do cartão é baixo') ->> 'ok')::boolean, 'saída: bloqueia a palavra custo');
  perform pg_temp.chk((public.agente_saida_segura(v_ex, 'Ótimo custo-benefício') ->> 'ok')::boolean, 'saída: custo-benefício não é vazamento');
  perform pg_temp.chk(not (public.agente_saida_segura(v_ex, 'Use o código CFV02') ->> 'ok')::boolean, 'saída: bloqueia SKU devolvido pela ferramenta');
  perform pg_temp.chk(not (public.agente_saida_segura(v_ex, 'Nosso fornecedor entrega rápido') ->> 'ok')::boolean, 'saída: bloqueia fornecedor');
  perform pg_temp.chk(not (public.agente_saida_segura(v_ex, 'Vai de bike até você') ->> 'ok')::boolean, 'saída: bloqueia bicicleta');
  perform pg_temp.chk(not (public.agente_saida_segura(v_ex, 'Fica na Rua Rio de Janeiro, 462, 22º andar') ->> 'ok')::boolean, 'saída: bloqueia endereço de retirada');
  perform pg_temp.chk(not (public.agente_saida_segura(v_ex, 'Passa na sala 2217') ->> 'ok')::boolean, 'saída: bloqueia sala do escritório');
  perform pg_temp.chk(not (public.agente_saida_segura(v_ex, '   ') ->> 'ok')::boolean, 'saída: texto vazio é bloqueado');
  perform pg_temp.chk(public.agente_saida_segura(v_ex, E'Oi\n\n\n\n- um\n- dois') ->> 'texto' = E'Oi\num\ndois', 'saída: tira marcadores e linhas em branco demais');

  -- detector de loop e log com custo
  perform pg_temp.chk((public.agente_tool_inicio(v_ex, 'buscar_produto') ->> 'permitido')::boolean, 'loop: 1a chamada passa');
  perform public.agente_tool_inicio(v_ex, 'buscar_produto'); perform public.agente_tool_inicio(v_ex, 'buscar_produto');
  v_r := public.agente_tool_inicio(v_ex, 'buscar_produto');
  perform pg_temp.chk(not (v_r ->> 'permitido')::boolean and v_r ->> 'motivo' = 'loop', 'loop: 4a chamada da mesma ferramenta encerra a rodada');
  perform pg_temp.chk((public.agente_tool_inicio(v_ex, 'verificar_frete') ->> 'permitido')::boolean, 'loop: outra ferramenta ainda passa');
  perform public.agente_tool_fim(v_ex, 'buscar_produto', 120, true, array['CFV02', 'CFV03'], array[189.90, 75.99], 'ok');
  perform pg_temp.chk((select 'CFV03' = any (skus_vistos) and 75.99 = any (valores_vistos) from public.agente_execucoes where id = v_ex), 'tool_fim: guarda SKUs e valores devolvidos');
  perform public.agente_log(v_ex, 'resposta', null, 'gemini-2.5-flash', 2000, 300, 900, '{}', 'ok');
  perform pg_temp.chk((select round(custo_estimado::numeric, 4) from public.agente_execucoes where id = v_ex) = round((2000 * 1.65 + 300 * 13.75) / 1000000, 4), 'log: custo estimado por tokens do modelo');
  perform pg_temp.chk((select count(*) from public.agent_logs where conversation_id = v_cv and action = 'resposta' and tokens_entrada = 2000) = 1, 'log: linha em agent_logs com tokens');

  -- teto de tokens
  update public.parametros_comerciais set tokens_max_conversa = 1000 where id = 1;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv, 'tk1', 'in', 'text', 'oi de novo') returning id into v_ms;
  v_r := public.agente_entrada(v_ms);
  perform pg_temp.chk(v_r ->> 'motivo' = 'teto_conversa' and not (v_r ->> 'processar')::boolean, 'teto: conversa acima do limite de tokens para de chamar o modelo');
  perform pg_temp.chk(exists (select 1 from public.alertas where conversation_id = v_cv and tipo = 'teto_tokens' and gravidade = 'alta'), 'teto: gera alerta ao dono');
  update public.parametros_comerciais set tokens_max_conversa = 40000 where id = 1;

  -- ignorar: pausa, humano, optout, tipo, pedido pago
  update public.app_settings set value = jsonb_set(value, '{enabled}', 'false') where key = 'agent';
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv, 'p1', 'in', 'text', 'oi') returning id into v_ms;
  perform pg_temp.chk(public.agente_entrada(v_ms) ->> 'motivo' = 'ia_pausada', 'ignora: IA global pausada (botão do topo)');
  update public.app_settings set value = jsonb_set(value, '{enabled}', 'true') where key = 'agent';
  update public.agente_config set ia_ligada = false where id = 1;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv, 'p2', 'in', 'text', 'oi') returning id into v_ms;
  perform pg_temp.chk(public.agente_entrada(v_ms) ->> 'motivo' = 'ia_pausada', 'ignora: IA desligada na configuração do agente');
  update public.agente_config set ia_ligada = true where id = 1;

  insert into public.contacts (wa_id, name) values ('5531900000002', 'Ana') returning id into v_ct2;
  insert into public.conversations (contact_id) values (v_ct2) returning id into v_cv2;
  update public.conversations set modo_atendimento = 'humano', ai_handled = false, attendant_changed_at = now() where id = v_cv2;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv2, 'hum1', 'in', 'text', 'oi') returning id into v_ms;
  perform pg_temp.chk(public.agente_entrada(v_ms) ->> 'motivo' = 'modo_humano', 'ignora: modo humano');
  update public.conversations set modo_atendimento = 'ia', ai_handled = true where id = v_cv2;
  update public.contacts set marketing_consent = 'opted_out', marketing_consent_at = now() where id = v_ct2;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv2, 'o1', 'in', 'text', 'oi') returning id into v_ms;
  perform pg_temp.chk(public.agente_entrada(v_ms) ->> 'motivo' = 'optout', 'ignora: contato em optout');
  update public.contacts set marketing_consent = 'none', marketing_consent_at = null where id = v_ct2;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv2, 'f1', 'in', 'other', '[figurinha recebida]') returning id into v_ms;
  perform pg_temp.chk(public.agente_entrada(v_ms) ->> 'motivo' = 'tipo_ignorado', 'ignora: figurinha');
  insert into public.orders (contact_id, conversation_id, title) values (v_ct2, v_cv2, 'Pedido') returning id into v_ord;
  update public.orders set payment_status = 'aprovado', stage = 'pago' where id = v_ord;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv2, 'pg1', 'in', 'text', 'já paguei') returning id into v_ms;
  perform pg_temp.chk(public.agente_entrada(v_ms) ->> 'motivo' = 'pedido_pago', 'ignora: pedido já pago (zero chamadas ao modelo)');
  perform pg_temp.chk((public.agente_pode_enviar(v_cv2) ->> 'pode')::boolean = false, 'pode_enviar: pagamento confirmado bloqueia a saída em andamento');
  perform pg_temp.chk((public.agente_pode_enviar(v_cv) ->> 'pode')::boolean, 'pode_enviar: conversa normal pode');

  -- ferramentas simples
  v_r := public.agente_salvar_contato(v_ct, '{"nome":"Carlos Souza","segmento":"barbearia","bairro":"Savassi","cep":"30140-071","interesse":"cartão de visita","quantidade":"1000","tem_arte":"não","campo_estranho":"x"}');
  perform pg_temp.chk((v_r ->> 'ok')::boolean and v_r -> 'salvo' @> '"quantidade"' and not (v_r -> 'salvo' @> '"campo_estranho"'), 'salvar_contato: grava só campos permitidos');
  perform pg_temp.chk((select segment = 'barbearia' and cep = '30140071' and status_lead = 'qualificando' from public.contacts where id = v_ct), 'salvar_contato: segmento, CEP só com dígitos e etapa do lead');
  perform pg_temp.chk((select collected_data ->> 'tem_arte' = 'nao' and (collected_data ->> 'quantidade')::int = 1000 from public.conversations where id = v_cv), 'salvar_contato: dados coletados na conversa');
  perform pg_temp.chk((public.agente_salvar_contato(v_ct, '{"cep":"123","quantidade":"-4"}') -> 'salvo') = '[]'::jsonb, 'salvar_contato: CEP e quantidade inválidos são ignorados');

  v_r := public.agente_chamar_dono(v_cv, 'Cliente pediu camiseta bordada', 'alta');
  perform pg_temp.chk((v_r ->> 'ok')::boolean and exists (select 1 from public.alertas where conversation_id = v_cv and status_whatsapp = 'pendente' and gravidade = 'alta'), 'chamar_dono: grava alerta pendente');
  perform pg_temp.chk((public.agente_chamar_dono(v_cv, 'Cliente pediu camiseta bordada', 'alta') ->> 'ja_alertado')::boolean, 'chamar_dono: mesmo alerta em 30 min não repete');
  perform pg_temp.chk((select needs_human from public.conversations where id = v_cv), 'chamar_dono: gravidade alta marca atenção, sem tirar a IA');
  perform pg_temp.chk((select modo_atendimento = 'ia' from public.conversations where id = v_cv), 'chamar_dono: não interrompe o atendimento');

  -- follow-up depende de orçamento aberto
  perform pg_temp.chk((public.agente_agendar_followup(v_cv, 'orcamento', '2h') ->> 'motivo') = 'sem_orcamento_aberto', 'followup: sem orçamento aberto não agenda');
  perform pg_temp.chk((public.agente_agendar_followup(v_cv, 'orcamento', 'amanha') ->> 'motivo') = 'combinacao_invalida', 'followup: o modelo só escolhe entre opções fixas');
  v_o := public.montar_orcamento(v_ct, '[{"sku":"CFV02","quantidade":1}]', jsonb_build_object('conversation_id', v_cv, 'teste', true, 'bairro', 'Centro', 'arte', 'nenhuma'));
  perform pg_temp.chk(v_o ? 'orcamento_id' or v_o ? 'id' or v_o ? 'numero', 'montar_orcamento responde (base para os próximos testes)');
  v_r := public.agente_agendar_followup(v_cv, 'orcamento', '20h');
  perform pg_temp.chk((v_r ->> 'ok')::boolean and v_r ->> 'regra' = 'F2', 'followup: agenda F2');
  perform pg_temp.chk((public.agente_agendar_followup(v_cv, 'orcamento', '20h') ->> 'ja_agendado')::boolean, 'followup: idempotente');
  perform pg_temp.chk((select extract(hour from agendado_para at time zone 'America/Sao_Paulo') between 8 and 19 from public.followup_fila where conversation_id = v_cv and regra_codigo = 'F2'), 'followup: dentro de 8h e 20h');
  v_r := public.agente_contexto(v_cv);
  perform pg_temp.chk(v_r -> 'orcamento_aberto' ->> 'numero' ~ '^SG-\d{4}$', 'contexto: orçamento aberto com número SG');

  -- transcrição e mídia
  insert into public.messages (conversation_id, wa_message_id, direction, type, body, media_id) values (v_cv, 'a1', 'in', 'audio', '[áudio recebido]', 'm1') returning id into v_ms;
  perform public.agente_gravar_transcricao(v_ms, 'quero mil panfletos');
  perform pg_temp.chk((select body from public.messages where id = v_ms) = '[áudio] quero mil panfletos', 'áudio: transcrição vira o corpo da mensagem');
  insert into public.messages (conversation_id, wa_message_id, direction, type, body, media_id) values (v_cv, 'i1', 'in', 'image', '[imagem recebida]', 'm2') returning id into v_ms;
  perform public.agente_registrar_midia(v_ms); perform public.agente_registrar_midia(v_ms);
  perform pg_temp.chk((select count(*) from public.conversation_notes where conversation_id = v_cv and body like 'Cliente enviou uma imagem%') = 1, 'mídia: nota interna uma vez só');

  -- resumo
  perform pg_temp.chk((public.agente_resumo_precisa(v_cv) ->> 'precisa')::boolean, 'resumo: depois de 8 mensagens novas precisa atualizar');
  perform public.agente_gravar_resumo(v_cv, 'Cliente quer cartão, 1000 unidades, Savassi.');
  perform pg_temp.chk(not (public.agente_resumo_precisa(v_cv) ->> 'precisa')::boolean, 'resumo: gravado, não precisa de novo');

  -- primeiro contato grava a origem do anúncio (só quando ainda não houve resposta)
  insert into public.contacts (wa_id, name, first_referral) values ('5531900000004', 'Dani', '{"source_id":"AD-9","headline":"Banner"}') returning id into v_ct2;
  insert into public.conversations (contact_id) values (v_ct2) returning id into v_cv2;
  v_r := public.agente_primeiro_contato(v_cv2);
  perform pg_temp.chk((v_r ->> 'ok')::boolean and (select collected_data ->> 'origem' = 'anuncio' and collected_data ->> 'anuncio_id' = 'AD-9' from public.conversations where id = v_cv2), 'primeiro contato: grava origem do anúncio na conversa');
  perform pg_temp.chk((select status_lead = 'qualificando' from public.contacts where id = v_ct2), 'primeiro contato: lead passa a qualificando');
  perform pg_temp.chk((public.agente_primeiro_contato(v_cv) ->> 'ja_iniciado')::boolean, 'primeiro contato: depois da primeira resposta não faz nada');

  -- cliente responde um follow-up: IA retoma, lembretes pendentes são cancelados, lead frio volta
  insert into public.contacts (wa_id, name, status_lead) values ('5531900000003', 'Bia', 'frio') returning id into v_ct2;
  insert into public.conversations (contact_id, ai_handled, modo_atendimento, attendant_changed_at, attendant_change_reason)
  values (v_ct2, false, 'humano', now() - interval '3 days', 'Follow-up automático') returning id into v_cv2;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body, template_name, created_at)
  values (v_cv2, 'fu-out', 'out', 'template', 'Seu orçamento vence hoje', 'orcamento_vence_hoje', now() - interval '1 day');
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para) values (v_ct2, v_cv2, 'F3', 'F3:teste-resposta', now() + interval '1 day');
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv2, 'fu-in', 'in', 'text', 'ainda vale?') returning id into v_ms;
  v_r := public.agente_entrada(v_ms);
  perform pg_temp.chk((v_r ->> 'processar')::boolean, 'follow-up: resposta do cliente a um follow-up volta ao atendimento da IA');
  perform pg_temp.chk((select status = 'cancelado' from public.followup_fila where chave = 'F3:teste-resposta'), 'follow-up: lembretes pendentes são cancelados quando o cliente responde');
  perform pg_temp.chk((select status_lead = 'qualificando' from public.contacts where id = v_ct2), 'follow-up: lead frio volta a qualificando');
  -- com pagamento em andamento ou com o dono no comando, não retoma
  update public.conversations set ai_handled = false, modo_atendimento = 'humano', attendant_change_reason = 'Assumido pelo dono' where id = v_cv2;
  insert into public.messages (conversation_id, wa_message_id, direction, type, body) values (v_cv2, 'fu-in2', 'in', 'text', 'oi?') returning id into v_ms;
  perform pg_temp.chk(public.agente_entrada(v_ms) ->> 'motivo' = 'modo_humano', 'follow-up: se o dono assumiu, a resposta não devolve para a IA');

  -- modo de teste: preparar, registrar, avaliar, limpar
  select id into v_caso from public.testes_conversa where nome = 'e5-03-indeciso-preco-g1';
  v_p := public.agente_teste_preparar(v_caso);
  perform pg_temp.chk((v_p ->> 'ok')::boolean and (select tags @> array['teste'] from public.contacts where id = (v_p ->> 'contact_id')::uuid), 'teste: cria contato de teste');
  perform pg_temp.chk(exists (select 1 from public.orcamentos where contact_id = (v_p ->> 'contact_id')::uuid and teste), 'teste: prepara orçamento aberto marcado como teste');
  perform pg_temp.chk((select status = 'enviado' from public.orcamentos where contact_id = (v_p ->> 'contact_id')::uuid and teste), 'teste: orçamento do cenário já está enviado (como depois do PDF)');
  v_r := public.oferecer_condicao_especial((select id from public.orcamentos where contact_id = (v_p ->> 'contact_id')::uuid and teste), 'G1');
  perform pg_temp.chk(v_r ->> 'tipo' <> 'sem_condicao' or v_r ->> 'motivo' is not null, 'cenário G1: a função de condição responde sobre o orçamento enviado (decide sozinha)');
  perform pg_temp.chk(v_r::text !~* '(custo|piso|margem|lucro|fornecedor)', 'cenário G1: a resposta da condição não vaza custo, piso, margem nem lucro');
  perform pg_temp.chk((public.oferecer_condicao_especial((select id from public.orcamentos where contact_id = (v_p ->> 'contact_id')::uuid and teste), 'G1') ->> 'tipo') = 'sem_condicao', 'cenário: uma condição por orçamento, a segunda tentativa não repete');
  v_r := public.agente_entrada((v_p ->> 'ultima_mensagem')::uuid, true);
  perform pg_temp.chk((v_r ->> 'processar')::boolean and (v_r ->> 'teste')::boolean, 'teste: entrada do caso segue em modo de teste');
  perform public.agente_teste_registrar_saida((v_p ->> 'conversation_id')::uuid, 'Consegui uma condição especial até amanhã.');
  v_r := public.agente_teste_avaliar(v_caso);
  perform pg_temp.chk(v_r ->> 'status' = 'falhou' and v_r -> 'falhas' @> '"faltou_ferramenta:oferecer_condicao_especial"', 'teste: avaliação aponta ferramenta obrigatória que faltou');
  perform public.agente_log((select id from public.agente_execucoes where message_id = (v_p ->> 'ultima_mensagem')::uuid), 'ferramenta', 'oferecer_condicao_especial');
  v_r := public.agente_teste_avaliar(v_caso);
  perform pg_temp.chk(v_r ->> 'status' = 'passou', 'teste: avaliação passa quando a ferramenta foi usada e a saída é limpa');
  perform public.agente_teste_registrar_saida((v_p ->> 'conversation_id')::uuid, 'O custo é R$ 12,00 — fica barato');
  v_r := public.agente_teste_avaliar(v_caso);
  perform pg_temp.chk(v_r ->> 'status' = 'falhou' and v_r::text like '%travessao%' and v_r::text like '%saida_insegura%', 'teste: avaliação pega travessão e vazamento');
  v_r := public.agente_teste_limpar(v_caso);
  perform pg_temp.chk((v_r ->> 'ok')::boolean and not exists (select 1 from public.contacts where 'teste' = any (tags)), 'teste: limpa tudo do contato de teste');

  select id into v_caso from public.testes_conversa where nome = 'e5-21-pagamento-confirmado';
  v_p := public.agente_teste_preparar(v_caso);
  perform pg_temp.chk(public.agente_entrada((v_p ->> 'ultima_mensagem')::uuid, true) ->> 'motivo' = 'pedido_pago', 'teste: cenário de pagamento confirmado para o agente');
  perform pg_temp.chk((public.agente_teste_avaliar(v_caso) ->> 'status') = 'passou', 'teste: sem resposta e zero tokens passa');
  perform public.agente_teste_limpar(v_caso);

  select id into v_caso from public.testes_conversa where nome = 'e5-18-falha-de-ferramenta';
  v_p := public.agente_teste_preparar(v_caso);
  v_r := public.agente_entrada((v_p ->> 'ultima_mensagem')::uuid, true);
  perform pg_temp.chk((public.agente_tool_inicio((v_r ->> 'execucao_id')::uuid, 'montar_orcamento') ->> 'simular_falha')::boolean, 'teste: falha de ferramenta simulada');
  perform pg_temp.chk(not (public.agente_tool_inicio((v_r ->> 'execucao_id')::uuid, 'buscar_produto') ->> 'simular_falha')::boolean, 'teste: só a ferramenta escolhida falha');
  perform public.agente_teste_limpar(v_caso);

  select id into v_caso from public.testes_conversa where nome = 'e5-13-fora-do-catalogo';
  v_p := public.agente_teste_preparar(v_caso);
  perform public.agente_teste_registrar_saida((v_p ->> 'conversation_id')::uuid, 'Vou confirmar com a equipe e já te falo.');
  v_r := public.agente_teste_avaliar(v_caso);
  perform pg_temp.chk(v_r -> 'falhas' @> '"faltou_alerta_ao_dono"', 'teste: cenário fora do catálogo exige alerta ao dono');
  perform public.agente_chamar_dono((v_p ->> 'conversation_id')::uuid, 'Pedido fora do catálogo', 'alta');
  perform pg_temp.chk((public.agente_teste_avaliar(v_caso) ->> 'status') = 'passou', 'teste: com alerta ao dono e resposta limpa o cenário passa');
  perform public.agente_teste_limpar(v_caso);

  perform pg_temp.chk((select count(*) from public.testes_conversa where nome like 'e5-%') = 21, 'teste: 21 cenários cadastrados (20 pedidos mais o de pagamento)');
end $$;

-- permissões: service role executa, anon e usuário logado não
do $$
declare v_srv boolean := false; v_anon boolean := false; v_auth boolean := false;
begin
  set local role service_role;
  begin perform public.agente_bloqueio(gen_random_uuid()); v_srv := true; exception when others then v_srv := false; end;
  reset role;
  set local role anon;
  begin perform public.agente_bloqueio(gen_random_uuid()); exception when insufficient_privilege then v_anon := true; end;
  reset role;
  set local role authenticated;
  begin perform public.agente_contexto(gen_random_uuid()); exception when insufficient_privilege then v_auth := true; end;
  reset role;
  perform pg_temp.chk(v_srv, 'permissão: service role executa as funções do agente');
  perform pg_temp.chk(v_anon, 'permissão: anon não executa as funções do agente');
  perform pg_temp.chk(v_auth, 'permissão: usuário logado não executa as funções do agente');
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
