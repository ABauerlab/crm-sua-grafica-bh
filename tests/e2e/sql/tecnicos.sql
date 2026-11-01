-- Cenários técnicos só de banco (Etapa 8B). Rode no SQL do Supabase ou pelo MCP; falha com exceção se algo quebrar.
-- Cria contatos is_teste e limpa tudo no fim (e2e_limpar só apaga a flag).
do $$
declare c uuid; n int; li timestamptz; ordem text[]; r jsonb;
begin
  -- 1) Webhook duplicado da Meta: a mesma mensagem duas vezes grava uma só
  perform public.ingest_inbound_message('55000093330001', 'TESTE_tec', 'wamid.e2e.dup', 'text', 'oi', null, now(), null);
  perform public.ingest_inbound_message('55000093330001', 'TESTE_tec', 'wamid.e2e.dup', 'text', 'oi', null, now(), null);
  select count(*) into n from public.messages where wa_message_id = 'wamid.e2e.dup';
  if n <> 1 then raise exception 'webhook duplicado gravou % linhas', n; end if;
  update public.contacts set is_teste = true, tags = array['teste'] where wa_id = '55000093330001';
  select id into c from public.conversations where contact_id = (select id from public.contacts where wa_id = '55000093330001');

  -- 2) Mensagens fora de ordem: a mais nova chega primeiro; o histórico fica em ordem de horário e a conversa não "volta no tempo"
  perform public.ingest_inbound_message('55000093330001', 'TESTE_tec', 'wamid.e2e.b', 'text', 'segunda', null, now() + interval '2 minutes', null);
  perform public.ingest_inbound_message('55000093330001', 'TESTE_tec', 'wamid.e2e.a', 'text', 'primeira', null, now() + interval '1 minute', null);
  select array_agg(body order by created_at) into ordem from public.messages where conversation_id = c;
  if ordem <> array['oi', 'primeira', 'segunda'] then raise exception 'ordem do histórico errada: %', ordem; end if;
  select last_inbound_at into li from public.conversations where id = c;
  if li < now() + interval '90 seconds' then raise exception 'last_inbound_at voltou no tempo'; end if;

  -- 3) Conversa nova nasce em modo humano até o WF1 assumir (nunca responde sem passar pela entrada)
  update public.conversations set last_inbound_at = now() where id = c;
  if public.agente_bloqueio(c) is distinct from 'modo_humano' then raise exception 'conversa nova deveria estar em modo humano, veio %', public.agente_bloqueio(c); end if;

  -- 4) Modo IA com contato de teste: liberado; opt-out: o agente não proativa nem responde promoção (bloqueio optout)
  update public.conversations set modo_atendimento = 'ia', ai_handled = true where id = c;
  if public.agente_bloqueio(c) is not null then raise exception 'contato de teste em modo IA deveria estar liberado, veio %', public.agente_bloqueio(c); end if;
  update public.contacts set marketing_consent = 'opted_out', marketing_consent_at = now(), marketing_consent_source = 'whatsapp' where wa_id = '55000093330001';
  if public.agente_bloqueio(c) is distinct from 'optout' then raise exception 'opt-out deveria bloquear o agente, veio %', public.agente_bloqueio(c); end if;

  -- 5) A flag is_teste protege a limpeza: um contato real (sem a flag) nunca é apagado
  perform public.ingest_inbound_message('55000093330002', 'Cliente Real Simulado', 'wamid.e2e.real', 'text', 'oi', null, now(), null);
  r := public.e2e_limpar('TESTE_tec');
  if not exists (select 1 from public.contacts where wa_id = '55000093330002') then raise exception 'e2e_limpar apagou contato sem a flag'; end if;
  if exists (select 1 from public.contacts where wa_id = '55000093330001') then raise exception 'e2e_limpar não apagou o contato de teste'; end if;
  delete from public.contacts where wa_id = '55000093330002';
  raise notice 'OK: cenários técnicos de banco (%)', r;
end $$;
