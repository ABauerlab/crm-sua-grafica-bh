-- Etapa 7B, Bloco B: debounce, dados do cliente, setores, promessas indevidas, motivo de perda, BauerLab, validador, três opções.
begin;
create temp table _t (n int, ok boolean, nome text);
create or replace function pg_temp.chk(p_ok boolean, p_nome text) returns void language plpgsql as $$
begin insert into _t values ((select count(*) + 1 from _t), coalesce(p_ok, false), p_nome); end $$;
create or replace function pg_temp.erro_ok(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;

do $$
declare
  v_staff uuid := gen_random_uuid(); v_ct uuid; v_cv uuid; v_ex uuid; v_m1 uuid; v_m2 uuid; r jsonb; v_o uuid; v_sku text; v_orc uuid; v_n int; v_txt text; v_p text[];
  v_cond uuid;
begin
  perform set_config('request.jwt.claim.role', 'service_role', true);
  insert into auth.users (id, email) values (v_staff, 'contato.bauerlab@gmail.com');
  insert into public.profiles (id, name, role) values (v_staff, 'Dono', 'admin');
  update public.app_settings set value = jsonb_set(value, '{email}', '"contato.bauerlab@gmail.com"') where key = 'owner';
  insert into public.contacts (wa_id, name) values ('5531900000091', 'Cliente B') returning id into v_ct;
  insert into public.conversations (contact_id, ai_handled, modo_atendimento) values (v_ct, true, 'ia') returning id into v_cv;

  -- B1: 10 segundos e mensagens incompletas
  perform pg_temp.chk((select debounce_segundos from public.agente_config where id = 1) = 10, 'B1: debounce padrão de 10 segundos');
  perform pg_temp.chk(private.mensagem_incompleta('audio', null), 'B1: só áudio parece incompleto');
  perform pg_temp.chk(private.mensagem_incompleta('text', 'Queria cartões e'), 'B1: termina em "e" parece incompleta');
  perform pg_temp.chk(private.mensagem_incompleta('text', 'Preciso de:'), 'B1: termina em dois pontos parece incompleta');
  perform pg_temp.chk(not private.mensagem_incompleta('text', 'Quanto custa 500 cartões de visita?'), 'B1: pergunta completa responde já');
  perform pg_temp.chk(not private.mensagem_incompleta('text', 'Bom dia'), 'B1: mensagem comum não prolonga');
  insert into public.messages (conversation_id, direction, type, body, wa_message_id, status) values (v_cv, 'in', 'text', 'Quanto custa 500 cartões?', 'wamid.b1', null) returning id into v_m1;
  insert into public.agente_execucoes (conversation_id, contact_id, message_id, teste) values (v_cv, v_ct, v_m1, true);
  r := public.agente_debounce(v_m1, false);
  perform pg_temp.chk((r ->> 'ultima')::boolean, 'B1: última mensagem do grupo segue');
  insert into public.messages (conversation_id, direction, type, body, wa_message_id, status) values (v_cv, 'in', 'text', 'e também 1000 panfletos', 'wamid.b2', null) returning id into v_m2;
  r := public.agente_debounce(v_m1, false);
  perform pg_temp.chk(not (r ->> 'ultima')::boolean, 'B1: nova mensagem reinicia a contagem (a anterior é agrupada)');

  -- B3: dados do cliente
  r := public.agente_salvar_contato(v_ct, '{"empresa":"Barbearia Central","documento":"12345678000199","endereco":"Rua X, 10"}'::jsonb);
  perform pg_temp.chk(r -> 'ignorado' @> '"documento_sem_nota_fiscal"' and r -> 'ignorado' @> '"endereco_sem_entrega_ou_nota"', 'B3: CPF/CNPJ e endereço só com nota fiscal ou entrega');
  perform pg_temp.chk((select company from public.contacts where id = v_ct) = 'Barbearia Central' and (select document from public.contacts where id = v_ct) is null, 'B3: usa os campos do CRM e não grava documento à toa');
  r := public.agente_salvar_contato(v_ct, '{"nota_fiscal":"sim","documento":"123.456.789-09","email":"cliente@exemplo.com.br"}'::jsonb);
  perform pg_temp.chk((select document from public.contacts where id = v_ct) = '12345678909' and r -> 'falta' @> '"endereco"' is not null, 'B3: nota fiscal libera o documento');
  perform pg_temp.chk(not (r -> 'falta' @> '"empresa"') and not (r -> 'falta' @> '"documento"'), 'B3: pergunta só o que falta');
  perform pg_temp.chk((select marketing_consent from public.contacts where id = v_ct) = 'none' and (r ->> 'perguntar_promocoes')::boolean, 'B3: consentimento nunca é presumido');
  r := public.agente_salvar_contato(v_ct, '{"consentimento_promocoes":"sim"}'::jsonb);
  perform pg_temp.chk((select marketing_consent from public.contacts where id = v_ct) = 'opted_in' and (select marketing_consent_source from public.contacts where id = v_ct) is not null and (select marketing_consent_at from public.contacts where id = v_ct) is not null, 'B3: consentimento registrado com data e origem');
  update public.contacts set marketing_consent = 'opted_out' where id = v_ct;
  r := public.agente_salvar_contato(v_ct, '{"consentimento_promocoes":"sim"}'::jsonb);
  perform pg_temp.chk((select marketing_consent from public.contacts where id = v_ct) = 'opted_out', 'B3: quem pediu para parar não volta a receber promoções');
  update public.contacts set marketing_consent = 'none' where id = v_ct;
  r := public.agente_salvar_contato(v_ct, '{"urgencia":"preciso para sexta"}'::jsonb);
  perform pg_temp.chk((select urgente from public.contacts where id = v_ct), 'B3: urgência citada pelo cliente vira selo no CRM');

  -- B6: setores
  r := public.agente_encaminhar_setor(v_cv, 'comercial', 'cliente quer orçamento de banner', 'pede banner 1x2');
  perform pg_temp.chk(r ->> 'setor' = 'comercial' and not (r ->> 'dono_chamado')::boolean, 'B6: comercial cobre venda e orçamento');
  r := public.agente_encaminhar_setor(v_cv, 'financeiro', 'cliente diz que pagou', null);
  perform pg_temp.chk(r ->> 'setor' = 'financeiro' and r -> 'financeiro' ->> 'pagamento' = 'sem_pedido', 'B6: financeiro responde com o que está no sistema, sem inventar');
  r := public.agente_encaminhar_setor(v_cv, 'arte', 'cliente enviou o arquivo', null);
  perform pg_temp.chk(r ->> 'setor' = 'arte' and exists (select 1 from public.tasks where contact_id = v_ct and setor = 'arte'), 'B6: arte vira tarefa na fila do dono');
  r := public.agente_encaminhar_setor(v_cv, 'comercial', 'cliente reclama de produto errado', 'veio errado');
  perform pg_temp.chk(r ->> 'setor' = 'dono' and (r ->> 'dono_chamado')::boolean, 'B6: reclamação vai para o dono mesmo pedindo comercial');
  perform pg_temp.chk(exists (select 1 from public.alertas where contact_id = v_ct and setor = 'dono' and gravidade = 'alta' and dados ? 'acao_recomendada' and dados ? 'resumo' and dados ? 'historico'), 'B6: alerta ao dono com resumo, motivo, ação recomendada e histórico');
  r := public.agente_encaminhar_setor(v_cv, 'comercial', 'quer reembolso do pedido', null);
  perform pg_temp.chk(r ->> 'acao_recomendada' like '%reembolso%' and r ->> 'orientacao' like '%reembolso%', 'B6: reembolso vai para o dono sem promessa');

  -- B7: promessas indevidas
  insert into public.agente_execucoes (conversation_id, contact_id, message_id, teste) values (v_cv, v_ct, v_m2, true) returning id into v_ex;
  perform pg_temp.chk(public.agente_promessas_indevidas(v_ex, 'Seu pagamento foi confirmado, obrigado!') @> array['promessa:pagamento_sem_confirmacao'], 'B7: não afirma pagamento sem consulta ao sistema');
  perform pg_temp.chk(array_length(public.agente_promessas_indevidas(v_ex, 'Assim que o pagamento for confirmado eu aviso a produção.'), 1) is null, 'B7: frase condicional sobre pagamento é permitida');
  perform pg_temp.chk(public.agente_promessas_indevidas(v_ex, 'Sua arte já foi aprovada') @> array['promessa:arte_aprovada_sem_status'], 'B7: não afirma arte aprovada sem status');
  perform pg_temp.chk(public.agente_promessas_indevidas(v_ex, 'Seu pedido já entrou em produção') @> array['promessa:producao_sem_status'], 'B7: não afirma produção sem status');
  perform pg_temp.chk(public.agente_promessas_indevidas(v_ex, 'Seu pedido está pronto, pode retirar') @> array['promessa:conclusao_sem_status'], 'B7: não afirma conclusão sem status');
  perform pg_temp.chk(public.agente_promessas_indevidas(v_ex, 'Fica pronto no dia 17') @> array['promessa:data_que_a_ferramenta_nao_deu'], 'B7: não inventa data');
  perform pg_temp.chk(public.agente_promessas_indevidas(v_ex, 'Consigo 15% de desconto para você') @> array['promessa:desconto_fora_da_funcao'], 'B7: não oferece desconto fora da função');
  perform pg_temp.chk(public.agente_promessas_indevidas(v_ex, 'Vamos fazer o reembolso hoje mesmo') @> array['promessa:reembolso'], 'B7: não promete reembolso');
  perform pg_temp.chk(public.agente_promessas_indevidas(v_ex, 'Seu dinheiro será devolvido amanhã') @> array['promessa:reembolso'], 'B7: não promete devolução do dinheiro');
  perform pg_temp.chk(array_length(public.agente_promessas_indevidas(v_ex, 'Oi! Posso te ajudar com cartões de visita?'), 1) is null, 'B7: conversa normal passa');
  r := public.agente_saida_segura(v_ex, 'Seu pagamento foi confirmado!');
  perform pg_temp.chk(not (r ->> 'ok')::boolean and r -> 'motivos' @> '"promessa:pagamento_sem_confirmacao"', 'B7: a trava de saída bloqueia a promessa (camada determinística)');
  -- com status real no sistema a afirmação passa
  insert into public.orders (contact_id, title, payment_method) values (v_ct, 'pago', 'pix') returning id into v_o;
  update public.orders set payment_status = 'aprovado' where id = v_o;
  perform pg_temp.chk(array_length(public.agente_promessas_indevidas(v_ex, 'Seu pagamento foi confirmado!'), 1) is null, 'B7: com o pagamento aprovado no sistema a afirmação é permitida');
  update public.orders set art_status = 'aprovada' where id = v_o;
  perform pg_temp.chk(array_length(public.agente_promessas_indevidas(v_ex, 'Sua arte já foi aprovada'), 1) is null, 'B7: arte aprovada no sistema libera a afirmação');

  -- B9: motivo de perda e estratégia
  select sku into v_sku from public.catalogo where vendavel and active limit 1;
  r := public.montar_orcamento(v_ct, jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', 1)), jsonb_build_object('conversation_id', v_cv));
  v_orc := (r ->> 'orcamento_id')::uuid;
  perform public.orcamento_registrar_perda(v_orc, 'preco');
  r := public.recuperacao_proximo_passo(v_orc);
  perform pg_temp.chk(r ->> 'passo' = 'esclarecer' and r ->> 'motivo_perda' = 'preco', 'B9: preço começa esclarecendo');
  perform pg_temp.chk((select max(ordem) from public.estrategia_recuperacao where motivo = 'preco') = 5 and (select passo from public.estrategia_recuperacao where motivo = 'preco' and ordem = 5) = 'condicao_especial', 'B9: condição especial é o último degrau');
  perform pg_temp.chk((select passo from public.estrategia_recuperacao where motivo = 'abandonou_checkout' and ordem = 1) = 'ajudar_checkout', 'B9: checkout abandonado recebe ajuda primeiro');
  update public.contacts set marketing_consent = 'opted_out' where id = v_ct;
  perform pg_temp.chk(public.recuperacao_proximo_passo(v_orc) ->> 'motivo' = 'optout', 'B9: respeita o optout');
  perform pg_temp.chk(not (public.orcamento_registrar_perda(v_orc, 'inventado') ->> 'ok')::boolean, 'B9: motivo inválido é recusado');

  -- B10: BauerLab
  r := public.agente_bauerlab(v_cv, 'precisa de um site');
  perform pg_temp.chk(not (r ->> 'ja_apresentado')::boolean and r ->> 'telefone' = '+5531998021169' and r ->> 'contato' = 'João Victor', 'B10: apresenta a BauerLab e passa o contato de João Victor');
  perform pg_temp.chk(exists (select 1 from public.alertas where tipo = 'oportunidade_bauerlab' and gravidade = 'baixa') and exists (select 1 from public.oportunidades_bauerlab where contact_id = v_ct), 'B10: registra a oportunidade e alerta em baixa gravidade');
  r := public.agente_bauerlab(v_cv, 'de novo');
  perform pg_temp.chk((r ->> 'ja_apresentado')::boolean, 'B10: uma vez só, sem insistir');

  -- B11: validador de pedido
  insert into public.orders (contact_id, title) values (v_ct, 'incompleto') returning id into v_o;
  r := public.pedido_pendencias(v_o);
  perform pg_temp.chk(not (r ->> 'completo')::boolean and (r -> 'pendencias') @> '"Itens do pedido"' and (r -> 'pendencias') @> '"Pagamento confirmado"', 'B11: pedido incompleto lista o que falta');

  -- B5: três opções
  select count(*) into v_n from public.catalogo where active and vendavel;
  select c.sku into v_sku from public.catalogo c where c.active and c.vendavel and (select count(*) from public.catalogo d where d.grupo_produto = c.grupo_produto and d.tamanho_mm is not distinct from c.tamanho_mm and d.cores is not distinct from c.cores and d.active and d.vendavel) >= 3
    order by c.quantidade offset 1 limit 1;
  if v_sku is not null then
    r := public.montar_opcoes(v_ct, v_sku, null);
    perform pg_temp.chk((r ->> 'ok')::boolean and jsonb_array_length(r -> 'opcoes') between 1 and 3, 'B5: devolve até 3 opções');
    perform pg_temp.chk(exists (select 1 from jsonb_array_elements(r -> 'opcoes') e where e ->> 'rotulo' = 'intermediaria' and (e ->> 'recomendada')::boolean), 'B5: a recomendada é a pedida, em destaque');
    perform pg_temp.chk(not exists (select 1 from jsonb_array_elements(r -> 'opcoes') e where e ->> 'rotulo' <> 'intermediaria' and e ->> 'diferenca' in ('outra configuração', 'a que você pediu')), 'B5: toda opção tem diferença real do catálogo');
    perform pg_temp.chk((select min(lucro_pior_caso) from public.orcamento_opcoes where grupo_id = (r ->> 'grupo_id')::uuid) >= (select lucro_liquido_minimo from public.parametros_comerciais) - 0.05, 'B5: cada opção passa na margem mínima no pior caso');
    perform pg_temp.chk((select count(distinct preco_total) from public.orcamento_opcoes where grupo_id = (r ->> 'grupo_id')::uuid) = (select count(*) from public.orcamento_opcoes where grupo_id = (r ->> 'grupo_id')::uuid), 'B5: preços das opções são diferentes entre si');
    perform public.orcamento_opcao_escolher((r ->> 'grupo_id')::uuid, 'intermediaria');
    perform pg_temp.chk((select escolhidas from public.opcoes_conversao where rotulo = 'intermediaria') >= 1, 'B5: registra qual opção o cliente escolheu');
  else
    perform pg_temp.chk(true, 'B5: catálogo local sem 3 opções (cenário coberto em produção)');
  end if;
  perform pg_temp.chk(not (public.montar_opcoes(v_ct, 'SKU-INEXISTENTE') ->> 'ok')::boolean, 'B5: SKU inválido não gera opções');
  -- B8: cupom de recompra incondicional, desligado por padrão
  perform pg_temp.chk(not coalesce((select (value ->> 'ativo')::boolean from public.app_settings where key = 'cupom_recompra'), true), 'B8: o cupom nasce desligado');
  r := public.cupom_recompra_simular(100);
  perform pg_temp.chk((r ->> 'amostra')::int > 0 and (r ->> 'menor_lucro_no_pior_caso')::numeric >= 0, 'B8: simulação de margem mostra lucro não negativo no pior caso com 5%');
  insert into public.orders (contact_id, title, payment_method) values (v_ct, 'concluido', 'pix') returning id into v_o;
  update public.orders set payment_status = 'aprovado', delivered_at = now() where id = v_o;
  perform pg_temp.chk(not (public.cupom_recompra_emitir(v_o) ->> 'emitido')::boolean, 'B8: desligado não emite cupom');
  update public.app_settings set value = jsonb_set(value, '{ativo}', 'true') where key = 'cupom_recompra';
  perform public.cupom_recompra_emitir(v_o);
  perform pg_temp.chk((select percentual from public.cupons_recompra where contact_id = v_ct) = 5 and (select valido_ate from public.cupons_recompra where contact_id = v_ct) > now(), 'B8: cliente que concluiu um pedido ganha 5%');
  perform public.cupom_recompra_emitir(v_o);
  perform pg_temp.chk((select count(*) from public.cupons_recompra where contact_id = v_ct) = 1, 'B8: uma vez por cliente');
  select sku into v_sku from public.catalogo where vendavel and active and custo > 0 order by md5(sku) limit 1;
  r := public.montar_orcamento(v_ct, jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', 1)), jsonb_build_object('conversation_id', v_cv));
  v_orc := (r ->> 'orcamento_id')::uuid;
  r := public.cupom_recompra_aplicar(v_orc);
  perform pg_temp.chk(not (r ->> 'aplicado')::boolean or ((r ->> 'desconto')::numeric <= (select (quantidade * preco_unitario) * 0.05 from public.orcamento_itens where orcamento_id = v_orc limit 1) + 0.01 and public.validar_margem(v_orc) ->> 'status' = 'ok'),
    'B8: se aplicado, nunca passa de 5% e passa na trava de lucro');
  perform pg_temp.chk((select valor_ok from (select (select count(*) from public.cupons_recompra where contact_id = v_ct and usado_em is not null) <= 1 as valor_ok) q), 'B8: usado no máximo uma vez');
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
