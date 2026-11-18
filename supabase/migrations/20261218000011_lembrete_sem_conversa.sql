-- 18/11/2026: lembrete de pagamento para pedido manual sem conversa de WhatsApp falhava com "conversation_id inválido".
-- Agora nem é agendado, e se algum chegar sem conversa é pulado com motivo claro. Aditiva e idempotente.
do $m$
declare d text; n text;
begin
  -- 1) agendamento: só pedido cujo contato tem conversa
  select pg_get_functiondef('public.followup_agendar(timestamptz)'::regprocedure) into d;
  if position('sem_conversa_whatsapp' in d) = 0 then
    n := regexp_replace(d, E'where p\\.eh_link and p\\.link_ativo and p\\.status = ''pendente''',
      E'where p.eh_link and p.link_ativo and p.status = ''pendente'' /* sem_conversa_whatsapp */ and coalesce(ord.conversation_id, (select cv0.id from public.conversations cv0 where cv0.contact_id = ord.contact_id limit 1)) is not null');
    if n = d then raise exception 'followup_agendar mudou: âncora do link_pagamento não encontrada.'; end if;
    execute n;
  end if;

  -- 2) montagem: sem conversa, pula
  select pg_get_functiondef('public.followup_montar(uuid,timestamptz)'::regprocedure) into d;
  if position('sem_conversa' in d) = 0 then
    n := regexp_replace(d, E'select \\* into o from public\\.orcamentos where id = f\\.orcamento_id;',
      E'if cv.id is null then return jsonb_build_object(''ok'', true, ''acao'', ''pular'', ''motivo'', ''sem_conversa''); end if;\n  select * into o from public.orcamentos where id = f.orcamento_id;');
    if n = d then raise exception 'followup_montar mudou: âncora do orçamento não encontrada.'; end if;
    execute n;
  end if;
end
$m$;

-- 3) limpa o que já falhou por esse motivo (não há conversa para enviar)
update public.followup_fila
   set status = 'pulado', motivo = 'sem_conversa'
 where status in ('erro', 'pendente')
   and coalesce(motivo, '') in ('', 'conversation_id inválido.')
   and conversation_id is null
   and not exists (select 1 from public.conversations cv where cv.contact_id = followup_fila.contact_id)
   and (status = 'erro' or regra_codigo like 'PAG_%');
