-- Autorrecuperação do atendimento: se o modelo falhou (por exemplo, crédito do Gemini esgotado) e o cliente ficou sem resposta
-- (ou só com a frase neutra), a conversa é reprocessada sozinha a cada 3 minutos, com limite de tentativas.
-- A URL de entrada do WF1 fica em app_segredos (chave n8n_wf1_entrada_url), nunca no repositório. Aditiva e idempotente.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function private.agente_retomar_travadas() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; v_url text; v_n integer := 0;
begin
  select valor into v_url from public.app_segredos where chave = 'n8n_wf1_entrada_url';
  if v_url is null then return 0; end if;
  if coalesce((select (value ->> 'enabled')::boolean from public.app_settings where key = 'agent_retomada'), true) = false then return 0; end if;
  if coalesce((select (value ->> 'enabled')::boolean from public.app_settings where key = 'agent'), false) = false then return 0; end if;

  for r in
    select cv.id as conv, mi.id as msg
      from public.conversations cv
      join public.contacts ct on ct.id = cv.contact_id
      join lateral (select m.direction, m.body, m.created_at from public.messages m where m.conversation_id = cv.id order by m.created_at desc limit 1) ult on true
      join lateral (select m.id, m.created_at from public.messages m where m.conversation_id = cv.id and m.direction = 'in' order by m.created_at desc limit 1) mi on true
     where coalesce(cv.modo_atendimento, 'ia') = 'ia' and coalesce(cv.ai_handled, true)
       and not coalesce(ct.optout, false) and not ('teste' = any (coalesce(ct.tags, '{}')))
       and mi.created_at > now() - interval '6 hours' and mi.created_at < now() - interval '4 minutes'
       and (not coalesce(cv.needs_human, false) or (ult.direction = 'out' and ult.body like 'Oi! Recebi sua mensagem e já volto%'))
       and (ult.direction = 'in'
            or (ult.direction = 'out' and ult.created_at < now() - interval '4 minutes'
                and (ult.body like 'Oi! Recebi sua mensagem e já volto%' or ult.body like 'Deixa eu confirmar isso certinho aqui e já te respondo%'
                     or ult.body like 'Deixa eu conferir os detalhes exatos%')))
       and not exists (select 1 from public.agente_execucoes e where e.message_id = mi.id and e.status in ('ignorada', 'rodando'))
       and not exists (select 1 from public.agente_execucoes e where e.conversation_id = cv.id and e.status = 'rodando' and e.iniciado_em > now() - interval '5 minutes')
       and (select count(*) from public.agent_logs l where l.conversation_id = cv.id and l.action = 'retomada' and l.detail ->> 'message_id' = mi.id::text) < 6
       and not exists (select 1 from public.agent_logs l where l.conversation_id = cv.id and l.action = 'retomada' and l.created_at > now() - interval '10 minutes')
     limit 5
  loop
    update public.conversations set needs_human = false where id = r.conv and needs_human; -- o aviso veio da própria falha do modelo
    delete from public.agente_execucoes where message_id = r.msg;
    insert into public.agent_logs (conversation_id, actor, action, detail, result, workflow)
    values (r.conv, 'sistema', 'retomada', jsonb_build_object('message_id', r.msg), 'ok', 'private.agente_retomar_travadas');
    perform net.http_post(url := v_url, headers := '{"Content-Type": "application/json"}'::jsonb, body := jsonb_build_object('message_id', r.msg));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function private.agente_retomar_travadas() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'agente-retomar-travadas') then perform cron.unschedule('agente-retomar-travadas'); end if;
  perform cron.schedule('agente-retomar-travadas', '*/3 * * * *', 'select private.agente_retomar_travadas();');
end $$;
