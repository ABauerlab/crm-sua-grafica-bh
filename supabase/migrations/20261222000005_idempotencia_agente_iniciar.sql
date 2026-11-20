-- Blindagem final da Fase 1, item 3: loop de saudações duplicadas no WF1 (caso "Contato extra #02").
-- Causa raiz: o nó "Trava da conversa" do WF1 chama agente_iniciar com retryOnFail (até 3 tentativas,
-- timeout de 20s). Se a 1a chamada já tiver travado a rodada no banco (status 'rodando') mas a resposta
-- HTTP demorar e o n8n desistir por timeout, a 2a tentativa (mesma mensagem, mesmo id de execução) não
-- se via como bloqueio: o filtro "id <> v_ex.id" só olha OUTRAS execuções da conversa, nunca a própria.
-- Resultado: a 2a tentativa também recebia ok=true e o WF1 rodava a mensagem inteira de novo (Gemini +
-- envio no WhatsApp), produzindo saudações repetidas para o mesmo cliente.
-- Fix: reconfere o status da própria execução (já dentro da trava consultiva por conversa) e, se ela
-- já estiver 'rodando' ou 'concluida', devolve ok=false (motivo 'ja_processada') em vez de reiniciar.
-- O WF1 trata ok=false do mesmo jeito que "ocupado" (espera e tenta de novo), então nenhuma mudança no
-- workflow é necessária.
create or replace function public.agente_iniciar(p_message uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_ex record;
begin
  select * into v_ex from public.agente_execucoes where message_id = p_message;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'sem_execucao'); end if;
  perform pg_advisory_xact_lock(hashtext(v_ex.conversation_id::text));

  -- Idempotência: reconfere a própria execução já dentro da trava da conversa. Se uma tentativa
  -- anterior (retry do n8n por timeout de rede, não por falha real) já iniciou ou terminou esta
  -- mesma mensagem, não processa de novo.
  select * into v_ex from public.agente_execucoes where id = v_ex.id;
  if v_ex.status in ('rodando', 'concluida') then
    return jsonb_build_object('ok', false, 'motivo', 'ja_processada', 'execucao_id', v_ex.id, 'conversation_id', v_ex.conversation_id);
  end if;

  /* lock150 */ -- Destrava automaticamente execuções órfãs/travadas que estejam em 'rodando' há mais de 150 segundos
  update public.agente_execucoes
  set status = 'erro', motivo = 'timeout_auto_destravado', finalizado_em = now()
  where conversation_id = v_ex.conversation_id
    and status = 'rodando'
    and id <> v_ex.id
    and iniciado_em <= now() - interval '150 seconds';

  -- Se ainda houver execução rodando recentemente (< 150 segundos), retorna ocupado
  if exists (
    select 1 from public.agente_execucoes x
    where x.conversation_id = v_ex.conversation_id and x.status = 'rodando' and x.id <> v_ex.id and x.iniciado_em > now() - interval '150 seconds'
  ) then
    return jsonb_build_object('ok', false, 'motivo', 'ocupado');
  end if;

  update public.agente_execucoes set status = 'rodando', iniciado_em = now() where id = v_ex.id;
  return jsonb_build_object('ok', true, 'execucao_id', v_ex.id, 'conversation_id', v_ex.conversation_id, 'contact_id', v_ex.contact_id);
end;
$function$;
