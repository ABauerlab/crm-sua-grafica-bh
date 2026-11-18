-- 18/11/2026: quando o cliente usa "Responder" do WhatsApp numa mensagem antiga, a Laura passa a ver
-- qual mensagem foi citada (campo `responde_a` em cada item de `historico`). Aditiva e idempotente.
do $mig$
begin
  if not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agente_contexto_pre_reply') then
    alter function public.agente_contexto(uuid) rename to agente_contexto_pre_reply;
  end if;
end
$mig$;

create or replace function public.agente_contexto(p_conversation uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $f$
declare
  r jsonb;
  v_cfg_n int;
  v_desde timestamptz;
  v_hist jsonb;
begin
  r := public.agente_contexto_pre_reply(p_conversation);
  if r ? 'erro' then return r; end if;

  select greatest(coalesce(c.historico_mensagens, 20), 1) into v_cfg_n from public.agente_config c limit 1;
  select cv.contexto_desde into v_desde from public.conversations cv where cv.id = p_conversation;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'direcao', m.direction,
      'texto', left(coalesce(m.body, ''), 1500),
      'tipo', m.type,
      'quando', m.created_at
    ) || case when q.id is not null or m.reply_to_wa_id is not null then
      jsonb_build_object('responde_a', jsonb_build_object(
        'quem', case q.direction when 'in' then 'cliente' when 'out' then 'voce' else null end,
        'texto', left(coalesce(nullif(btrim(q.body), ''), case q.type when 'image' then '[imagem]' when 'document' then '[documento]' when 'audio' then '[áudio]' else null end, '(mensagem antiga fora do histórico)'), 400)
      ))
    else '{}'::jsonb end
    order by m.created_at), '[]'::jsonb)
  into v_hist
  from (
    select * from public.messages
    where conversation_id = p_conversation
      and (v_desde is null or created_at >= v_desde)
    order by created_at desc
    limit coalesce(v_cfg_n, 20)
  ) m
  left join public.messages q on q.conversation_id = m.conversation_id and q.wa_message_id = m.reply_to_wa_id and m.reply_to_wa_id is not null;

  return r || jsonb_build_object('historico', v_hist);
end
$f$;

revoke execute on function public.agente_contexto(uuid) from public, anon, authenticated;
grant execute on function public.agente_contexto(uuid) to service_role;
