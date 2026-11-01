-- Etapa 7B, Bloco A: taxas por método, taxa real, pedido manual, exclusão, atraso e urgência. Desfaz tudo no fim.
-- Sucesso aparece como "OK: N testes passaram".
begin;
create temp table _t (n int, ok boolean, nome text);
create or replace function pg_temp.chk(p_ok boolean, p_nome text) returns void language plpgsql as $$
begin insert into _t values ((select count(*) + 1 from _t), coalesce(p_ok, false), p_nome); end $$;
create or replace function pg_temp.erro(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return sqlerrm; end $$;

do $$
declare
  v_staff uuid := gen_random_uuid(); v_ct uuid; v_cv uuid; v_o uuid; v_o2 uuid; v_o3 uuid; v_o4 uuid; v_pg uuid;
  r jsonb; v_p1 jsonb; v_p2 jsonb; v_sku text; v_orc uuid; f numeric; lp numeric; lm jsonb;
begin
  perform set_config('request.jwt.claim.role', 'service_role', true);
  insert into auth.users (id, email) values (v_staff, 'contato.bauerlab@gmail.com');
  insert into public.profiles (id, name, role) values (v_staff, 'Dono', 'admin');
  update public.app_settings set value = jsonb_set(value, '{email}', '"contato.bauerlab@gmail.com"') where key = 'owner';

  -- ============================ A1: taxas por método e parcelas
  perform pg_temp.chk((private.taxa_pagamento('pix') ->> 'pct')::numeric = 0.99, 'Pix 0,99%');
  perform pg_temp.chk((private.taxa_pagamento('cartao_credito', 1) ->> 'pct')::numeric = 4.98, 'crédito à vista 4,98%');
  perform pg_temp.chk((private.taxa_pagamento('cartao_credito', 2) ->> 'pct')::numeric = 10.50, 'crédito em 2x sem juros usa a taxa de 2x');
  perform pg_temp.chk((private.taxa_pagamento('saldo_mercado_pago') ->> 'pct')::numeric = 4.99, 'saldo 4,99%');
  perform pg_temp.chk((private.taxa_pagamento('open_finance') ->> 'pct')::numeric = 0, 'Open Finance 0%');
  perform pg_temp.chk((private.taxa_pagamento('dinheiro') ->> 'pct')::numeric = 0 and (private.taxa_pagamento('dinheiro') ->> 'conhecido')::boolean, 'dinheiro sem taxa');
  perform pg_temp.chk((private.taxa_pagamento('transferencia') ->> 'pct')::numeric = 0, 'transferência sem taxa');
  perform pg_temp.chk(not (private.taxa_pagamento('manual') ->> 'conhecido')::boolean and (private.taxa_pagamento('manual') ->> 'pct')::numeric = 10.50, 'método desconhecido usa a pior taxa');
  perform pg_temp.chk((private.taxa_pagamento(null) ->> 'pct')::numeric = 10.50, 'sem método usa a pior taxa (2x)');
  perform pg_temp.chk((private.taxa_pagamento('cartao_credito', 4) ->> 'pct')::numeric = 10.50 + 2 * 2.00, 'acima de 2x soma o adicional por parcela');

  -- ============================ A2/A3: piso na pior taxa, taxa por dentro, método previsto não baixa a trava
  select sku into v_sku from public.catalogo where vendavel and active limit 1;
  v_p1 := public.calcular_preco(v_sku, 1, '{}'::jsonb);
  v_p2 := public.calcular_preco(v_sku, 1, '{"metodo":"pix","simular_metodo":true}'::jsonb);
  perform pg_temp.chk(public.calcular_preco(v_sku, 1, '{"metodo":"pix"}'::jsonb) = v_p1, 'método informado no contexto não baixa o preço (só com simular_metodo)');
  perform pg_temp.chk((v_p1 ->> 'piso')::numeric >= (v_p2 ->> 'piso')::numeric, 'piso sem método é maior ou igual ao piso do Pix');
  perform pg_temp.chk((v_p1 ->> 'piso_duro')::numeric > (v_p2 ->> 'piso_duro')::numeric, 'piso duro sem método considera o 2x');
  -- lucro líquido do preço final, calculado com a pior taxa, respeita o mínimo quando a regra é o piso
  perform pg_temp.chk((v_p1 ->> 'lucro_liquido')::numeric > 0, 'preço final nunca tem lucro negativo no pior caso');
  perform pg_temp.chk(private.lucro((v_p1 ->> 'preco_total')::numeric, (select custo from public.catalogo where sku = v_sku), private.custos_operacionais(null), 'pix') >= (v_p1 ->> 'lucro_liquido')::numeric,
    'em qualquer outro método o lucro é igual ou maior que no pior caso');

  insert into public.contacts (wa_id, name) values ('5531900000071', 'Cliente Bloco A') returning id into v_ct;
  insert into public.conversations (contact_id, ai_handled, modo_atendimento) values (v_ct, true, 'ia') returning id into v_cv;
  r := public.montar_orcamento(v_ct, jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', 1)), jsonb_build_object('conversation_id', v_cv, 'metodo', 'pix'));
  v_orc := (r ->> 'orcamento_id')::uuid;
  perform pg_temp.chk((select metodo_previsto from public.orcamentos where id = v_orc) is null, 'orçamento nunca guarda método previsto (a trava usa o pior caso)');
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  lm := public.orcamento_lucro_por_metodo(v_orc);
  perform pg_temp.chk(jsonb_array_length(lm -> 'metodos') >= 7 and lm ->> 'pior_caso' = 'cartao_credito_2x', 'tabela interna de lucro por método existe');
  perform pg_temp.chk((select (e ->> 'lucro_liquido')::numeric from jsonb_array_elements(lm -> 'metodos') e where e ->> 'metodo' = 'pix')
                    > (select (e ->> 'lucro_liquido')::numeric from jsonb_array_elements(lm -> 'metodos') e where e ->> 'metodo' = 'cartao_credito_2x'), 'Pix dá mais lucro que o cartão em 2x');
  perform pg_temp.chk((select min((e ->> 'lucro_liquido')::numeric) from jsonb_array_elements(lm -> 'metodos') e) >= 0, 'nenhum método gera lucro negativo no orçamento');

  -- ============================ A4: pedido manual, método e taxa
  insert into public.orders (contact_id, title, payment_method) values (v_ct, 'manual dinheiro', 'dinheiro') returning id into v_o;
  perform pg_temp.chk((select payment_fee_pct from public.orders where id = v_o) = 0, 'pedido manual em dinheiro nasce sem taxa');
  insert into public.orders (contact_id, title, payment_method) values (v_ct, 'manual pix', 'pix') returning id into v_o2;
  perform pg_temp.chk((select payment_fee_pct from public.orders where id = v_o2) = 0.99, 'pedido manual no Pix usa 0,99%');
  update public.orders set payment_method = 'cartao_credito', parcelas = 2 where id = v_o2;
  perform pg_temp.chk((select payment_fee_pct from public.orders where id = v_o2) = 10.50, 'crédito em 2x usa a taxa de 2x');
  update public.orders set parcelas = 1 where id = v_o2;
  perform pg_temp.chk((select payment_fee_pct from public.orders where id = v_o2) = 4.98, 'crédito à vista usa 4,98%');
  insert into public.orders (contact_id, title) values (v_ct, 'sem método') returning id into v_o3;
  perform pg_temp.chk((select payment_fee_pct from public.orders where id = v_o3) = 4.98 and (select taxa_fonte from public.orders where id = v_o3) = 'estimada', 'pedido sem método mantém a taxa padrão estimada');
  perform pg_temp.chk(pg_temp.erro(format('select public.confirmar_pagamento_manual(%L)', v_o3)) like '%Escolha o método%', 'confirmar pagamento manual sem método é recusado');
  perform pg_temp.chk(pg_temp.erro(format('select public.confirmar_pagamento_manual(%L, ''manual'')', v_o3)) like '%Escolha o método%', 'método "manual" legado também é recusado');
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price, fora_catalogo) values (v_o3, null, 'item fora do catálogo', 1, 10, 100, true);
  perform public.confirmar_pagamento_manual(v_o3, 'dinheiro');
  perform pg_temp.chk((select payment_fee_pct from public.orders where id = v_o3) = 0 and (select payment_status from public.orders where id = v_o3) = 'aprovado', 'pagamento manual em dinheiro confirma sem taxa');
  perform pg_temp.chk((select lucro_liquido_real from public.orders where id = v_o3) = 100 * (1 - 0.06) - 10, 'lucro real do pedido em dinheiro desconta só imposto e custo');

  -- ============================ A1: taxa REAL do Mercado Pago
  insert into public.orders (contact_id, title, payment_method) values (v_ct, 'mp 2x', 'cartao') returning id into v_o4;
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price, fora_catalogo) values (v_o4, null, 'item', 1, 50, 200, true);
  insert into public.pagamentos (order_id, valor, status, modo, metodo, mp_payment_id, aprovado_em) values (v_o4, 200, 'aprovado', 'producao', 'cartao', 'MP-REAL-1', now()) returning id into v_pg;
  perform private.confirmar_pagamento(v_o4, 'mercadopago', 'cartao', 'MP-REAL-1', now(), v_pg);
  perform pg_temp.chk((select payment_fee_pct from public.orders where id = v_o4) = 4.98, 'cartão sem parcelas informado grava 4,98% até a taxa real chegar');
  r := public.pagamento_taxa_real('MP-REAL-1', 21.40, 178.60, 2);
  perform pg_temp.chk((r ->> 'ok')::boolean and (select taxa_fonte from public.orders where id = v_o4) = 'mercado_pago', 'taxa real do Mercado Pago é gravada');
  perform pg_temp.chk((select payment_fee_pct from public.orders where id = v_o4) = 10.70, 'taxa real vira o percentual do pedido (21,40 de 200)');
  perform pg_temp.chk((select lucro_liquido_real from public.orders where id = v_o4) = round(200 * (1 - 0.06 - 0.107) - 50, 2), 'lucro líquido real usa a taxa real');
  update public.orders set payment_method = 'pix' where id = v_o4;
  perform pg_temp.chk((select payment_fee_pct from public.orders where id = v_o4) = 10.70, 'taxa real não é sobrescrita pela tabela');
  perform pg_temp.chk((public.pagamento_taxa_real('NAO-EXISTE', 1, 1, 1) ->> 'ok')::boolean = false, 'taxa real de pagamento inexistente é ignorada');

  -- ============================ A5: exclusão
  perform pg_temp.chk(pg_temp.erro(format('select public.pedido_excluir(%L, ''x'')', v_o2)) like '%motivo%', 'exclusão exige motivo');
  r := public.pedido_excluir(v_o2, 'cliente desistiu antes de pagar');
  perform pg_temp.chk((r ->> 'ok')::boolean and (select excluido_em from public.orders where id = v_o2) is not null, 'pedido sem pagamento é excluído de forma lógica');
  perform pg_temp.chk((select count(*) from public.pedidos_auditoria where order_id = v_o2 and acao = 'excluido' and por = v_staff and motivo like 'cliente desistiu%') = 1, 'auditoria registra quem, quando e motivo');
  r := public.pedido_excluir(v_o3, 'tentativa em pedido pago');
  perform pg_temp.chk(not (r ->> 'ok')::boolean and r ->> 'motivo' = 'pedido_pago' and exists (select 1 from public.orders where id = v_o3 and excluido_em is null), 'pedido pago nunca é apagado');
  update public.orders set teste = true where id = v_o;
  r := public.pedido_excluir(v_o, 'limpeza de teste');
  perform pg_temp.chk((r ->> 'removido_por_completo')::boolean and not exists (select 1 from public.orders where id = v_o), 'pedido de teste é removido por completo');
  r := public.pedido_cancelar_ou_arquivar(v_o3, 'cancelar', 'cliente pediu o cancelamento');
  perform pg_temp.chk((r ->> 'reembolso_pendente')::boolean and (select reembolso_pendente from public.orders where id = v_o3), 'cancelar pedido pago deixa reembolso pendente para o dono');
  perform pg_temp.chk(exists (select 1 from public.alertas where order_id = v_o3 and tipo = 'reembolso_pendente' and gravidade = 'alta'), 'cancelamento de pedido pago alerta o dono');
  perform pg_temp.chk(exists (select 1 from public.orders where id = v_o3) and exists (select 1 from public.pagamentos where order_id = v_o3), 'registro financeiro do pedido cancelado permanece');
  -- pagamento chega em pedido excluído
  update public.orders set payment_status = 'aprovado' where id = v_o2;
  perform pg_temp.chk((select excluido_em from public.orders where id = v_o2) is null and exists (select 1 from public.pedidos_auditoria where order_id = v_o2 and acao = 'restaurado'), 'pagamento em pedido excluído restaura o pedido e avisa');
  -- orçamento de pedido excluído fica consistente
  insert into public.orders (contact_id, title) values (v_ct, 'com orçamento') returning id into v_o;
  update public.orcamentos set order_id = v_o where id = v_orc;
  perform public.pedido_excluir(v_o, 'duplicado, refeito depois');
  perform pg_temp.chk((select status from public.orcamentos where id = v_orc) = 'cancelado', 'exclusão cancela o orçamento ligado');

  -- ============================ A6: atraso e urgência
  perform pg_temp.chk(public.pedido_esta_atrasado('producao', current_date - 1, null), 'em produção e vencido é atrasado');
  perform pg_temp.chk(not public.pedido_esta_atrasado('producao', current_date, null), 'no dia do prazo ainda não é atrasado');
  perform pg_temp.chk(not public.pedido_esta_atrasado('pago', current_date - 5, null), 'pago com prazo vencido não é atrasado (ainda não foi para produção)');
  perform pg_temp.chk(not public.pedido_esta_atrasado('arte', current_date - 5, null), 'em arte nunca é atrasado');
  perform pg_temp.chk(not public.pedido_esta_atrasado('producao', current_date - 5, now()), 'entregue nunca é atrasado');
  r := public.registrar_urgencia(v_ct, 'cliente precisa para sexta');
  update public.orders set due_date = current_date + 3 where id = v_o4;
  r := public.registrar_urgencia(v_ct, 'cliente precisa para sexta');
  perform pg_temp.chk((select due_date from public.orders where id = v_o4) = current_date + 3, 'urgência não altera o prazo oficial');
  perform pg_temp.chk((select urgente from public.contacts where id = v_ct) and (select urgente from public.orders where id = v_o4), 'urgência marca contato e pedidos abertos');
  perform pg_temp.chk((select urgente_motivo from public.contacts where id = v_ct) = 'cliente precisa para sexta', 'urgência registra o motivo');
  perform pg_temp.chk(not (select urgente from public.orders where id = v_o3), 'urgência não marca pedido cancelado');

  -- ============================ A8: o nome do fornecedor não aparece em nenhum texto gravado (conhecimento, templates, respostas, regras, cenários)
  perform pg_temp.chk((select count(*) from (
      select to_jsonb(t)::text as x from public.conhecimento t union all select to_jsonb(t)::text from public.templates_cache t
      union all select to_jsonb(t)::text from public.testes_conversa t union all select to_jsonb(t)::text from public.quick_replies t
      union all select to_jsonb(t)::text from public.followup_regras t union all select to_jsonb(t)::text from public.app_settings t
      union all select to_jsonb(t)::text from public.agente_config t union all select to_jsonb(t)::text from public.orcamentos t) q
    where x ~* ('z[._-]{0,2}[a4@][._-]{0,2}' || 'p')) = 0, 'sigilo: nenhum texto gravado cita o fornecedor');

  -- ============================ A10: WF9, tipos de erro e ação por tipo (simulação de cada caso)
  perform pg_temp.chk(private.erro_tipo('GBH | WF6', 'Enviar', 'proativo-enviar 500') = 'envio_mensagem', 'WF9: falha de envio de mensagem');
  perform pg_temp.chk(private.erro_tipo('GBH | WF1', 'HTTP', 'ETIMEDOUT timed out') = 'integracao_indisponivel', 'WF9: indisponibilidade de integração');
  perform pg_temp.chk(private.erro_tipo('GBH | FERRAMENTA', 'Consultar tabela do fornecedor', 'falhou') = 'fornecedor', 'WF9: erro de consulta ao fornecedor');
  perform pg_temp.chk(private.erro_tipo('GBH | FERRAMENTA | gerar_link_pagamento', 'mp-criar-link', 'erro') = 'checkout', 'WF9: falha ao gerar checkout');
  perform pg_temp.chk(private.erro_tipo('GBH | WF5', 'Conferir', 'divergência entre valor do pagamento e pedido') = 'divergencia_pagamento', 'WF9: divergência entre pagamento e pedido');
  perform pg_temp.chk(private.erro_tipo('GBH | WF5', 'Gravar', 'duplicate key value violates unique constraint') = 'evento_duplicado', 'WF9: evento duplicado');
  perform pg_temp.chk(private.erro_tipo('GBH | WF2', 'salvar_contato', 'supabase rpc violates check') = 'gravar_crm', 'WF9: falha ao gravar no CRM');
  perform pg_temp.chk(private.erro_tipo('GBH | WF8', 'mudar etapa', 'erro ao atualizar o status do pedido') = 'mudar_status', 'WF9: erro ao mudar status');
  r := public.agente_erro_registrar('GBH | WF6 | Follow-ups', 'x', 'Enviar', 'proativo-enviar 502', null, null, true);
  perform pg_temp.chk(r ->> 'acao' = 'repetir' and r ->> 'tipo' = 'envio_mensagem', 'WF9: envio falho é repetido de forma controlada');
  perform public.agente_erro_registrar('GBH | WF6 | Follow-ups', 'x', 'Enviar', 'proativo-enviar 502', null, null, false);
  perform public.agente_erro_registrar('GBH | WF6 | Follow-ups', 'x', 'Enviar', 'proativo-enviar 502', null, null, false);
  perform public.agente_erro_registrar('GBH | WF6 | Follow-ups', 'x', 'Enviar', 'proativo-enviar 502', null, null, false);
  r := public.agente_erro_registrar('GBH | WF6 | Follow-ups', 'x', 'Enviar', 'proativo-enviar 502', null, null, false);
  perform pg_temp.chk(r ->> 'acao' = 'interromper_e_alertar' and r -> 'alerta' is not null, 'WF9: depois de 3 repetições seguidas interrompe e alerta o dono');
  r := public.agente_erro_registrar('GBH | WF3', 'x', 'mp-criar-link', 'checkout falhou', null, v_o4, true);
  perform pg_temp.chk(r ->> 'acao' = 'interromper_e_alertar' and exists (select 1 from public.alertas where tipo = 'erro_workflow' and gravidade = 'alta'), 'WF9: checkout com falha nunca repete sozinho e alerta com gravidade alta');
  r := public.agente_erro_registrar('GBH | WF5', 'x', 'Gravar', 'duplicate key value', null, null, true);
  perform pg_temp.chk(r ->> 'acao' = 'registrar', 'WF9: evento duplicado só é registrado (idempotência já protegeu)');
  perform pg_temp.chk((select count(*) from public.erros_operacao where simulacao) >= 3, 'WF9: simulações ficam marcadas');
  -- divergência entre pagamento e pedido
  update public.pagamentos set valor = valor + 50 where order_id = v_o4 and status = 'aprovado';
  r := public.pagamentos_divergencias_checar();
  perform pg_temp.chk((r ->> 'divergencias')::int >= 1 and exists (select 1 from public.alertas where tipo = 'divergencia_pagamento' and order_id = v_o4), 'WF9: divergência entre pagamento e pedido gera alerta alto');

  -- ============================ A12: uma só implementação de prazo (início na aprovação da arte, corte das 12h, feriados)
    insert into public.orders (contact_id, title, lead_days, payment_method) values (v_ct, 'prazo', 3, 'pix') returning id into v_o;
    update public.orders set payment_status = 'aprovado', payment_confirmed_at = now() - interval '2 days' where id = v_o;
    update public.orders set art_status = 'aprovada' where id = v_o;
    perform pg_temp.chk((select due_date from public.orders where id = v_o) = private.prazo_data(3, greatest(now() - interval '2 days', (select art_approved_at from public.orders where id = v_o))),
      'prazo: a data do pedido conta da aprovação da arte e usa a mesma função do orçamento');
    select sku into v_sku from public.catalogo where vendavel and active and prazo_dias_uteis is not null limit 1;
    perform pg_temp.chk((public.calcular_prazo(v_sku, now(), false) ->> 'data_pronto')::date = private.prazo_data((select prazo_dias_uteis from public.catalogo where sku = v_sku), now()), 'prazo: calcular_prazo e o pedido usam private.prazo_data');

  -- ============================ segurança
  reset role;
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform pg_temp.chk(pg_temp.erro('select public.pagamento_taxa_real(''x'', 1, 1, 1)') like '%permissão%', 'anon não grava taxa real');
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
