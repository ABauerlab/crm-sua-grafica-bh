-- /resetchat também zera o "cérebro" da conversa (conversations.brain), que antes sobrevivia ao reset
-- e voltava ao contexto da Laura na mensagem seguinte. Aditiva e idempotente (create or replace).
create or replace function public.resetar_contexto_conversa(p_conversation uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_agora timestamptz := now();
begin
  if not private.is_staff() then raise exception 'sem_permissao'; end if;
  update public.conversations
     set contexto_desde = v_agora, summary = null, collected_data = '{}'::jsonb, brain = '{}'::jsonb,
         needs_human = false, ai_handled = true
   where id = p_conversation;
  if not found then raise exception 'conversa_inexistente'; end if;
  insert into public.agent_logs (conversation_id, actor, action, detail, result)
  values (
    p_conversation, 'humano', 'reset_chat',
    jsonb_build_object(
      'desde', v_agora,
      'operador_id', auth.uid(),
      'operador_nome', (select p.name from public.profiles p where p.id = auth.uid())),
    'ok');
  return jsonb_build_object('ok', true, 'desde', v_agora);
end;
$function$;
