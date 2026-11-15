-- Apagar conversa e apagar contato no CRM (só admin, com auditoria). Pedido pago nunca é apagado.
-- Quem pediu para parar de receber promoções continua na lista de supressão (o telefone fica guardado) mesmo com o contato apagado.
-- Aditiva e idempotente.
create table if not exists public.exclusoes_auditoria (
  id uuid primary key default gen_random_uuid(),
  operador_id uuid,
  operador_nome text,
  tipo text not null check (tipo in ('conversa', 'contato')),
  telefone text,
  nome text,
  motivo text,
  resultado text not null,
  apagados jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now()
);
alter table public.exclusoes_auditoria enable row level security;
drop policy if exists exclusoes_auditoria_admin_le on public.exclusoes_auditoria;
create policy exclusoes_auditoria_admin_le on public.exclusoes_auditoria for select to authenticated using (private.is_admin());

-- Apaga tudo o que depende do contato (mesma lógica do /resetchat) e, conforme pedido, a conversa e o contato.
create or replace function private.apagar_dados_do_contato(p_contact uuid, p_apagar_contato boolean)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_orders uuid[]; v_convs uuid[]; v_ap jsonb := '{}'::jsonb; r record; n bigint;
begin
  select coalesce(array_agg(id), '{}') into v_orders from public.orders where contact_id = p_contact;
  select coalesce(array_agg(id), '{}') into v_convs from public.conversations where contact_id = p_contact;
  for r in select c.table_name, c.column_name from information_schema.columns c
            join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
           where c.table_schema = 'public' and c.column_name = 'order_id' and c.data_type = 'uuid'
             and c.table_name not in ('orders', 'orcamentos', 'reset_chat_auditoria', 'exclusoes_auditoria') loop
    execute format('delete from public.%I where %I = any($1)', r.table_name, r.column_name) using v_orders;
    get diagnostics n = row_count;
    if n > 0 then v_ap := v_ap || jsonb_build_object(r.table_name, coalesce((v_ap ->> r.table_name)::bigint, 0) + n); end if;
  end loop;
  for r in select c.table_name, c.column_name from information_schema.columns c
            join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
           where c.table_schema = 'public' and c.column_name in ('conversation_id', 'contact_id') and c.data_type = 'uuid'
             and c.table_name not in ('orders', 'orcamentos', 'messages', 'conversations', 'contacts', 'reset_chat_auditoria', 'exclusoes_auditoria') loop
    execute format('delete from public.%I where %I = any($1)', r.table_name, r.column_name) using (case when r.column_name = 'contact_id' then array[p_contact] else v_convs end);
    get diagnostics n = row_count;
    if n > 0 then v_ap := v_ap || jsonb_build_object(r.table_name, coalesce((v_ap ->> r.table_name)::bigint, 0) + n); end if;
  end loop;
  delete from public.orcamentos where contact_id = p_contact or conversation_id = any (v_convs);
  get diagnostics n = row_count; v_ap := v_ap || jsonb_build_object('orcamentos', n);
  delete from public.orders where contact_id = p_contact;
  get diagnostics n = row_count; v_ap := v_ap || jsonb_build_object('orders', n);
  delete from public.messages where conversation_id = any (v_convs);
  get diagnostics n = row_count; v_ap := v_ap || jsonb_build_object('messages', n);
  delete from public.conversations where contact_id = p_contact;
  if p_apagar_contato then
    delete from public.contacts where id = p_contact;
    v_ap := v_ap || jsonb_build_object('contacts', 1);
  end if;
  return v_ap;
end $$;
revoke execute on function private.apagar_dados_do_contato(uuid, boolean) from public, anon, authenticated;

create or replace function private.excluir_contato_core(p_contact uuid, p_tipo text, p_motivo text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_wa text; v_nome text; v_op text; v_ap jsonb; v_consent text;
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  select wa_id, name, marketing_consent into v_wa, v_nome, v_consent from public.contacts where id = p_contact;
  if v_wa is null then return jsonb_build_object('ok', false, 'erro', 'contato_inexistente'); end if;
  select p.name into v_op from public.profiles p where p.id = auth.uid();
  if exists (select 1 from public.orders o where o.contact_id = p_contact and (o.payment_status = 'aprovado' or o.stage in ('producao', 'prova', 'pronto', 'entregue')))
     or exists (select 1 from public.pagamentos pg join public.orders o on o.id = pg.order_id where o.contact_id = p_contact and pg.status = 'aprovado') then
    insert into public.exclusoes_auditoria (operador_id, operador_nome, tipo, telefone, nome, motivo, resultado) values (auth.uid(), v_op, p_tipo, v_wa, v_nome, p_motivo, 'recusado_pedido_pago');
    return jsonb_build_object('ok', false, 'erro', 'tem_pedido_pago');
  end if;
  if p_tipo = 'contato' and v_consent = 'opted_out' then
    insert into public.marketing_suppressions (wa_id) values (v_wa) on conflict do nothing;
  end if;
  v_ap := private.apagar_dados_do_contato(p_contact, p_tipo = 'contato');
  insert into public.exclusoes_auditoria (operador_id, operador_nome, tipo, telefone, nome, motivo, resultado, apagados) values (auth.uid(), v_op, p_tipo, v_wa, v_nome, p_motivo, 'ok', v_ap);
  return jsonb_build_object('ok', true, 'apagados', v_ap);
end $$;
revoke execute on function private.excluir_contato_core(uuid, text, text) from public, anon, authenticated;

create or replace function public.excluir_conversa(p_conversation uuid, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_contact uuid;
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  select contact_id into v_contact from public.conversations where id = p_conversation;
  if v_contact is null then return jsonb_build_object('ok', false, 'erro', 'conversa_inexistente'); end if;
  return private.excluir_contato_core(v_contact, 'conversa', p_motivo);
end $$;

create or replace function public.excluir_contato(p_contact uuid, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  return private.excluir_contato_core(p_contact, 'contato', p_motivo);
end $$;

revoke execute on function public.excluir_conversa(uuid, text), public.excluir_contato(uuid, text) from public, anon;
grant execute on function public.excluir_conversa(uuid, text), public.excluir_contato(uuid, text) to authenticated;
