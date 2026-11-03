-- Conversa completa como no WhatsApp: todos os tipos de mensagem, resposta a uma mensagem, reações, dados da mensagem e apagar no CRM.
-- Aditiva e idempotente.
-- A API oficial do WhatsApp NÃO permite apagar nem editar o que já foi entregue ao cliente: "apagar" aqui esconde a mensagem no CRM
-- (deleted_at), reversível, e o cliente continua vendo a dele.

alter table public.messages add column if not exists reply_to_wa_id text;      -- mensagem a que esta responde (context.id da Meta)
alter table public.messages add column if not exists raw_type text;            -- tipo original informado pela Meta
alter table public.messages add column if not exists meta jsonb;               -- nome do arquivo, formato, local, contatos, reação etc.
alter table public.messages add column if not exists forwarded boolean not null default false;
alter table public.messages add column if not exists sent_by uuid;             -- atendente que enviou pelo CRM
alter table public.messages add column if not exists deleted_at timestamptz;
alter table public.messages add column if not exists deleted_by uuid;

create index if not exists messages_reply_to_idx on public.messages (reply_to_wa_id) where reply_to_wa_id is not null;
create index if not exists messages_wa_message_id_idx on public.messages (wa_message_id) where wa_message_id is not null;

-- novos tipos aceitos
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.messages'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%''template''%' loop
    execute format('alter table public.messages drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'messages_type_check_v2') then
    alter table public.messages add constraint messages_type_check_v2
      check (type in ('text', 'image', 'document', 'audio', 'video', 'sticker', 'location', 'contacts', 'reaction', 'template', 'other'));
  end if;
end $$;
