-- Testes da rodada 18/11/2026 (diário do tráfego pago). Rodar no SQL Editor (tudo desfeito no fim, a transação termina em exceção).
-- Cobre: regex de aprovação por pagamento, alerta de condição fora do padrão sem falso positivo de medida, travas de saída
-- (frete em toda BH, prazo por dia da semana, NF antes do pagamento, frase repetida) e orçamento sem opções duplicadas por orientação.
do $t$
declare v_ex uuid; v_conv uuid; r jsonb; falhas text[] := '{}';
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform set_config('request.jwt.claim.role', 'service_role', true);

  if not ('Pagamento será pix' ~* '(\mpix\M|pagamento (ser[aá]|vai ser|[eé]|por|no))') then falhas := falhas || 'aprovação por "pagamento será pix"'; end if;
  if not ('Ok' ~* '^\W*(ok|sim|blz|beleza|certo|show|perfeito|bora|fechado)\W*$') then falhas := falhas || 'aprovação por "Ok"'; end if;
  if 'adesivo 5 x 10 cm' ~* '\m([3-9]|1[0-2]) ?x (sem juros|no cart|de r\$|no cr[eé]dito)' then falhas := falhas || 'medida virou parcelamento'; end if;
  if not ('Pagamento 50% outra partir retira e pagar?' ~* '(50 ?%|metade|sinal|entrada)') then falhas := falhas || '50% não detectado'; end if;

  select e.id, e.conversation_id into v_ex, v_conv from public.agente_execucoes e where e.status = 'concluida' and coalesce(e.teste, false) = false order by e.iniciado_em desc limit 1;
  if v_ex is null then raise exception 'sem execução para testar'; end if;

  r := public.agente_saida_segura(v_ex, 'Somos de BH sim! Entregamos por motoboy em toda BH e região. Qual quantidade você quer?');
  if coalesce(r ->> 'texto_saneado', '') ~* 'toda BH' then falhas := falhas || 'frete em toda BH passou'; end if;
  r := public.agente_saida_segura(v_ex, 'Consigo deixar pronto para segunda de manhã sem problema nenhum. Quer que eu monte?');
  if not (r -> 'motivos' ? 'promessa:prazo_sem_ferramenta') then falhas := falhas || 'prazo por dia da semana passou'; end if;
  r := public.agente_saida_segura(v_ex, 'Perfeito, anotei tudo. Você vai querer Nota Fiscal para esse pedido? Me diz por favor.');
  if not (r -> 'motivos' ? 'promessa:nf_antes_do_pagamento') and exists (select 1 from public.agente_execucoes x where x.id = v_ex) then
    -- só falha se o contato da execução não tiver pedido pago recente
    if not exists (select 1 from public.orders o join public.agente_execucoes x on x.contact_id = o.contact_id where x.id = v_ex and (o.payment_status = 'aprovado' or o.payment_manual) and coalesce(o.paid_at, o.created_at) > now() - interval '30 days') then
      falhas := falhas || 'pergunta de NF antes do pagamento passou';
    end if;
  end if;

  insert into public.messages (conversation_id, direction, type, body, status, created_at) values (v_conv, 'out', 'text', 'Assim que o pagamento for confirmado, a equipe de criação já faz o ajuste.', 'sent', now());
  r := public.agente_saida_segura(v_ex, 'Assim que o pagamento for confirmado no link acima, nossa equipe já ajusta. Você prefere Pix ou cartão para fechar?');
  if coalesce(r ->> 'texto_saneado', '') ~* 'Assim que o pagamento' then falhas := falhas || 'frase repetida não foi removida'; end if;

  r := public.buscar_produto('crachá funcionário', 5);
  if jsonb_array_length(r -> 'opcoes') <> (select count(distinct (o ->> 'descricao_curta') ) from jsonb_array_elements(r -> 'opcoes') o) then falhas := falhas || 'opções duplicadas na busca'; end if;

  if array_length(falhas, 1) > 0 then raise exception 'FALHAS: %', array_to_string(falhas, '; '); end if;
  raise exception 'OK rodada 18 (desfeito de propósito)';
end $t$;
