-- Mercado Pago (Checkout Pro): cobranças, eventos, alertas e um único caminho para confirmar pagamento (webhook e botão manual).
-- Aditiva e idempotente. Acesso só do dono (RLS); escrita das cobranças e do webhook só pelas Edge Functions (service role).

-- Pedido de teste: em modo teste do Mercado Pago só pedidos marcados como teste mudam de etapa.
alter table public.orders add column if not exists teste boolean not null default false;

create table if not exists public.pagamentos (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  eh_link boolean not null default false,          -- linha que guarda o link (as demais são tentativas de pagamento do mesmo link)
  link_ativo boolean not null default false,
  mp_preference_id text,
  mp_payment_id text unique,
  link text,
  valor numeric(12, 2) not null check (valor > 0),
  moeda text not null default 'BRL',
  status text not null default 'pendente'
    check (status in ('pendente', 'em_analise', 'aprovado', 'recusado', 'cancelado', 'expirado', 'estornado', 'contestado', 'invalidado')),
  status_detalhe text,
  metodo text,
  modo text not null check (modo in ('teste', 'producao', 'manual')),
  divergencia text,
  expira_em timestamptz,
  aprovado_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists pagamentos_order_idx on public.pagamentos (order_id, criado_em desc);
-- Um único link ativo por pedido e modo: duas chamadas ao mesmo tempo não criam dois links
create unique index if not exists pagamentos_link_ativo_uq on public.pagamentos (order_id, modo) where eh_link and link_ativo;

create table if not exists public.eventos_pagamento (
  id uuid primary key default gen_random_uuid(),
  chave text not null unique,                        -- impede evento duplicado (aviso repetido)
  tipo text not null check (tipo in (
    'link_criado', 'pagamento_pendente', 'pagamento_em_analise', 'pagamento_confirmado',
    'pagamento_recusado', 'pagamento_cancelado', 'pagamento_expirado', 'pagamento_estornado', 'pagamento_contestado')),
  order_id uuid not null references public.orders (id) on delete cascade,
  pagamento_id uuid references public.pagamentos (id) on delete set null,
  payload jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  processado_em timestamptz                          -- o agente marca aqui quando já tratou o evento
);
create index if not exists eventos_pagamento_pendentes_idx on public.eventos_pagamento (criado_em) where processado_em is null;

create table if not exists public.pagamentos_alertas (
  id uuid primary key default gen_random_uuid(),
  chave text not null unique,
  tipo text not null,
  order_id uuid references public.orders (id) on delete set null,
  mp_payment_id text,
  mensagem text not null,
  detalhes jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  resolvido_em timestamptz
);
create index if not exists pagamentos_alertas_abertos_idx on public.pagamentos_alertas (criado_em desc) where resolvido_em is null;

alter table public.pagamentos enable row level security;
alter table public.eventos_pagamento enable row level security;
alter table public.pagamentos_alertas enable row level security;

drop policy if exists pagamentos_select on public.pagamentos;
create policy pagamentos_select on public.pagamentos for select to authenticated using (private.is_staff());
drop policy if exists eventos_pagamento_select on public.eventos_pagamento;
create policy eventos_pagamento_select on public.eventos_pagamento for select to authenticated using (private.is_staff());
drop policy if exists pagamentos_alertas_select on public.pagamentos_alertas;
create policy pagamentos_alertas_select on public.pagamentos_alertas for select to authenticated using (private.is_staff());
drop policy if exists pagamentos_alertas_update on public.pagamentos_alertas;
create policy pagamentos_alertas_update on public.pagamentos_alertas for update to authenticated using (private.is_staff()) with check (private.is_staff());
-- (nenhuma política de insert/delete: só o service role escreve)

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'pagamentos') then
      alter publication supabase_realtime add table public.pagamentos;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'eventos_pagamento') then
      alter publication supabase_realtime add table public.eventos_pagamento;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'pagamentos_alertas') then
      alter publication supabase_realtime add table public.pagamentos_alertas;
    end if;
  end if;
end $$;

-- Ponto de extensão: roda antes de criar qualquer link. Hoje só confere pedido existente, valor maior que zero e pedido ainda não pago.
-- Quando a regra de piso/margem existir no banco, é só acrescentar aqui. Devolve null se pode cobrar, ou a mensagem de recusa.
create or replace function public.validar_antes_de_cobrar(p_order uuid) returns text
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_pay text;
  v_total numeric;
begin
  select payment_status into v_pay from public.orders where id = p_order;
  if not found then return 'Pedido não encontrado.'; end if;
  if v_pay = 'aprovado' then return 'Este pedido já está pago.'; end if;
  select total into v_total from public.order_financials where order_id = p_order;
  if coalesce(v_total, 0) <= 0 then return 'O pedido precisa ter itens e valor maior que zero para gerar o link.'; end if;
  return null;
end;
$$;

-- Evento e alerta (somente dentro do banco)
create or replace function private.mp_evento(p_tipo text, p_order uuid, p_pag uuid, p_chave text, p_payload jsonb) returns void
language sql
set search_path = ''
as $$
  insert into public.eventos_pagamento (tipo, order_id, pagamento_id, chave, payload)
  values (p_tipo, p_order, p_pag, p_chave, p_payload)
  on conflict (chave) do nothing;
$$;

create or replace function private.mp_alerta(p_tipo text, p_order uuid, p_mp_payment text, p_chave text, p_msg text, p_detalhes jsonb) returns void
language sql
set search_path = ''
as $$
  insert into public.pagamentos_alertas (tipo, order_id, mp_payment_id, chave, mensagem, detalhes)
  values (p_tipo, p_order, p_mp_payment, p_chave, p_msg, coalesce(p_detalhes, '{}'::jsonb))
  on conflict (chave) do nothing;
$$;

-- ÚNICO caminho para marcar um pedido como pago (webhook do Mercado Pago e botão "Marcar como pago").
-- Idempotente: se o pedido já está pago, não faz nada e devolve false.
create or replace function private.confirmar_pagamento(p_order uuid, p_origem text, p_metodo text, p_ext_id text, p_quando timestamptz, p_pagamento uuid) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_o public.orders%rowtype;
  v_total numeric;
begin
  select * into v_o from public.orders where id = p_order for update;
  if not found or v_o.payment_status = 'aprovado' then return false; end if;

  update public.orders set
    payment_status = 'aprovado',
    payment_manual = (p_origem = 'manual'),
    payment_method = coalesce(p_metodo, payment_method),
    payment_external_id = coalesce(p_ext_id, payment_external_id),
    payment_confirmed_at = coalesce(payment_confirmed_at, p_quando, now()),
    -- só avança para Pago quem ainda está antes dessa etapa; quem já passou dela não volta
    stage = case when stage in ('novo', 'cotando', 'aguardando_pagamento') then 'pago' else stage end
  where id = p_order;

  select total into v_total from public.order_financials where order_id = p_order;
  perform private.mp_evento(
    'pagamento_confirmado', p_order, p_pagamento, 'pagamento_confirmado:' || p_order::text,
    jsonb_build_object('pedido_id', p_order, 'pedido_numero', v_o.number, 'referencia', 'SG-' || lpad(v_o.number::text, 4, '0'),
      'valor', v_total, 'metodo', coalesce(p_metodo, v_o.payment_method), 'origem', p_origem, 'mp_payment_id', p_ext_id, 'teste', v_o.teste));
  return true;
end;
$$;

-- Botão manual do CRM: mesmo caminho do webhook
create or replace function public.confirmar_pagamento_manual(p_order uuid) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ok boolean;
  v_total numeric;
  v_id uuid;
begin
  if not private.is_staff() then raise exception 'Não autorizado.' using errcode = '42501'; end if;
  select total into v_total from public.order_financials where order_id = p_order;
  if v_total is null then raise exception 'Pedido não encontrado.' using errcode = 'P0001'; end if;
  insert into public.pagamentos (order_id, valor, status, modo, metodo, aprovado_em)
  select p_order, greatest(v_total, 0.01), 'aprovado', 'manual', coalesce((select payment_method from public.orders where id = p_order), 'manual'), now()
  where not exists (select 1 from public.orders where id = p_order and payment_status = 'aprovado')
  returning id into v_id;
  v_ok := private.confirmar_pagamento(p_order, 'manual', coalesce((select payment_method from public.orders where id = p_order), 'manual'), null, now(), v_id);
  return v_ok;
end;
$$;

-- Aviso do Mercado Pago já consultado na API: registra a tentativa e, se tudo confere, confirma o pedido.
create or replace function public.mp_registrar_pagamento(
  p_mp_payment_id text, p_mp_status text, p_status_detail text, p_referencia text,
  p_valor numeric, p_moeda text, p_metodo text, p_live boolean, p_modo text,
  p_aprovado_em timestamptz, p_preference_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_num bigint;
  v_o public.orders%rowtype;
  v_total numeric;
  v_row public.pagamentos%rowtype;
  v_link public.pagamentos%rowtype;
  v_status text;
  v_rank_new int;
  v_rank_old int;
  v_div text;
  v_payload jsonb;
  v_ref text;
  v_ranks jsonb := '{"pendente":0,"em_analise":1,"recusado":2,"cancelado":2,"expirado":2,"invalidado":2,"aprovado":3,"estornado":4,"contestado":5}';
begin
  if p_modo not in ('teste', 'producao') then raise exception 'modo inválido'; end if;
  v_status := case p_mp_status
    when 'approved' then 'aprovado' when 'pending' then 'pendente'
    when 'authorized' then 'em_analise' when 'in_process' then 'em_analise' when 'in_mediation' then 'em_analise'
    when 'rejected' then 'recusado' when 'refunded' then 'estornado' when 'charged_back' then 'contestado'
    when 'cancelled' then case when p_status_detail = 'expired' then 'expirado' else 'cancelado' end
    else 'pendente' end;

  if p_referencia ~ '^SG-[0-9]{1,12}$' then v_num := substring(p_referencia from 4)::bigint; end if;
  select * into v_o from public.orders where number = v_num for update;
  if not found then
    perform private.mp_alerta('referencia_desconhecida', null, p_mp_payment_id, 'ref_desconhecida:' || p_mp_payment_id || ':' || v_status,
      'Pagamento recebido com referência que não existe no CRM.', jsonb_build_object('referencia', p_referencia, 'valor', p_valor, 'status', v_status));
    return jsonb_build_object('acao', 'alerta', 'motivo', 'referencia_desconhecida');
  end if;
  select total into v_total from public.order_financials where order_id = v_o.id;
  v_ref := 'SG-' || lpad(v_o.number::text, 4, '0');

  -- 1) a tentativa já conhecida; 2) o link ainda sem pagamento; 3) nova tentativa copiando o link
  select * into v_row from public.pagamentos where mp_payment_id = p_mp_payment_id;
  if not found then
    select * into v_link from public.pagamentos
      where order_id = v_o.id and eh_link and modo = p_modo and (p_preference_id is null or mp_preference_id = p_preference_id)
      order by criado_em desc limit 1 for update;
    if found and v_link.mp_payment_id is null then
      update public.pagamentos set mp_payment_id = p_mp_payment_id where id = v_link.id returning * into v_row;
    else
      insert into public.pagamentos (order_id, eh_link, link_ativo, mp_preference_id, mp_payment_id, link, valor, status, modo, expira_em)
      values (v_o.id, false, false, coalesce(v_link.mp_preference_id, p_preference_id), p_mp_payment_id, v_link.link, greatest(coalesce(p_valor, 0), 0.01), 'pendente', p_modo, v_link.expira_em)
      returning * into v_row;
    end if;
  end if;

  v_rank_new := (v_ranks ->> v_status)::int;
  v_rank_old := (v_ranks ->> v_row.status)::int;
  -- aviso repetido: mesmo status já tratado (o evento do status existe, ou o pedido já foi confirmado por este pagamento)
  if v_row.status = v_status and v_row.divergencia is null and (
       (v_status = 'aprovado' and v_o.payment_status = 'aprovado')
       or (v_status <> 'aprovado' and exists (select 1 from public.eventos_pagamento where chave = 'pagamento_' || v_status || ':' || p_mp_payment_id))
     ) then
    return jsonb_build_object('acao', 'duplicado', 'status', v_status);
  end if;
  if v_rank_new < v_rank_old then
    return jsonb_build_object('acao', 'ignorado', 'motivo', 'aviso_antigo', 'status', v_status);
  end if;

  update public.pagamentos set
    status = v_status, status_detalhe = p_status_detail, metodo = coalesce(p_metodo, metodo),
    valor = greatest(coalesce(p_valor, 0), 0.01), moeda = coalesce(p_moeda, 'BRL'),
    aprovado_em = case when v_status = 'aprovado' then coalesce(p_aprovado_em, now()) else aprovado_em end,
    atualizado_em = now()
  where id = v_row.id returning * into v_row;

  v_payload := jsonb_build_object('pedido_id', v_o.id, 'pedido_numero', v_o.number, 'referencia', v_ref, 'valor', p_valor,
    'metodo', p_metodo, 'mp_payment_id', p_mp_payment_id, 'modo', p_modo, 'status_detalhe', p_status_detail, 'teste', v_o.teste);

  if v_status = 'aprovado' then
    if coalesce(p_moeda, '') <> 'BRL' then v_div := 'moeda_divergente';
    elsif p_valor is null or round(p_valor * 100) <> round(v_total * 100) then v_div := 'valor_divergente';
    elsif p_live is distinct from (p_modo = 'producao') then v_div := 'modo_divergente';
    elsif p_modo = 'teste' and not v_o.teste then v_div := 'teste_em_pedido_real';
    elsif p_modo = 'producao' and v_o.teste then v_div := 'producao_em_pedido_teste';
    elsif v_o.payment_status = 'aprovado' and v_o.payment_external_id is distinct from p_mp_payment_id then v_div := 'pagamento_duplicado';
    end if;

    if v_div is not null then
      update public.pagamentos set divergencia = v_div where id = v_row.id;
      perform private.mp_alerta(v_div, v_o.id, p_mp_payment_id, v_div || ':' || p_mp_payment_id,
        case v_div
          when 'valor_divergente' then 'Valor pago (R$ ' || replace(to_char(p_valor, 'FM9999990.00'), '.', ',') || ') diferente do pedido ' || v_ref || ' (R$ ' || replace(to_char(v_total, 'FM9999990.00'), '.', ',') || '). O pedido não foi alterado.'
          when 'moeda_divergente' then 'Moeda do pagamento diferente de BRL no pedido ' || v_ref || '. O pedido não foi alterado.'
          when 'teste_em_pedido_real' then 'Pagamento de TESTE recebido para o pedido real ' || v_ref || '. O pedido não foi alterado.'
          when 'producao_em_pedido_teste' then 'Pagamento real recebido para o pedido de teste ' || v_ref || '. Confira com o dono.'
          when 'pagamento_duplicado' then 'Segundo pagamento aprovado para o pedido ' || v_ref || ' que já estava pago. Avalie o estorno.'
          else 'Modo do aviso (teste/produção) não confere com a configuração. O pedido não foi alterado.' end,
        v_payload || jsonb_build_object('valor_pedido', v_total));
      return jsonb_build_object('acao', 'alerta', 'motivo', v_div);
    end if;

    update public.pagamentos set link_ativo = false where order_id = v_o.id and eh_link;
    perform private.confirmar_pagamento(v_o.id, 'mercadopago', p_metodo, p_mp_payment_id, p_aprovado_em, v_row.id);
    return jsonb_build_object('acao', 'confirmado');
  end if;

  perform private.mp_evento('pagamento_' || v_status, v_o.id, v_row.id, 'pagamento_' || v_status || ':' || p_mp_payment_id, v_payload);
  if v_status = 'recusado' then
    perform private.mp_alerta('pagamento_recusado', v_o.id, p_mp_payment_id, 'recusado:' || p_mp_payment_id,
      'Pagamento recusado no pedido ' || v_ref || ' (' || coalesce(p_status_detail, 'sem detalhe') || '). O cliente pode tentar de novo pelo mesmo link.', v_payload);
  elsif v_status = 'estornado' then
    perform private.mp_alerta('estorno', v_o.id, p_mp_payment_id, 'estorno:' || p_mp_payment_id,
      'Pagamento do pedido ' || v_ref || ' foi estornado. O pedido não foi alterado: decida o que fazer.', v_payload);
  elsif v_status = 'contestado' then
    perform private.mp_alerta('contestacao', v_o.id, p_mp_payment_id, 'contestacao:' || p_mp_payment_id,
      'Pagamento do pedido ' || v_ref || ' foi contestado (chargeback). O pedido não foi alterado: responda no painel do Mercado Pago.', v_payload);
  end if;
  return jsonb_build_object('acao', 'registrado', 'status', v_status);
end;
$$;

-- Alerta avulso (reclamações e contestações que chegam por tópicos próprios)
create or replace function public.mp_registrar_alerta(p_tipo text, p_mp_payment_id text, p_chave text, p_mensagem text, p_detalhes jsonb) returns void
language sql
security definer
set search_path = ''
as $$
  select private.mp_alerta(
    p_tipo,
    (select o.id from public.pagamentos g join public.orders o on o.id = g.order_id where g.mp_payment_id = p_mp_payment_id limit 1),
    p_mp_payment_id, p_chave, p_mensagem, p_detalhes);
$$;

-- Funções de servidor: só o service role executa as de pagamento; o botão manual é do dono logado
revoke execute on function public.validar_antes_de_cobrar(uuid) from public, anon, authenticated;
revoke execute on function public.mp_registrar_pagamento(text, text, text, text, numeric, text, text, boolean, text, timestamptz, text) from public, anon, authenticated;
revoke execute on function public.mp_registrar_alerta(text, text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.confirmar_pagamento_manual(uuid) from public, anon;
revoke execute on function private.mp_evento(text, uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function private.mp_alerta(text, uuid, text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function private.confirmar_pagamento(uuid, text, text, text, timestamptz, uuid) from public, anon, authenticated;
grant execute on function public.validar_antes_de_cobrar(uuid) to service_role;
grant execute on function public.mp_registrar_pagamento(text, text, text, text, numeric, text, text, boolean, text, timestamptz, text) to service_role;
grant execute on function public.mp_registrar_alerta(text, text, text, text, jsonb) to service_role;
grant execute on function public.confirmar_pagamento_manual(uuid) to authenticated;
