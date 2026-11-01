-- Etapa 7B, Bloco A10: WF9 completo. Tipos de erro, ação por tipo, divergência entre pagamento e pedido e simulação.
-- Aditiva e idempotente. O WF9 continua chamando agente_erro_registrar; só ganhou o pedido opcional.

create table if not exists public.erros_operacao (
  id uuid primary key default gen_random_uuid(),
  quando timestamptz not null default now(),
  tipo text not null check (tipo in ('envio_mensagem', 'integracao_indisponivel', 'fornecedor', 'checkout', 'divergencia_pagamento', 'evento_duplicado', 'gravar_crm', 'mudar_status', 'outro')),
  workflow text not null,
  etapa text,
  mensagem text,
  pedido_id uuid,
  acao text not null check (acao in ('repetir', 'registrar', 'interromper_e_alertar')),
  repetivel boolean not null default false,
  simulacao boolean not null default false
);
create index if not exists erros_operacao_quando_idx on public.erros_operacao (tipo, quando desc);
alter table public.erros_operacao enable row level security;
drop policy if exists erros_operacao_dono on public.erros_operacao;
create policy erros_operacao_dono on public.erros_operacao for select to authenticated using (private.is_staff());
revoke all on public.erros_operacao from anon;

-- Classifica pela mensagem e pelo nó que falhou
create or replace function private.erro_tipo(p_workflow text, p_no text, p_msg text) returns text
language sql immutable set search_path = ''
as $$
  select case
    when t ~ '(duplicate key|duplicad|already exists|23505|evento_duplicado)' then 'evento_duplicado'
    when t ~ '(diverg|valor do pagamento|payment.*mismatch|pagamento.*pedido)' then 'divergencia_pagamento'
    when t ~ '(mp-criar-link|checkout|preferenc|link de pagamento|gerar_link)' then 'checkout'
    when t ~ '(fornecedor|tabela do fornecedor|catalogo-fornecedor)' then 'fornecedor'
    when t ~ '(agente-enviar|proativo-enviar|cliente-pago-avisar|whatsapp|graph\.facebook|enviar)' then 'envio_mensagem'
    when t ~ '(etapa|stage|subestatus|status do pedido|mudar)' and t ~ '(pedido|order)' then 'mudar_status'
    when t ~ '(supabase|postgrest|permission denied|violates|insert|update|rpc|crm)' then 'gravar_crm'
    when t ~ '(timeout|timed out|econn|enotfound|502|503|504|429|indispon|unavailable)' then 'integracao_indisponivel'
    else 'outro' end
  from (select lower(coalesce(p_workflow, '') || ' ' || coalesce(p_no, '') || ' ' || coalesce(p_msg, '')) as t) x;
$$;

-- Registra o erro, decide a ação e alerta o dono quando não há recuperação segura.
-- Repetir (sem risco): envio de mensagem, integração fora do ar, consulta ao fornecedor. As filas são idempotentes (reserva atômica).
-- Nunca repetir sozinho: checkout, divergência de pagamento, gravação no CRM e mudança de status (podem duplicar pagamento ou pedido).
drop function if exists public.agente_erro_registrar(text, text, text, text, text);
create or replace function public.agente_erro_registrar(p_workflow text, p_workflow_id text, p_no text, p_mensagem text, p_execucao text default null, p_pedido uuid default null, p_simulacao boolean default false) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_msg text := left(regexp_replace(coalesce(p_mensagem, 'sem mensagem'), '\s+', ' ', 'g'), 240);
  v_wf text := left(coalesce(p_workflow, 'desconhecido'), 80);
  v_tipo text := private.erro_tipo(p_workflow, p_no, p_mensagem);
  v_acao text; v_repetivel boolean; v_lib jsonb := '{}'::jsonb; v_al jsonb; v_recentes integer; v_conv uuid; v_contato uuid;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  v_repetivel := v_tipo in ('envio_mensagem', 'integracao_indisponivel', 'fornecedor');
  select count(*) into v_recentes from public.erros_operacao where tipo = v_tipo and workflow = v_wf and quando >= now() - interval '30 minutes' and not simulacao;
  v_acao := case
    when v_tipo = 'evento_duplicado' then 'registrar'                                  -- a idempotência já protegeu: nada a refazer
    when v_repetivel and v_recentes < 3 then 'repetir'
    else 'interromper_e_alertar' end;
  insert into public.erros_operacao (tipo, workflow, etapa, mensagem, pedido_id, acao, repetivel, simulacao)
  values (v_tipo, v_wf, left(p_no, 80), v_msg, p_pedido, v_acao, v_repetivel, p_simulacao);
  insert into public.agent_logs (actor, action, detail, result, workflow)
  values ('sistema', 'erro_workflow', jsonb_build_object('workflow_id', p_workflow_id, 'no', left(p_no, 80), 'execucao', p_execucao, 'tipo', v_tipo, 'acao', v_acao, 'pedido_id', p_pedido), v_msg, v_wf);
  if v_acao = 'repetir' and v_wf ~ 'WF[5-8]' and not p_simulacao then v_lib := public.followup_liberar_travados(); end if;
  if v_acao = 'interromper_e_alertar' then
    if p_pedido is not null then
      select o.conversation_id, o.contact_id into v_conv, v_contato from public.orders o where o.id = p_pedido;
      -- divergência ou falha em pedido: o agente para de falar do assunto e o dono assume
      if v_conv is not null and v_tipo in ('divergencia_pagamento', 'checkout', 'mudar_status', 'gravar_crm') and not p_simulacao then
        update public.conversations set needs_human = true where id = v_conv;
      end if;
    end if;
    v_al := public.alerta_criar('erro_workflow', 'alta', v_contato, v_conv, p_pedido,
      'Erro (' || replace(v_tipo, '_', ' ') || ') no workflow ' || v_wf || ', nó ' || coalesce(left(p_no, 60), '?') || ': ' || left(v_msg, 100) || '. Nada foi refeito sozinho.',
      jsonb_build_object('workflow', v_wf, 'execucao', p_execucao, 'tipo', v_tipo, 'simulacao', p_simulacao),
      'erro_wf:' || v_tipo || ':' || v_wf || ':' || to_char(date_trunc('hour', now()) + floor(extract(minute from now()) / 30) * interval '30 minutes', 'YYYYMMDDHH24MI'), null);
  end if;
  return jsonb_build_object('ok', true, 'tipo', v_tipo, 'acao', v_acao, 'liberados', v_lib, 'alerta', v_al);
end;
$$;
revoke execute on function public.agente_erro_registrar(text, text, text, text, text, uuid, boolean) from public, anon, authenticated;
grant execute on function public.agente_erro_registrar(text, text, text, text, text, uuid, boolean) to service_role;

-- Divergência entre pagamento e pedido (a cada hora no WF9): valor diferente do total ou pedido pago sem pagamento aprovado
create or replace function public.pagamentos_divergencias_checar() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r record; v_n integer := 0; v_al jsonb;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  for r in
    select o.id, o.number, o.contact_id, o.conversation_id,
           case when o.payment_status = 'aprovado' and not o.payment_manual and not exists (select 1 from public.pagamentos p where p.order_id = o.id and p.status = 'aprovado') then 'pedido_pago_sem_pagamento'
                else 'valor_diferente' end as motivo
      from public.orders o join public.order_financials f on f.order_id = o.id
     where o.excluido_em is null and not coalesce(o.teste, false) and o.payment_status = 'aprovado'
       and ((not o.payment_manual and not exists (select 1 from public.pagamentos p where p.order_id = o.id and p.status = 'aprovado'))
         or exists (select 1 from public.pagamentos p where p.order_id = o.id and p.status = 'aprovado' and abs(p.valor - f.total) > 0.05))
  loop
    v_n := v_n + 1;
    insert into public.erros_operacao (tipo, workflow, etapa, mensagem, pedido_id, acao, repetivel)
    select 'divergencia_pagamento', 'verificação horária', r.motivo, 'Pagamento e pedido SG-' || lpad(r.number::text, 4, '0') || ' não conferem', r.id, 'interromper_e_alertar', false
     where not exists (select 1 from public.erros_operacao e where e.pedido_id = r.id and e.tipo = 'divergencia_pagamento' and e.quando >= now() - interval '1 day');
    v_al := public.alerta_criar('divergencia_pagamento', 'alta', r.contact_id, r.conversation_id, r.id,
      'Pagamento e pedido SG-' || lpad(r.number::text, 4, '0') || ' não conferem (' || replace(r.motivo, '_', ' ') || '). Confira no Mercado Pago.', '{}'::jsonb, 'diverg:' || r.id::text, null);
  end loop;
  return jsonb_build_object('ok', true, 'divergencias', v_n);
end;
$$;
revoke execute on function public.pagamentos_divergencias_checar() from public, anon, authenticated;
grant execute on function public.pagamentos_divergencias_checar() to service_role;
