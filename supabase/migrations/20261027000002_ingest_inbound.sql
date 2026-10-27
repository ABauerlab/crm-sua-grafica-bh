-- Gravação atômica de mensagem recebida (chamada só pela Edge Function com service role)
create function public.ingest_inbound_message(
  p_wa_id text,
  p_name text,
  p_wa_message_id text,
  p_type text,
  p_body text,
  p_media_id text,
  p_ts timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contact_id uuid;
  v_conv_id uuid;
  v_msg_id uuid;
begin
  insert into public.contacts (wa_id, name)
  values (p_wa_id, nullif(p_name, ''))
  on conflict (wa_id) do update
    set name = coalesce(public.contacts.name, excluded.name)
  returning id into v_contact_id;

  insert into public.conversations (contact_id)
  values (v_contact_id)
  on conflict (contact_id) do nothing;

  select id into v_conv_id from public.conversations where contact_id = v_contact_id;

  insert into public.messages (conversation_id, wa_message_id, direction, type, body, media_id, created_at)
  values (v_conv_id, p_wa_message_id, 'in', p_type, p_body, p_media_id, p_ts)
  on conflict (wa_message_id) do nothing
  returning id into v_msg_id;

  -- mensagem duplicada: não mexe em contadores
  if v_msg_id is null then
    return null;
  end if;

  update public.conversations
  set status = 'open',
      last_inbound_at = greatest(coalesce(last_inbound_at, p_ts), p_ts),
      last_message_at = greatest(coalesce(last_message_at, p_ts), p_ts),
      last_message_preview = left(coalesce(p_body, ''), 120),
      unread_count = unread_count + 1
  where id = v_conv_id;

  return v_msg_id;
end;
$$;

revoke execute on function public.ingest_inbound_message(text, text, text, text, text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.ingest_inbound_message(text, text, text, text, text, text, timestamptz)
  to service_role;
