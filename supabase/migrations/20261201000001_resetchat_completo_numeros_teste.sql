-- Fase 1: /resetchat apaga TODO o histórico do número (como cliente novo), só para números de teste. Aditiva e idempotente.
create table if not exists public.numeros_teste (
  telefone text primary key check (telefone ~ '^[0-9]{10,13}$'),
  apelido text,
  criado_em timestamptz not null default now(),
  criado_por uuid
);
alter table public.numeros_teste enable row level security;
drop policy if exists numeros_teste_ler on public.numeros_teste;
create policy numeros_teste_ler on public.numeros_teste for select to authenticated using (private.is_staff());
drop policy if exists numeros_teste_escrever on public.numeros_teste;
create policy numeros_teste_escrever on public.numeros_teste for all to authenticated using (private.is_admin()) with check (private.is_admin());
revoke all on public.numeros_teste from anon;
grant select, insert, update, delete on public.numeros_teste to authenticated;
insert into public.numeros_teste (telefone, apelido) values ('3132232356', 'Número de teste do dono') on conflict (telefone) do nothing;

create table if not exists public.reset_chat_auditoria (
  id uuid primary key default gen_random_uuid(),
  em timestamptz not null default now(),
  operador_id uuid,
  operador_nome text,
  telefone text,
  contact_id uuid,
  conversation_id uuid,
  resultado text not null,
  apagados jsonb not null default '{}'::jsonb
);
alter table public.reset_chat_auditoria enable row level security;
drop policy if exists reset_chat_auditoria_ler on public.reset_chat_auditoria;
create policy reset_chat_auditoria_ler on public.reset_chat_auditoria for select to authenticated using (private.is_staff());
revoke all on public.reset_chat_auditoria from anon;
grant select on public.reset_chat_auditoria to authenticated;

-- O telefone cadastrado (DDD + número, sem 55) bate com o final do wa_id
create or replace function private.eh_numero_teste(p_wa text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.numeros_teste t where right(regexp_replace(coalesce(p_wa, ''), '\D', '', 'g'), length(t.telefone)) = t.telefone)
$$;

create or replace function public.resetar_chat_completo(p_conversation uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_contact uuid; v_wa text; v_nome text; v_orders uuid[]; v_convs uuid[]; v_apagados jsonb := '{}'::jsonb; r record; n bigint;
begin
  if not private.is_staff() then raise exception 'sem_permissao'; end if;
  select c.contact_id, k.wa_id into v_contact, v_wa from public.conversations c join public.contacts k on k.id = c.contact_id where c.id = p_conversation;
  if v_contact is null then raise exception 'conversa_inexistente'; end if;
  select p.name into v_nome from public.profiles p where p.id = auth.uid();

  if not private.eh_numero_teste(v_wa) then
    insert into public.reset_chat_auditoria (operador_id, operador_nome, telefone, contact_id, conversation_id, resultado)
    values (auth.uid(), v_nome, v_wa, v_contact, p_conversation, 'recusado_nao_e_numero_de_teste');
    return jsonb_build_object('ok', false, 'erro', 'numero_nao_e_de_teste');
  end if;
  if exists (select 1 from public.orders o where o.contact_id = v_contact and (o.payment_status = 'aprovado' or o.stage in ('producao', 'prova', 'pronto', 'entregue')))
     or exists (select 1 from public.pagamentos pg join public.orders o on o.id = pg.order_id where o.contact_id = v_contact and pg.status = 'aprovado') then
    insert into public.reset_chat_auditoria (operador_id, operador_nome, telefone, contact_id, conversation_id, resultado)
    values (auth.uid(), v_nome, v_wa, v_contact, p_conversation, 'recusado_pedido_pago');
    return jsonb_build_object('ok', false, 'erro', 'tem_pedido_pago');
  end if;

  select coalesce(array_agg(id), '{}') into v_orders from public.orders where contact_id = v_contact;
  select coalesce(array_agg(id), '{}') into v_convs from public.conversations where contact_id = v_contact;

  -- 1) tudo que aponta para os pedidos (filhos primeiro)
  for r in select c.table_name, c.column_name from information_schema.columns c
            join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
           where c.table_schema = 'public' and c.column_name = 'order_id' and c.data_type = 'uuid'
             and c.table_name not in ('orders', 'orcamentos', 'reset_chat_auditoria') loop
    execute format('delete from public.%I where %I = any($1)', r.table_name, r.column_name) using v_orders;
    get diagnostics n = row_count;
    if n > 0 then v_apagados := v_apagados || jsonb_build_object(r.table_name, coalesce((v_apagados ->> r.table_name)::bigint, 0) + n); end if;
  end loop;
  -- 2) tudo que aponta para a conversa ou o contato (menos mensagens, orçamentos e pedidos, tratados depois)
  for r in select c.table_name, c.column_name from information_schema.columns c
            join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
           where c.table_schema = 'public' and c.column_name in ('conversation_id', 'contact_id') and c.data_type = 'uuid'
             and c.table_name not in ('orders', 'orcamentos', 'messages', 'conversations', 'contacts', 'reset_chat_auditoria') loop
    execute format('delete from public.%I where %I = any($1)', r.table_name, r.column_name) using (case when r.column_name = 'contact_id' then array[v_contact] else v_convs end);
    get diagnostics n = row_count;
    if n > 0 then v_apagados := v_apagados || jsonb_build_object(r.table_name, coalesce((v_apagados ->> r.table_name)::bigint, 0) + n); end if;
  end loop;
  delete from public.orcamentos where contact_id = v_contact or conversation_id = any (v_convs);
  get diagnostics n = row_count; v_apagados := v_apagados || jsonb_build_object('orcamentos', n);
  delete from public.orders where contact_id = v_contact;
  get diagnostics n = row_count; v_apagados := v_apagados || jsonb_build_object('orders', n);
  delete from public.messages where conversation_id = any (v_convs);
  get diagnostics n = row_count; v_apagados := v_apagados || jsonb_build_object('messages', n);

  -- 3) contato e conversa voltam ao estado de cliente novo (nome do WhatsApp e número ficam)
  update public.contacts set email = default, document = default, company = default, segment = default, address = default, bairro = default, cep = default,
    notes = default, tags = default, marketing_consent = default, marketing_consent_at = default, marketing_consent_source = default,
    first_referral = default, first_referral_at = default, status_lead = default, optout = default, origem_anuncio = default,
    urgente = default, urgente_motivo = default, urgente_em = default, tipo_pessoa = default, ie_indicador = default, inscricao_estadual = default,
    logradouro = default, numero = default, complemento = default, municipio = default, uf = default, codigo_ibge = default, bling_contact_id = default
  where id = v_contact;
  update public.conversations set status = default, stage = default, assigned_to = default, ai_handled = true, last_message_at = default, last_message_preview = default,
    last_inbound_at = default, unread_count = default, last_referral = default, attendant_changed_at = default, attendant_change_reason = default,
    needs_human = false, summary = default, collected_data = '{}'::jsonb, labels = default, ad_window_until = default, modo_atendimento = default,
    setor = default, contexto_desde = default, brain = '{}'::jsonb
  where contact_id = v_contact;

  insert into public.reset_chat_auditoria (operador_id, operador_nome, telefone, contact_id, conversation_id, resultado, apagados)
  values (auth.uid(), v_nome, v_wa, v_contact, p_conversation, 'ok', v_apagados);
  return jsonb_build_object('ok', true, 'apagados', v_apagados);
end $$;
revoke execute on function public.resetar_chat_completo(uuid) from public, anon;
grant execute on function public.resetar_chat_completo(uuid) to authenticated;
