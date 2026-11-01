-- Etapa 8B: infraestrutura do teste ponta a ponta do atendimento (aditiva e idempotente).
-- 1) contacts.is_teste: marca contatos de teste (a limpeza só apaga quem tem a flag).
-- 2) e2e_mensagens: o que o simulador "enviaria" ao cliente (nada vai ao WhatsApp), por rodada, cenário e turno.
-- 3) agente_teste_preparar aceita continuar uma conversa de teste (conversas de vários turnos) e grava a flag.
-- 4) e2e_limpar: apaga somente o que tem a flag, inclusive o que poluiria o aprendizado de preços.

alter table public.contacts add column if not exists is_teste boolean not null default false;
create index if not exists contacts_is_teste_idx on public.contacts (is_teste) where is_teste;
update public.contacts set is_teste = true where 'teste' = any (tags) and not is_teste;

create table if not exists public.e2e_mensagens (
  id uuid primary key default gen_random_uuid(),
  rodada text not null,
  cenario text not null,
  formulacao int not null default 1,
  turno int not null default 1,
  direcao text not null check (direcao in ('cliente', 'agente')),
  texto text not null,
  contact_id uuid,
  conversation_id uuid,
  ferramentas text[] not null default '{}',
  tokens int,
  custo numeric,
  criado_em timestamptz not null default now()
);
create index if not exists e2e_mensagens_rodada_idx on public.e2e_mensagens (rodada, cenario, formulacao, turno);
alter table public.e2e_mensagens enable row level security;
-- sem políticas: só a service role (e o dono pelo MCP) lê e grava.
revoke all on public.e2e_mensagens from anon, authenticated;

-- Preparar um caso. Novidades de 8B (casos antigos se comportam como antes):
--   entradas.continuar_conversation: reaproveita a conversa de teste (mesmo contato, orçamentos e pedidos) e só acrescenta mensagens do cliente;
--   entradas.nome ganha o prefixo TESTE_ e o contato recebe is_teste = true.
create or replace function public.agente_teste_preparar(p_caso uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  c record;
  v_wa text := '550000' || lpad((floor(random() * 100000000))::bigint::text, 8, '0');
  v_contact uuid;
  v_conv uuid;
  v_cont uuid := nullif(
    (select entradas ->> 'continuar_conversation' from public.testes_conversa where id = p_caso), '')::uuid;
  v_msg jsonb;
  v_ids uuid[] := '{}';
  v_id uuid;
  v_prep text;
  v_orc jsonb;
  v_ord uuid;
  v_i int := 0;
  v_nome text;
begin
  select * into c from public.testes_conversa where id = p_caso;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'caso_inexistente'); end if;

  if v_cont is not null then
    select cv.contact_id, ct.wa_id into v_contact, v_wa
      from public.conversations cv join public.contacts ct on ct.id = cv.contact_id
     where cv.id = v_cont and ct.is_teste;
    if v_contact is null then return jsonb_build_object('ok', false, 'motivo', 'conversa_nao_e_de_teste'); end if;
    v_conv := v_cont;
  else
    v_nome := nullif(c.entradas ->> 'nome', '');
    if v_nome is not null and v_nome !~ '^TESTE_' then v_nome := 'TESTE_' || v_nome; end if;
    insert into public.contacts (wa_id, name, tags, is_teste, first_referral, first_referral_at)
    values (v_wa, coalesce(v_nome, 'TESTE_' || v_wa), array['teste'], true, nullif(c.entradas -> 'anuncio', 'null'::jsonb), case when c.entradas ? 'anuncio' then now() end)
    returning id into v_contact;
    insert into public.conversations (contact_id, last_referral, ai_handled, modo_atendimento)
    values (v_contact, nullif(c.entradas -> 'anuncio', 'null'::jsonb), true, 'ia') returning id into v_conv;
  end if;

  for v_prep in select jsonb_array_elements_text(coalesce(c.entradas -> 'preparar', '[]'::jsonb)) loop
    if v_prep = 'modo_humano' then
      update public.conversations set modo_atendimento = 'humano', ai_handled = false, attendant_changed_at = now(), attendant_change_reason = 'Assumido pelo dono' where id = v_conv;
    elsif v_prep in ('orcamento_aberto', 'condicao_expirada') then
      v_orc := public.montar_orcamento(v_contact, '[{"sku":"CFV02","quantidade":1}]'::jsonb,
        jsonb_build_object('conversation_id', v_conv, 'teste', true, 'bairro', 'Centro', 'arte', 'nenhuma'));
      if (v_orc ->> 'orcamento_id') is not null then perform public.orcamento_marcar_enviado((v_orc ->> 'orcamento_id')::uuid); end if;
      if v_prep = 'condicao_expirada' and (v_orc ->> 'orcamento_id') is not null then
        insert into public.condicoes_especiais (orcamento_id, contact_id, degrau, gatilho, tipo, valor, texto_curto, valida_ate, resultado)
        values ((v_orc ->> 'orcamento_id')::uuid, v_contact, 2, 'G1', 'desconto', 5, 'condição de teste expirada', now() - interval '2 hours', 'expirada');
      end if;
    elsif v_prep = 'pedido_pago' then
      insert into public.orders (contact_id, conversation_id, title) values (v_contact, v_conv, 'Pedido de teste') returning id into v_ord;
      update public.orders set payment_status = 'aprovado', stage = 'pago' where id = v_ord;
    elsif v_prep = 'optout' then
      update public.contacts set marketing_consent = 'opted_out', marketing_consent_at = now(), marketing_consent_source = 'whatsapp' where id = v_contact; -- optout é coluna gerada
    elsif v_prep like 'falha_ferramenta:%' then
      update public.conversations set collected_data = coalesce(collected_data, '{}'::jsonb) || jsonb_build_object('teste_falha', split_part(v_prep, ':', 2)) where id = v_conv;
    elsif v_prep = 'sem_falha' then
      update public.conversations set collected_data = coalesce(collected_data, '{}'::jsonb) - 'teste_falha' where id = v_conv;
    end if;
  end loop;

  for v_msg in select * from jsonb_array_elements(coalesce(c.entradas -> 'mensagens', '[]'::jsonb)) loop
    v_i := v_i + 1;
    insert into public.messages (conversation_id, wa_message_id, direction, type, body, media_id, created_at)
    values (v_conv, 'teste.' || v_wa || '.' || replace(gen_random_uuid()::text, '-', ''), 'in', coalesce(v_msg ->> 'tipo', 'text'), nullif(v_msg ->> 'texto', ''),
            case when coalesce(v_msg ->> 'tipo', 'text') in ('audio', 'image', 'document') then 'teste' end, now() + make_interval(secs => v_i))
    returning id into v_id;
    v_ids := array_append(v_ids, v_id);
  end loop;
  update public.conversations set last_inbound_at = now() + make_interval(secs => v_i), last_message_at = now() + make_interval(secs => v_i), status = 'open' where id = v_conv;

  update public.testes_conversa set ultimo_resultado = jsonb_build_object('contact_id', v_contact, 'conversation_id', v_conv, 'saidas', '[]'::jsonb), ultimo_status = null, executado_em = now() where id = p_caso;
  return jsonb_build_object('ok', true, 'contact_id', v_contact, 'conversation_id', v_conv, 'message_ids', to_jsonb(v_ids), 'ultima_mensagem', v_ids[array_length(v_ids, 1)]);
end;
$$;

-- Limpeza: apaga SOMENTE contatos com is_teste = true (e o que depende deles). O agente pode renomear o contato, então o padrão não filtra por nome.
create or replace function public.e2e_limpar(p_prefixo text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ids uuid[];
  v_conv uuid[];
  v_n int;
begin
  select coalesce(array_agg(id), '{}') into v_ids from public.contacts where is_teste and (p_prefixo is null or coalesce(name, '') like p_prefixo || '%');
  if array_length(v_ids, 1) is null then return jsonb_build_object('ok', true, 'contatos', 0); end if;
  select coalesce(array_agg(id), '{}') into v_conv from public.conversations where contact_id = any (v_ids);
  delete from public.alertas where contact_id = any (v_ids) or conversation_id = any (v_conv);
  delete from public.agent_logs where conversation_id = any (v_conv);
  delete from public.itens_fora_catalogo where contact_id = any (v_ids) or conversation_id = any (v_conv);
  delete from public.produto_fotos_envios where contact_id = any (v_ids) or conversation_id = any (v_conv);
  delete from public.precos_praticados where contact_id = any (v_ids);
  delete from public.condicoes_especiais where contact_id = any (v_ids);
  delete from public.orcamentos where contact_id = any (v_ids);
  delete from public.followup_fila where contact_id = any (v_ids);
  delete from public.orders where contact_id = any (v_ids);
  delete from public.contacts where id = any (v_ids) and is_teste;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'contatos', v_n);
end;
$$;

revoke execute on function public.e2e_limpar(text) from public, anon, authenticated;
grant execute on function public.e2e_limpar(text) to service_role;
