-- Etapa 7C, parte 3: duas personas (Laura e João Victor) e o setor de arte, onde o dono assume.
-- Laura e João Victor são NOMES de um só assistente virtual. A fase é decidida pelo estado do pedido, nunca pelo modelo.
-- Antes do pagamento: Laura. Pagamento confirmado: João Victor (automático). O dono só entra quando o pedido chega ao setor de arte.
-- Chave de segurança: app_settings.personas.pos_pagamento_automatico = false volta ao comportamento antigo (o agente PARA depois do pagamento).
-- Aditiva e idempotente.

-- ---------------------------------------------------------------- 1. colunas
alter table public.orders add column if not exists arte_fila_em timestamptz;
alter table public.orders add column if not exists arte_qualidade text check (arte_qualidade is null or arte_qualidade in ('ok', 'baixa', 'indefinida', 'briefing'));
alter table public.orders add column if not exists arte_baixa_ok_em timestamptz;
alter table public.orders add column if not exists arte_resumo jsonb;
alter table public.orders add column if not exists arte_ultimo_alerta_em timestamptz;
alter table public.orders add column if not exists arte_aprovada_registro jsonb;
alter table public.order_files add column if not exists qualidade text check (qualidade is null or qualidade in ('ok', 'baixa', 'indefinida'));
create index if not exists orders_arte_fila_idx on public.orders (arte_fila_em) where arte_fila_em is not null and art_status <> 'aprovada';

-- ---------------------------------------------------------------- 2. fase e persona
create or replace function private.persona_cfg() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('vendas', 'Laura', 'pos_pagamento', 'João Victor', 'artigo_vendas', 'a', 'artigo_pos_pagamento', 'o', 'apresentacao', 'assistente virtual da Sua Gráfica BH', 'pos_pagamento_automatico', true)
         || coalesce((select value from public.app_settings where key = 'personas'), '{}'::jsonb);
$$;
revoke execute on function private.persona_cfg() from public, anon, authenticated;

-- pos_pagamento = há pedido pago em andamento (pago, arte, prova ou produção); senão vendas
create or replace function private.agente_fase(p_contact uuid) returns text
language sql stable security definer set search_path = ''
as $$
  select case when exists (
    select 1 from public.orders o
     where o.contact_id = p_contact and o.excluido_em is null and o.stage in ('pago', 'arte', 'prova', 'producao')
       and (o.payment_status = 'aprovado' or o.payment_manual)) then 'pos_pagamento' else 'vendas' end;
$$;
revoke execute on function private.agente_fase(uuid) from public, anon, authenticated;

create or replace function public.agente_persona(p_conversation uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_contact uuid; v_cfg jsonb := private.persona_cfg(); v_fase text; v_nome text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select contact_id into v_contact from public.conversations where id = p_conversation;
  v_fase := case when v_contact is null then 'vendas' else private.agente_fase(v_contact) end;
  v_nome := case when v_fase = 'pos_pagamento' then v_cfg ->> 'pos_pagamento' else v_cfg ->> 'vendas' end;
  return jsonb_build_object('fase', v_fase, 'nome', v_nome, 'apresentacao', v_nome || ', ' || (v_cfg ->> 'apresentacao'),
    'automatico_pos_pagamento', coalesce((v_cfg ->> 'pos_pagamento_automatico')::boolean, true));
end;
$$;
revoke execute on function public.agente_persona(uuid) from public, anon, authenticated;
grant execute on function public.agente_persona(uuid) to service_role;

-- Contexto, entrada e mensagem de pós-pagamento passam a carregar a persona (embrulhando as funções existentes, sem copiar o corpo delas)
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'agente_contexto_base' and pronamespace = 'public'::regnamespace) then
    alter function public.agente_contexto(uuid) rename to agente_contexto_base;
  end if;
  if not exists (select 1 from pg_proc where proname = 'agente_entrada_base' and pronamespace = 'public'::regnamespace) then
    alter function public.agente_entrada(uuid, boolean) rename to agente_entrada_base;
  end if;
  if not exists (select 1 from pg_proc where proname = 'pagamento_pos_reservar_msg_base' and pronamespace = 'public'::regnamespace) then
    alter function public.pagamento_pos_reservar_msg(uuid) rename to pagamento_pos_reservar_msg_base;
  end if;
  if not exists (select 1 from pg_proc where proname = 'pagamento_pos_processar_base' and pronamespace = 'public'::regnamespace) then
    alter function public.pagamento_pos_processar(uuid) rename to pagamento_pos_processar_base;
  end if;
end $$;

create or replace function public.agente_contexto(p_conversation uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare r jsonb; p jsonb;
begin
  r := public.agente_contexto_base(p_conversation);
  if r ? 'erro' then return r; end if;
  p := public.agente_persona(p_conversation);
  return r || jsonb_build_object('persona', p, 'nome_atendente', p ->> 'nome', 'fase', p ->> 'fase');
end;
$$;
revoke execute on function public.agente_contexto(uuid) from public, anon, authenticated;
grant execute on function public.agente_contexto(uuid) to service_role;

create or replace function public.agente_entrada(p_message uuid, p_teste boolean default false) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r jsonb; p jsonb;
begin
  r := public.agente_entrada_base(p_message, p_teste);
  if coalesce((r ->> 'processar')::boolean, false) and r ->> 'conversation_id' is not null then
    p := public.agente_persona((r ->> 'conversation_id')::uuid);
    r := r || jsonb_build_object('persona', p, 'nome_atendente', p ->> 'nome', 'fase', p ->> 'fase');
  end if;
  return r;
end;
$$;
revoke execute on function public.agente_entrada(uuid, boolean) from public, anon, authenticated;
grant execute on function public.agente_entrada(uuid, boolean) to service_role;

create or replace function public.pagamento_pos_reservar_msg(p_order uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r jsonb;
begin
  r := public.pagamento_pos_reservar_msg_base(p_order);
  if coalesce((r ->> 'enviar')::boolean, false) then
    r := r || jsonb_build_object('persona', private.persona_cfg() ->> 'pos_pagamento', 'artigo', private.persona_cfg() ->> 'artigo_pos_pagamento', 'apresentacao', private.persona_cfg() ->> 'apresentacao');
  end if;
  return r;
end;
$$;
revoke execute on function public.pagamento_pos_reservar_msg(uuid) from public, anon, authenticated;
grant execute on function public.pagamento_pos_reservar_msg(uuid) to service_role;

-- Depois do pagamento a conversa NÃO fica mais em modo humano (se a IA estava atendendo): quem atende é o João Victor, até chegar ao setor de arte.
create or replace function public.pagamento_pos_processar(p_evento uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r jsonb; v_conv uuid; v_modo text; v_motivo text;
begin
  select o.conversation_id into v_conv from public.eventos_pagamento e join public.orders o on o.id = e.order_id where e.id = p_evento;
  select modo_atendimento, attendant_change_reason into v_modo, v_motivo from public.conversations where id = v_conv;
  r := public.pagamento_pos_processar_base(p_evento);
  if v_conv is not null and not coalesce((r ->> 'ja_processado')::boolean, false)
     and coalesce((private.persona_cfg() ->> 'pos_pagamento_automatico')::boolean, true)
     and coalesce(v_modo, 'ia') = 'ia' and coalesce(v_motivo, '') <> 'Assumido pelo dono' then
    update public.conversations set modo_atendimento = 'ia', needs_human = false where id = v_conv;
  end if;
  return r;
end;
$$;
revoke execute on function public.pagamento_pos_processar(uuid) from public, anon, authenticated;
grant execute on function public.pagamento_pos_processar(uuid) to service_role;

-- ---------------------------------------------------------------- 3. quando o agente pode falar
-- Antes: pedido em andamento = agente parado. Agora (automático): o agente segue como João Victor e só PARA quando o dono precisa agir (setor de arte ou dono).
create or replace function public.agente_bloqueio(p_conversation uuid) returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  cfg record; v_global boolean; v_conv record; v_hora time; v_dow int; v_dias jsonb;
  v_auto boolean := coalesce((private.persona_cfg() ->> 'pos_pagamento_automatico')::boolean, true);
begin
  select * into cfg from public.agente_config where id = 1;
  select coalesce((value ->> 'enabled')::boolean, false) into v_global from public.app_settings where key = 'agent';
  if not coalesce(cfg.ia_ligada, false) or not coalesce(v_global, false) then return 'ia_pausada'; end if;

  if not coalesce(cfg.atende_24h, true) then
    v_hora := (now() at time zone 'America/Sao_Paulo')::time;
    v_dow := extract(dow from now() at time zone 'America/Sao_Paulo')::int;
    v_dias := coalesce(cfg.horario_ia -> 'dias', '[0,1,2,3,4,5,6]'::jsonb);
    if not (v_dias @> to_jsonb(v_dow)) or v_hora < coalesce((cfg.horario_ia ->> 'inicio')::time, '00:00'::time)
       or v_hora > coalesce((cfg.horario_ia ->> 'fim')::time, '23:59'::time) then
      return 'fora_do_horario';
    end if;
  end if;

  select cv.contact_id, cv.modo_atendimento, cv.ai_handled, cv.setor, ct.optout, ct.wa_id into v_conv
  from public.conversations cv join public.contacts ct on ct.id = cv.contact_id where cv.id = p_conversation;
  if not found then return 'conversa_inexistente'; end if;
  if v_conv.wa_id is not distinct from cfg.whatsapp_dono then return 'numero_do_dono'; end if;
  if coalesce(v_conv.optout, false) then return 'optout'; end if;
  if coalesce(v_conv.modo_atendimento, 'ia') <> 'ia' or not coalesce(v_conv.ai_handled, true) then return 'modo_humano'; end if;

  if exists (select 1 from public.orders o where o.contact_id = v_conv.contact_id and o.excluido_em is null and o.stage in ('pago', 'arte', 'prova', 'producao')) then
    if not v_auto then return 'pedido_pago'; end if;
    if v_conv.setor in ('arte', 'dono') or exists (
         select 1 from public.orders o where o.contact_id = v_conv.contact_id and o.excluido_em is null and o.stage in ('arte', 'prova')) then
      return 'aguardando_dono';
    end if;
  end if;
  return null;
end;
$$;
revoke execute on function public.agente_bloqueio(uuid) from public, anon, authenticated;
grant execute on function public.agente_bloqueio(uuid) to service_role;

-- ---------------------------------------------------------------- 4. setor de arte
-- Resumo pronto para o dono agir (sem custo, margem, piso, fornecedor nem SKU)
create or replace function private.arte_resumo(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_itens jsonb; v_prev date; ct public.contacts%rowtype; cv public.conversations%rowtype;
begin
  select * into o from public.orders where id = p_order;
  if not found then return null; end if;
  select * into ct from public.contacts where id = o.contact_id;
  select * into cv from public.conversations where id = o.conversation_id;
  select coalesce(jsonb_agg(jsonb_build_object('produto', left(i.description, 120), 'quantidade', i.qty) order by i.created_at), '[]'::jsonb) into v_itens
    from public.order_items i where i.order_id = p_order;
  select max(q.data_prevista) into v_prev from public.orcamentos q where q.order_id = p_order;
  return jsonb_build_object(
    'pedido', 'SG-' || lpad(o.number::text, 4, '0'),
    'cliente', coalesce(nullif(split_part(trim(coalesce(ct.name, '')), ' ', 1), ''), 'cliente'),
    'itens', v_itens,
    'prazo_prometido', to_char(coalesce(v_prev, o.due_date), 'DD/MM/YYYY'),
    'entrega', case o.delivery_method when 'uber' then 'entrega (Uber, por conta do cliente)' when 'retirada' then 'retirada' else 'a combinar' end,
    'observacoes', nullif(left(coalesce(cv.summary, ''), 400), ''),
    'qualidade_do_arquivo', coalesce(o.arte_qualidade, 'indefinida'),
    'baixa_qualidade_com_ok_do_cliente', o.arte_baixa_ok_em is not null,
    'urgente', o.urgente);
end;
$$;
revoke execute on function private.arte_resumo(uuid) from public, anon, authenticated;

-- Chamada pelo agente (n8n) quando o cliente manda arquivo ou briefing DEPOIS de pagar: o pedido vai para a fila da arte e o dono é avisado.
create or replace function public.arte_receber(p_conversation uuid, p_tipo text, p_qualidade text default null, p_detalhe text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  cv public.conversations%rowtype; o public.orders%rowtype; cfg jsonb; v_q text; v_pior text; v_horas integer; v_res jsonb; v_ref text; v_al jsonb; v_baixa_tipos jsonb;
  v_tipo text := lower(trim(coalesce(p_tipo, 'arquivo')));
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into cv from public.conversations where id = p_conversation;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'conversa_inexistente'); end if;
  select * into o from public.orders x
   where x.contact_id = cv.contact_id and x.excluido_em is null and x.stage in ('pago', 'arte', 'prova') and (x.payment_status = 'aprovado' or x.payment_manual)
   order by x.created_at desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'sem_pedido_pago', 'orientacao', 'Ainda não há pedido pago. Peça o arquivo só depois do pagamento.'); end if;
  select value into cfg from public.app_settings where key = 'arte';
  v_baixa_tipos := coalesce(cfg -> 'tipos_baixa_qualidade', '["imagem_whatsapp","print","foto","imagem_pequena"]'::jsonb);
  v_q := case
    when lower(coalesce(p_qualidade, '')) in ('ok', 'baixa', 'indefinida') then lower(p_qualidade)
    when v_tipo = 'briefing' then 'briefing'
    when v_baixa_tipos ? v_tipo then 'baixa'
    else 'indefinida' end;
  -- guarda a pior qualidade já vista no pedido
  v_pior := case
    when 'baixa' in (v_q, coalesce(o.arte_qualidade, '')) then 'baixa'
    when 'indefinida' in (v_q, coalesce(o.arte_qualidade, '')) then 'indefinida'
    when 'ok' in (v_q, coalesce(o.arte_qualidade, '')) then 'ok'
    else v_q end;
  v_horas := coalesce((cfg ->> 'horas_novo_alerta')::integer, 4);

  update public.orders set arte_qualidade = v_pior, arte_fila_em = coalesce(arte_fila_em, now()),
         stage = case when stage = 'pago' then 'arte' else stage end,
         art_status = case when art_status in ('aguardando', 'ajuste') then 'em_criacao' else art_status end
   where id = o.id;
  v_res := private.arte_resumo(o.id);
  update public.orders set arte_resumo = v_res where id = o.id;
  update public.conversations set setor = 'arte', needs_human = true where id = p_conversation;
  insert into public.order_events (order_id, kind, message) values (o.id, 'art', 'Arte recebida (' || v_tipo || ', qualidade ' || v_pior || '): pedido na fila da arte');

  if not exists (select 1 from public.tasks where order_id = o.id and setor = 'arte' and done_at is null) then
    insert into public.tasks (title, contact_id, order_id, kind, priority, setor, due_at)
    values ('Arte ' || (v_res ->> 'pedido') || ': conferir arquivo (' || v_pior || ')', cv.contact_id, o.id, 'aprovar_prova', case when o.urgente then 'alta' else 'media' end, 'arte', now() + make_interval(hours => v_horas));
  end if;

  v_ref := v_res ->> 'pedido';
  v_al := public.alerta_criar('arte_recebida', 'alta', cv.contact_id, p_conversation, o.id,
    left(format('Arte do pedido %s. %s. Prazo prometido %s, %s. Qualidade: %s.%s Abra a Fila da arte.', v_ref,
      (select string_agg((e ->> 'produto') || ' x' || (e ->> 'quantidade'), ', ') from jsonb_array_elements(v_res -> 'itens') e),
      v_res ->> 'prazo_prometido', v_res ->> 'entrega', v_pior, case when o.urgente then ' URGENTE.' else '' end), 300),
    jsonb_build_object('setor', 'arte', 'resumo', v_res, 'detalhe', left(coalesce(p_detalhe, ''), 300)),
    'arte_fila:' || o.id::text);
  if v_al ->> 'alerta_id' is not null then update public.alertas set setor = 'arte' where id = (v_al ->> 'alerta_id')::uuid; end if;
  return jsonb_build_object('ok', true, 'pedido', v_ref, 'qualidade', v_pior, 'na_fila', true,
    'baixa_qualidade', v_pior = 'baixa',
    'orientacao', case when v_pior = 'baixa'
      then 'Avise que o arquivo está com qualidade baixa, sugira o PDF em alta qualidade ou a criação da arte, e se o cliente decidir seguir mesmo assim chame arte_baixa_ok.'
      else 'Diga que recebeu e que a equipe vai conferir e mandar a arte para aprovar. Não prometa data nova nem diga que a arte está aprovada.' end);
end;
$$;
revoke execute on function public.arte_receber(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.arte_receber(uuid, text, text, text) to service_role;

-- O cliente decidiu seguir mesmo com a baixa qualidade: registra o ok com data e hora
create or replace function public.arte_baixa_ok(p_conversation uuid, p_texto text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select x.* into o from public.orders x join public.conversations c on c.contact_id = x.contact_id
   where c.id = p_conversation and x.excluido_em is null and x.arte_qualidade = 'baixa' and x.art_status <> 'aprovada' order by x.created_at desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'sem_arte_de_baixa_qualidade'); end if;
  update public.orders set arte_baixa_ok_em = coalesce(arte_baixa_ok_em, now()) where id = o.id;
  insert into public.order_events (order_id, kind, message) values (o.id, 'art', 'Cliente confirmou seguir com a arte de baixa qualidade' || case when p_texto is null then '' else ': ' || left(p_texto, 200) end);
  return jsonb_build_object('ok', true, 'registrado', true);
end;
$$;
revoke execute on function public.arte_baixa_ok(uuid, text) from public, anon, authenticated;
grant execute on function public.arte_baixa_ok(uuid, text) to service_role;

-- O dono marca "arte aprovada pelo cliente": registra o ok com data e hora, o prazo começa a contar daqui, o pedido entra em produção e a automação volta
create or replace function public.arte_aprovar(p_order uuid, p_cliente_confirmou boolean default false, p_arte_refeita boolean default false, p_observacao text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_aviso text; v_quando timestamptz := now(); v_cfg jsonb := private.persona_cfg(); v_prev date;
begin
  if not private.is_staff() and coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orders where id = p_order and excluido_em is null;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'pedido_inexistente'); end if;
  if o.payment_status <> 'aprovado' and not o.payment_manual then return jsonb_build_object('ok', false, 'motivo', 'pedido_nao_pago'); end if;
  if o.art_status = 'aprovada' then return jsonb_build_object('ok', true, 'ja_aprovada', true); end if;
  if not p_cliente_confirmou then return jsonb_build_object('ok', false, 'motivo', 'confirmacao_do_cliente_obrigatoria', 'orientacao', 'Só marque depois de o cliente confirmar texto, cores e imagens.'); end if;
  if o.arte_qualidade = 'baixa' and o.arte_baixa_ok_em is null and not p_arte_refeita then
    return jsonb_build_object('ok', false, 'motivo', 'baixa_qualidade_sem_ok_do_cliente', 'orientacao', 'Arquivo de baixa qualidade: peça o ok do cliente para seguir, ou marque que a arte foi refeita.');
  end if;

  update public.orders set art_status = 'aprovada', arte_aprovada_registro = jsonb_build_object(
      'quando', v_quando, 'por', coalesce(auth.uid()::text, 'servico'), 'cliente_confirmou_texto_cores_imagens', true,
      'aceite', private.politica_texto('aceite_arte'), 'qualidade', o.arte_qualidade, 'baixa_ok_cliente_em', o.arte_baixa_ok_em,
      'arte_refeita', p_arte_refeita, 'observacao', left(coalesce(p_observacao, ''), 300))
   where id = o.id;
  begin
    update public.orders set stage = 'producao' where id = o.id and stage in ('pago', 'arte', 'prova');
  exception when others then
    v_aviso := 'Arte aprovada, mas o pedido não entrou em produção sozinho: ' || left(sqlerrm, 160);
  end;
  update public.tasks set done_at = v_quando where order_id = o.id and setor = 'arte' and done_at is null;
  if o.conversation_id is not null then
    update public.conversations set setor = null, needs_human = false,
           modo_atendimento = case when coalesce((v_cfg ->> 'pos_pagamento_automatico')::boolean, true) then 'ia' else modo_atendimento end,
           attendant_change_reason = case when coalesce((v_cfg ->> 'pos_pagamento_automatico')::boolean, true) then 'Arte aprovada: automação retomada' else attendant_change_reason end
     where id = o.conversation_id;
  end if;
  insert into public.order_events (order_id, kind, message) values (o.id, 'art', 'Arte aprovada pelo cliente em ' || to_char(v_quando at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (texto, cores e imagens confirmados)');
  select due_date into v_prev from public.orders where id = o.id;
  return jsonb_build_object('ok', true, 'aprovada_em', v_quando, 'em_producao', v_aviso is null, 'aviso', v_aviso, 'conversation_id', o.conversation_id,
    'mensagem_cliente', case when v_prev is null then 'Arte aprovada, obrigado! O prazo começa a contar a partir de agora e eu te aviso por aqui quando o pedido estiver pronto.'
      else 'Arte aprovada, obrigado! O prazo começa a contar a partir de agora e o pedido fica pronto dia ' || to_char(v_prev, 'DD/MM') || '. Eu te aviso por aqui quando estiver pronto.' end);
end;
$$;
revoke execute on function public.arte_aprovar(uuid, boolean, boolean, text) from public, anon;
grant execute on function public.arte_aprovar(uuid, boolean, boolean, text) to authenticated, service_role;

-- Aba "Fila da arte": urgência no topo, depois o prazo mais próximo, depois quem espera há mais tempo
create or replace function public.arte_fila() returns table (
  order_id uuid, numero integer, pedido text, cliente text, itens jsonb, prazo_prometido date, entrega text, qualidade text, baixa_ok boolean,
  urgente boolean, art_status text, stage text, na_fila_desde timestamptz, horas_na_fila numeric, conversation_id uuid, observacoes text)
language sql stable security invoker set search_path = ''
as $$
  select o.id, o.number::integer, 'SG-' || lpad(o.number::text, 4, '0'), coalesce(nullif(c.name, ''), c.wa_id),
         coalesce(o.arte_resumo -> 'itens', '[]'::jsonb), coalesce((select max(q.data_prevista) from public.orcamentos q where q.order_id = o.id), o.due_date),
         o.delivery_method, coalesce(o.arte_qualidade, 'indefinida'), o.arte_baixa_ok_em is not null,
         o.urgente, o.art_status, o.stage, o.arte_fila_em, round(extract(epoch from (now() - o.arte_fila_em)) / 3600, 1), o.conversation_id,
         nullif(left(coalesce(cv.summary, ''), 400), '')
    from public.orders o
    join public.contacts c on c.id = o.contact_id
    left join public.conversations cv on cv.id = o.conversation_id
   where o.excluido_em is null and (o.payment_status = 'aprovado' or o.payment_manual) and o.arte_fila_em is not null and o.art_status <> 'aprovada'
   order by o.urgente desc, coalesce((select max(q.data_prevista) from public.orcamentos q where q.order_id = o.id), o.due_date) asc nulls last, o.arte_fila_em asc;
$$;
revoke execute on function public.arte_fila() from public, anon;
grant execute on function public.arte_fila() to authenticated, service_role;

-- Se o dono não agir em X horas (app_settings.arte.horas_novo_alerta), novo alerta
create or replace function public.arte_varredura() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r record; v_h integer := coalesce((select (value ->> 'horas_novo_alerta')::integer from public.app_settings where key = 'arte'), 4); v_n integer := 0; v_d jsonb;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  for r in
    select o.id, o.number, o.contact_id, o.conversation_id, o.arte_fila_em, o.arte_ultimo_alerta_em from public.orders o
     where o.arte_fila_em is not null and o.art_status <> 'aprovada' and o.excluido_em is null and o.stage in ('arte', 'prova')
       and coalesce(o.arte_ultimo_alerta_em, o.arte_fila_em) < now() - make_interval(hours => v_h)
  loop
    v_d := public.alerta_criar('arte_pendente', 'alta', r.contact_id, r.conversation_id, r.id,
      format('Pedido SG-%s está na fila da arte há mais de %s h sem aprovação. Abra a Fila da arte.', lpad(r.number::text, 4, '0'), v_h),
      jsonb_build_object('setor', 'arte'), 'arte_pendente:' || r.id::text || ':' || floor(extract(epoch from now()) / (v_h * 3600))::text);
    update public.orders set arte_ultimo_alerta_em = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'alertas', v_n);
end;
$$;
revoke execute on function public.arte_varredura() from public, anon, authenticated;
grant execute on function public.arte_varredura() to service_role;

do $$
begin
  begin
    if exists (select 1 from cron.job where jobname = 'arte-varredura') then perform cron.unschedule('arte-varredura'); end if;
    perform cron.schedule('arte-varredura', '*/15 * * * *', 'select public.arte_varredura()');
  exception when others then raise notice 'pg_cron indisponível: agende public.arte_varredura() a cada 15 minutos'; end;
end $$;

-- O encaminhamento de "arte" do agente passa a usar o mesmo caminho (pedido pago vai à fila; sem pedido pago continua só como tarefa)
create or replace function public.agente_encaminhar_arte(p_conversation uuid, p_motivo text, p_qualidade text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return public.arte_receber(p_conversation, 'arquivo', p_qualidade, p_motivo);
end;
$$;
revoke execute on function public.agente_encaminhar_arte(uuid, text, text) from public, anon, authenticated;
grant execute on function public.agente_encaminhar_arte(uuid, text, text) to service_role;

-- ---------------------------------------------------------------- 5. trava de saída: endereço depois do pagamento e promessa de reembolso em qualquer forma verbal
-- O endereço de retirada só pode sair para quem já pagou (João Victor informa na hora da retirada). Antes do pagamento continua bloqueado.
create or replace function public.agente_saida_segura(p_execucao uuid, p_texto text) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  r jsonb := public.agente_saida_base(p_execucao, p_texto);
  v_prom text[]; v_ct uuid; v_mot jsonb;
begin
  if r -> 'motivos' ? 'vazamento:endereco' then
    select contact_id into v_ct from public.agente_execucoes where id = p_execucao;
    if v_ct is not null and private.agente_fase(v_ct) = 'pos_pagamento' then
      v_mot := (select coalesce(jsonb_agg(m), '[]'::jsonb) from jsonb_array_elements_text(r -> 'motivos') m where m <> 'vazamento:endereco');
      r := jsonb_set(r, '{motivos}', v_mot);
      r := jsonb_set(r, '{ok}', to_jsonb(jsonb_array_length(v_mot) = 0));
    end if;
  end if;
  if coalesce(p_texto, '') ~* '(calling tools?\s*:|control_token|default_api|\mcall_[0-9]{4,}|tool_call)' then
    r := jsonb_set(r, '{ok}', 'false'::jsonb);
    r := jsonb_set(r, '{motivos}', coalesce(r -> 'motivos', '[]'::jsonb) || '"vazamento:chamada_de_ferramenta"'::jsonb);
  end if;
  v_prom := public.agente_promessas_indevidas(p_execucao, p_texto);
  if coalesce(p_texto, '') ~* '((vou|iremos|irei|posso|podemos|farei|faremos)\s+(te\s+)?(reembolsar|estornar|devolver|ressarcir)|(reembolsarei|estornarei|devolverei|ressarcirei)|te\s+(reembolsamos|devolvemos))'
     and not v_prom @> array['promessa:reembolso'] then
    v_prom := array_append(v_prom, 'promessa:reembolso');
  end if;
  if array_length(v_prom, 1) > 0 then
    r := jsonb_set(r, '{ok}', 'false'::jsonb);
    r := jsonb_set(r, '{motivos}', coalesce(r -> 'motivos', '[]'::jsonb) || to_jsonb(v_prom));
  end if;
  return r;
end;
$$;
revoke execute on function public.agente_saida_segura(uuid, text) from public, anon, authenticated;
grant execute on function public.agente_saida_segura(uuid, text) to service_role;

-- ---------------------------------------------------------------- 6. BauerLab: telefone confirmado pelo dono e indicação sem alerta
update public.app_settings set value = jsonb_set(value, '{telefone_confirmado_pelo_dono}', 'true') where key = 'bauerlab';
do $$
declare d text;
begin
  d := pg_get_functiondef('public.agente_bauerlab(uuid,text)'::regprocedure);
  if d like '%perform public.alerta_criar(''oportunidade_bauerlab''%' then
    d := regexp_replace(d, 'perform public\.alerta_criar\(''oportunidade_bauerlab''[^;]*;', 'null;', 'g');
    execute d;
  end if;
exception when undefined_function then null;
end $$;
