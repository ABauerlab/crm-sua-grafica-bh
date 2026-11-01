-- Etapa 6: alertas ao dono (WhatsApp + push no iPhone), pós-pagamento (WF5) e chamar_dono real.
-- Aditiva e idempotente. Estende `alertas` (Etapa 1) e `agente_chamar_dono` (Etapa 5). Não recria nada do Mercado Pago.

-- ---------------------------------------------------------------- 1. assinaturas de push (uma por aparelho)
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  dispositivo text,
  ativo boolean not null default true,
  falhas smallint not null default 0,
  criado_em timestamptz not null default now(),
  ultimo_envio_em timestamptz,
  desativado_em timestamptz
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id) where ativo;
alter table public.push_subscriptions enable row level security;
revoke all on table public.push_subscriptions from anon;
drop policy if exists push_subscriptions_dono on public.push_subscriptions;
create policy push_subscriptions_dono on public.push_subscriptions for all to authenticated
  using (user_id = (select auth.uid()) and private.is_staff())
  with check (user_id = (select auth.uid()) and private.is_staff());

-- ---------------------------------------------------------------- 2. alertas: colunas novas
alter table public.alertas add column if not exists chave text;
alter table public.alertas add column if not exists dados jsonb not null default '{}'::jsonb;
alter table public.alertas add column if not exists tentativas_whatsapp smallint not null default 0;
alter table public.alertas add column if not exists tentativas_push smallint not null default 0;
alter table public.alertas add column if not exists erro_whatsapp text;
alter table public.alertas add column if not exists erro_push text;
alter table public.alertas add column if not exists ultima_tentativa_em timestamptz;
alter table public.alertas add column if not exists enviado_whatsapp_em timestamptz;
alter table public.alertas add column if not exists enviado_push_em timestamptz;
alter table public.alertas add column if not exists resumo_id uuid references public.alertas (id) on delete set null;
alter table public.alertas add column if not exists lido_em timestamptz;
create unique index if not exists alertas_chave_uq on public.alertas (chave) where chave is not null;
create index if not exists alertas_fila_idx on public.alertas (criado_em desc)
  where status_whatsapp in ('pendente', 'aguardando_template', 'agrupado') or status_push in ('pendente', 'agrupado');
create index if not exists alertas_nao_lidos_idx on public.alertas (criado_em desc) where lido_em is null;

-- o CRM marca como lido (RLS já limita à equipe); o resto só a service role escreve
drop policy if exists alertas_dono on public.alertas;
create policy alertas_dono on public.alertas for all to authenticated using (private.is_staff()) with check (private.is_staff());
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'alertas') then
    alter publication supabase_realtime add table public.alertas;
  end if;
end $$;

-- ---------------------------------------------------------------- 3. configuração (Configurações > Notificações)
insert into public.app_settings (key, value) values ('notificacoes', '{
  "tipos": {
    "pedido_pago":          {"push": true, "whatsapp": true,  "fura_silencio": true},
    "atencao_agente":       {"push": true, "whatsapp": true,  "fura_silencio": true},
    "pagamento_problema":   {"push": true, "whatsapp": true,  "fura_silencio": true},
    "nova_mensagem_humano": {"push": true, "whatsapp": false, "fura_silencio": false},
    "pagamento_pendente":   {"push": true, "whatsapp": true,  "fura_silencio": false},
    "pedido_sem_arte":      {"push": true, "whatsapp": true,  "fura_silencio": false},
    "politica_desconto":    {"push": true, "whatsapp": true,  "fura_silencio": false},
    "resumo":               {"push": true, "whatsapp": true,  "fura_silencio": false}
  },
  "silencio": {"ativo": true, "inicio": "22:00", "fim": "07:00"},
  "limites": {"horas_pagamento_pendente": 6, "horas_sem_arte": 12},
  "resumo_minutos": 120,
  "url_base": "https://crm.suagraficabh.com.br"
}'::jsonb) on conflict (key) do nothing;

-- configuração efetiva: o que o dono salvou por cima do padrão
create or replace function private.notif_cfg() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce((select value from public.app_settings where key = 'notificacoes'), '{}'::jsonb);
$$;
revoke execute on function private.notif_cfg() from public, anon, authenticated;

create or replace function private.alerta_categoria(p_tipo text) returns text
language sql immutable set search_path = ''
as $$
  select case
    when p_tipo = 'pedido_pago' then 'pedido_pago'
    when p_tipo = 'nova_mensagem_humano' then 'nova_mensagem_humano'
    when p_tipo = 'pagamento_pendente_demora' then 'pagamento_pendente'
    when p_tipo = 'pedido_sem_arte' then 'pedido_sem_arte'
    when p_tipo like 'padrao_desconto%' then 'politica_desconto'
    when p_tipo = 'resumo' then 'resumo'
    when p_tipo = 'pagamento_problema' then 'pagamento_problema'
    else 'atencao_agente' end;
$$;

-- horário de silêncio (America/Sao_Paulo); aceita janela que vira o dia (22:00 a 07:00)
create or replace function private.em_silencio(p_cfg jsonb, p_agora timestamptz default now()) returns boolean
language plpgsql stable set search_path = ''
as $$
declare v_ini time; v_fim time; v_h time := (p_agora at time zone 'America/Sao_Paulo')::time;
begin
  if not coalesce((p_cfg #>> '{silencio,ativo}')::boolean, false) then return false; end if;
  v_ini := coalesce(p_cfg #>> '{silencio,inicio}', '22:00')::time;
  v_fim := coalesce(p_cfg #>> '{silencio,fim}', '07:00')::time;
  if v_ini = v_fim then return false; end if;
  if v_ini < v_fim then return v_h >= v_ini and v_h < v_fim; end if;
  return v_h >= v_ini or v_h < v_fim;
exception when others then return false;
end;
$$;

create or replace function private.brl_milhar(p_v numeric) returns text
language sql immutable set search_path = ''
as $$
  select case when p_v is null then 'a confirmar'
    else 'R$ ' || regexp_replace(replace(to_char(p_v, 'FM999999990.00'), '.', ','), '(\d)(?=(\d{3})+,)', '\1.', 'g') end;
$$;

-- ---------------------------------------------------------------- 4. criar alerta (única porta de entrada)
-- Regras: mesmo alerta (tipo + conversa/pedido/contato + início do motivo) só uma vez a cada 30 minutos, ou uma vez por `chave`.
-- Gravidade alta: pendente nos dois canais. Gravidade baixa: agrupada no resumo (a cada 2 h). Canal desligado nas configurações: 'desligado'.
create or replace function public.alerta_criar(
  p_tipo text, p_gravidade text, p_contact uuid, p_conversation uuid, p_order uuid, p_motivo text,
  p_dados jsonb default '{}'::jsonb, p_chave text default null, p_canais text[] default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_grav text := case when lower(coalesce(p_gravidade, '')) in ('alta', 'alto', 'high', 'urgente') then 'alta' else 'baixa' end;
  v_motivo text := left(trim(coalesce(p_motivo, 'sem motivo informado')), 300);
  v_cfg jsonb := private.notif_cfg();
  v_pref jsonb := coalesce(v_cfg -> 'tipos' -> private.alerta_categoria(p_tipo), '{"push":true,"whatsapp":true}'::jsonb);
  v_base text := coalesce(v_cfg ->> 'url_base', 'https://crm.suagraficabh.com.br');
  v_wa text; v_push text; v_id uuid; v_dados jsonb := coalesce(p_dados, '{}'::jsonb);
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_chave is not null then
    select id into v_id from public.alertas where chave = p_chave;
    if found then return jsonb_build_object('ok', true, 'ja_alertado', true, 'alerta_id', v_id); end if;
  else
    if exists (
      select 1 from public.alertas
      where tipo = p_tipo and criado_em > now() - interval '30 minutes' and left(motivo, 60) = left(v_motivo, 60)
        and conversation_id is not distinct from p_conversation and order_id is not distinct from p_order and contact_id is not distinct from p_contact
    ) then return jsonb_build_object('ok', true, 'ja_alertado', true); end if;
  end if;

  v_wa := case when not coalesce((v_pref ->> 'whatsapp')::boolean, true) or (p_canais is not null and not 'whatsapp' = any(p_canais)) then 'desligado'
               when v_grav = 'baixa' then 'agrupado' else 'pendente' end;
  v_push := case when not coalesce((v_pref ->> 'push')::boolean, true) or (p_canais is not null and not 'push' = any(p_canais)) then 'desligado'
                 when v_grav = 'baixa' then 'agrupado' else 'pendente' end;
  -- link de abertura: pedido tem prioridade; senão a conversa
  if not (v_dados ? 'url') then
    if p_order is not null then v_dados := v_dados || jsonb_build_object('url', v_base || '/kanban?pedido=' || p_order::text);
    elsif p_conversation is not null then v_dados := v_dados || jsonb_build_object('url', v_base || '/inbox/' || p_conversation::text);
    else v_dados := v_dados || jsonb_build_object('url', v_base || '/painel'); end if;
  end if;
  if p_contact is not null and not (v_dados ? 'cliente') then
    v_dados := v_dados || jsonb_build_object('cliente', coalesce((select nullif(trim(name), '') from public.contacts where id = p_contact), 'Cliente sem nome'));
  end if;

  insert into public.alertas (tipo, gravidade, contact_id, conversation_id, order_id, motivo, canais, status_whatsapp, status_push, dados, chave)
  values (p_tipo, v_grav, p_contact, p_conversation, p_order, v_motivo,
          array_remove(array[case when v_wa <> 'desligado' then 'whatsapp' end, case when v_push <> 'desligado' then 'push' end], null),
          v_wa, v_push, v_dados, p_chave)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'alerta_id', v_id, 'gravidade', v_grav, 'status_whatsapp', v_wa, 'status_push', v_push);
end;
$$;
revoke execute on function public.alerta_criar(text, text, uuid, uuid, uuid, text, jsonb, text, text[]) from public, anon, authenticated;
grant execute on function public.alerta_criar(text, text, uuid, uuid, uuid, text, jsonb, text, text[]) to service_role;

-- chamar_dono REAL (Etapa 5 só gravava a linha): agora passa pela mesma porta e o dispatcher envia pelos dois canais
create or replace function public.agente_chamar_dono(
  p_conversation uuid, p_motivo text, p_gravidade text default 'baixa', p_tipo text default 'agente_chamado'
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_contact uuid; v_r jsonb; v_grav text;
begin
  select contact_id into v_contact from public.conversations where id = p_conversation;
  if v_contact is null then return jsonb_build_object('ok', false, 'motivo', 'conversa_inexistente'); end if;
  v_r := public.alerta_criar(p_tipo, p_gravidade, v_contact, p_conversation, null, p_motivo, jsonb_build_object('motivo', left(trim(coalesce(p_motivo, '')), 300)));
  v_grav := v_r ->> 'gravidade';
  if v_grav = 'alta' then update public.conversations set needs_human = true where id = p_conversation; end if;
  return v_r;
end;
$$;

-- ---------------------------------------------------------------- 5. fila do dispatcher (Edge Function alertas-enviar)
-- Devolve o que precisa sair agora. Aplica silêncio (empurra o push para o resumo) e o recuo entre tentativas.
create or replace function public.alertas_proximos(p_limite integer default 20) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_cfg jsonb := private.notif_cfg(); v_sil boolean := private.em_silencio(private.notif_cfg()); r record; v_out jsonb := '[]'::jsonb;
  v_fura boolean; v_push boolean; v_wa boolean; v_badge integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select count(*) into v_badge from public.alertas where lido_em is null and criado_em > now() - interval '48 hours' and gravidade = 'alta' and tipo <> 'resumo';
  for r in
    select * from public.alertas
    where criado_em > now() - interval '12 hours'
      and (status_whatsapp in ('pendente', 'aguardando_template') or status_push = 'pendente')
      and (ultima_tentativa_em is null or ultima_tentativa_em < now() - (greatest(tentativas_whatsapp, tentativas_push) * interval '1 minute'))
    order by criado_em limit greatest(1, least(p_limite, 100))
  loop
    v_fura := coalesce((v_cfg #>> array['tipos', private.alerta_categoria(r.tipo), 'fura_silencio'])::boolean, false);
    v_push := r.status_push = 'pendente';
    v_wa := r.status_whatsapp in ('pendente', 'aguardando_template');
    if v_push and v_sil and not v_fura then
      update public.alertas set status_push = 'agrupado' where id = r.id;
      v_push := false;
    end if;
    if v_push or v_wa then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', r.id, 'tipo', r.tipo, 'gravidade', r.gravidade, 'motivo', r.motivo, 'dados', r.dados,
        'conversation_id', r.conversation_id, 'order_id', r.order_id, 'criado_em', r.criado_em,
        'enviar_push', v_push, 'enviar_whatsapp', v_wa, 'badge', v_badge));
    end if;
  end loop;
  return v_out;
end;
$$;
revoke execute on function public.alertas_proximos(integer) from public, anon, authenticated;
grant execute on function public.alertas_proximos(integer) to service_role;

-- Resultado de um canal. Falha: tenta de novo (recuo de 1, 2 min) até 3 vezes; esgotado, avisa pelo outro canal.
create or replace function public.alerta_resultado(p_id uuid, p_canal text, p_status text, p_erro text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  a public.alertas%rowtype; v_final text; v_tent smallint; v_outro text; v_outro_status text; v_aviso jsonb := null;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_canal not in ('whatsapp', 'push') or p_status not in ('enviado', 'falhou', 'aguardando_template', 'sem_aparelho', 'indisponivel') then
    return jsonb_build_object('ok', false, 'motivo', 'parametro_invalido');
  end if;
  select * into a from public.alertas where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'alerta_inexistente'); end if;
  v_tent := case p_canal when 'whatsapp' then a.tentativas_whatsapp else a.tentativas_push end + 1;
  v_final := case
    when p_status = 'falhou' then case when v_tent >= 3 then 'falhou' else 'pendente' end
    when p_status = 'aguardando_template' and a.criado_em < now() - interval '11 hours' then 'indisponivel'
    else p_status end;
  if p_canal = 'whatsapp' then
    update public.alertas set status_whatsapp = v_final, tentativas_whatsapp = v_tent, erro_whatsapp = left(p_erro, 300), ultima_tentativa_em = now(),
      enviado_whatsapp_em = case when p_status = 'enviado' then now() else enviado_whatsapp_em end, enviado_em = case when p_status = 'enviado' then now() else enviado_em end where id = p_id;
  else
    update public.alertas set status_push = v_final, tentativas_push = v_tent, erro_push = left(p_erro, 300), ultima_tentativa_em = now(),
      enviado_push_em = case when p_status = 'enviado' then now() else enviado_push_em end, enviado_em = case when p_status = 'enviado' then now() else enviado_em end where id = p_id;
  end if;
  -- canal esgotado: avisa pelo outro (uma vez), sem repetir o conteúdo todo
  if v_final in ('falhou', 'indisponivel', 'sem_aparelho') and a.tipo <> 'canal_falhou' and v_final <> 'sem_aparelho' then
    v_outro := case p_canal when 'whatsapp' then 'push' else 'whatsapp' end;
    v_outro_status := case v_outro when 'whatsapp' then (select status_whatsapp from public.alertas where id = p_id) else (select status_push from public.alertas where id = p_id) end;
    if v_outro_status <> 'desligado' then
      v_aviso := public.alerta_criar('canal_falhou', 'alta', a.contact_id, a.conversation_id, a.order_id,
        format('O aviso por %s não chegou (%s). Conteúdo: %s', case p_canal when 'whatsapp' then 'WhatsApp' else 'notificação' end, coalesce(left(p_erro, 80), 'erro'), left(a.motivo, 140)),
        coalesce(a.dados, '{}'::jsonb), 'canal_falhou:' || p_id::text || ':' || p_canal, array[v_outro]);
    end if;
  end if;
  return jsonb_build_object('ok', true, 'status', v_final, 'tentativas', v_tent, 'aviso_outro_canal', v_aviso);
end;
$$;
revoke execute on function public.alerta_resultado(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.alerta_resultado(uuid, text, text, text) to service_role;

-- Resumo das gravidades baixas (a cada `resumo_minutos`, fora do silêncio)
create or replace function public.alertas_resumo_montar() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_cfg jsonb := private.notif_cfg(); v_min integer := coalesce((v_cfg ->> 'resumo_minutos')::integer, 120);
  v_n integer; v_itens jsonb; v_texto text; v_id uuid; v_r jsonb; v_chave text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if private.em_silencio(v_cfg) then return jsonb_build_object('ok', true, 'criado', false, 'motivo', 'silencio'); end if;
  if exists (select 1 from public.alertas where tipo = 'resumo' and criado_em > now() - make_interval(mins => v_min)) then
    return jsonb_build_object('ok', true, 'criado', false, 'motivo', 'resumo_recente');
  end if;
  select count(*), coalesce(jsonb_agg(jsonb_build_object('tipo', x.tipo, 'motivo', left(x.motivo, 120), 'url', x.dados ->> 'url', 'cliente', x.dados ->> 'cliente') order by x.criado_em), '[]'::jsonb)
    into v_n, v_itens
    from public.alertas x where (x.status_whatsapp = 'agrupado' or x.status_push = 'agrupado') and x.criado_em > now() - interval '48 hours';
  if v_n = 0 then return jsonb_build_object('ok', true, 'criado', false, 'motivo', 'nada_a_resumir'); end if;
  select string_agg(format('%s (%s)', t, c), '; ') into v_texto from (
    select tipo as t, count(*) as c from public.alertas where (status_whatsapp = 'agrupado' or status_push = 'agrupado') and criado_em > now() - interval '48 hours' group by tipo order by count(*) desc limit 5) s;
  v_chave := 'resumo:' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMMDDHH24MI');
  v_r := public.alerta_criar('resumo', 'alta', null, null, null, format('%s aviso(s) de baixa gravidade: %s', v_n, v_texto),
    jsonb_build_object('itens', v_itens, 'total', v_n, 'url', coalesce(v_cfg ->> 'url_base', 'https://crm.suagraficabh.com.br') || '/painel', 'cliente', 'Resumo'), v_chave);
  v_id := (v_r ->> 'alerta_id')::uuid;
  if v_id is null then return jsonb_build_object('ok', true, 'criado', false, 'motivo', 'duplicado'); end if;
  update public.alertas set resumo_id = v_id,
    status_whatsapp = case when status_whatsapp = 'agrupado' then 'resumido' else status_whatsapp end,
    status_push = case when status_push = 'agrupado' then 'resumido' else status_push end
  where id <> v_id and (status_whatsapp = 'agrupado' or status_push = 'agrupado') and criado_em > now() - interval '48 hours';
  return jsonb_build_object('ok', true, 'criado', true, 'alerta_id', v_id, 'itens', v_n);
end;
$$;
revoke execute on function public.alertas_resumo_montar() from public, anon, authenticated;
grant execute on function public.alertas_resumo_montar() to service_role;

-- ---------------------------------------------------------------- 6. varredura periódica (pagamento parado, pedido sem arte, desconto incomum)
create or replace function public.alertas_varredura() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_cfg jsonb := private.notif_cfg(); r record; v_n integer := 0; v_h_pag integer := coalesce((v_cfg #>> '{limites,horas_pagamento_pendente}')::integer, 6);
  v_h_arte integer := coalesce((v_cfg #>> '{limites,horas_sem_arte}')::integer, 12); v_pref jsonb; v_d jsonb; v_ref text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  -- link criado e não pago há mais de X horas (uma vez por pedido)
  for r in
    select o.id as order_id, o.number, o.contact_id, o.conversation_id, min(p.criado_em) as desde
      from public.orders o join public.pagamentos p on p.order_id = o.id and p.eh_link
     where o.payment_status <> 'aprovado' and not o.teste and o.stage not in ('cancelado', 'perdido', 'entregue')
       and p.criado_em < now() - make_interval(hours => v_h_pag) and p.criado_em > now() - interval '7 days'
     group by o.id, o.number, o.contact_id, o.conversation_id
  loop
    v_ref := 'SG-' || lpad(r.number::text, 4, '0');
    v_d := public.alerta_criar('pagamento_pendente_demora', 'baixa', r.contact_id, r.conversation_id, r.order_id,
      format('Pedido %s com link de pagamento há mais de %s h sem pagar.', v_ref, v_h_pag), jsonb_build_object('pedido', v_ref), 'pag_pendente:' || r.order_id::text);
    if not coalesce((v_d ->> 'ja_alertado')::boolean, false) then v_n := v_n + 1; end if;
  end loop;
  -- pago e sem arte há mais de X horas (uma vez por pedido)
  for r in
    select o.id as order_id, o.number, o.contact_id, o.conversation_id from public.orders o
     where o.payment_status = 'aprovado' and not o.teste and o.art_status = 'aguardando'
       and o.stage not in ('cancelado', 'perdido', 'entregue', 'pronto')
       and o.payment_confirmed_at < now() - make_interval(hours => v_h_arte) and o.payment_confirmed_at > now() - interval '14 days'
  loop
    v_ref := 'SG-' || lpad(r.number::text, 4, '0');
    v_d := public.alerta_criar('pedido_sem_arte', 'baixa', r.contact_id, r.conversation_id, r.order_id,
      format('Pedido %s pago e sem arte há mais de %s h.', v_ref, v_h_arte), jsonb_build_object('pedido', v_ref), 'sem_arte:' || r.order_id::text);
    if not coalesce((v_d ->> 'ja_alertado')::boolean, false) then v_n := v_n + 1; end if;
  end loop;
  -- padrão incomum de desconto: a função da Etapa 3 grava a linha; aqui só definimos os canais e o agrupamento
  perform public.detectar_padroes_desconto();
  v_pref := coalesce(v_cfg -> 'tipos' -> 'politica_desconto', '{"push":true,"whatsapp":true}'::jsonb);
  update public.alertas set
    status_whatsapp = case when coalesce((v_pref ->> 'whatsapp')::boolean, true) then 'agrupado' else 'desligado' end,
    status_push = case when coalesce((v_pref ->> 'push')::boolean, true) then 'agrupado' else 'desligado' end
  where tipo like 'padrao_desconto%' and status_whatsapp is null and status_push is null;
  return jsonb_build_object('ok', true, 'alertas_criados', v_n);
end;
$$;
revoke execute on function public.alertas_varredura() from public, anon, authenticated;
grant execute on function public.alertas_varredura() to service_role;

-- ---------------------------------------------------------------- 7. gatilhos: problema de pagamento e nova mensagem em modo humano
create or replace function private.trg_pagamento_alerta() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_conv uuid; v_contact uuid; v_ref text;
begin
  begin
    if new.order_id is not null then
      select conversation_id, contact_id, 'SG-' || lpad(number::text, 4, '0') into v_conv, v_contact, v_ref from public.orders where id = new.order_id;
    end if;
    -- estorno, contestação e demais problemas: gravidade alta, sem tocar no pedido
    perform public.alerta_criar('pagamento_problema', 'alta', v_contact, v_conv, new.order_id,
      left(coalesce(new.mensagem, 'Problema no pagamento.'), 280), jsonb_build_object('pedido', v_ref, 'tipo_original', new.tipo), 'pagalerta:' || new.id::text);
  exception when others then
    raise warning 'alerta de pagamento não criado: %', sqlerrm;
  end;
  return new;
end;
$$;
revoke execute on function private.trg_pagamento_alerta() from public, anon, authenticated;
drop trigger if exists pagamentos_alertas_notifica on public.pagamentos_alertas;
create trigger pagamentos_alertas_notifica after insert on public.pagamentos_alertas for each row execute function private.trg_pagamento_alerta();

create or replace function private.trg_mensagem_humano() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_cv public.conversations%rowtype; v_wa text; v_dono text;
begin
  if new.direction <> 'in' then return new; end if;
  begin
    select * into v_cv from public.conversations where id = new.conversation_id;
    if not found or v_cv.modo_atendimento <> 'humano' then return new; end if;
    select wa_id into v_wa from public.contacts where id = v_cv.contact_id;
    select whatsapp_dono into v_dono from public.agente_config where id = 1;
    if v_wa is not distinct from v_dono then return new; end if;   -- o próprio dono falando com o número comercial
    -- o dono já está respondendo agora: sem aviso
    if exists (select 1 from public.messages where conversation_id = new.conversation_id and direction = 'out' and created_at > now() - interval '5 minutes') then return new; end if;
    perform public.alerta_criar('nova_mensagem_humano', 'alta', v_cv.contact_id, new.conversation_id, null, 'Nova mensagem do cliente (atendimento humano).', '{}'::jsonb);
  exception when others then
    raise warning 'alerta de mensagem não criado: %', sqlerrm;
  end;
  return new;
end;
$$;
revoke execute on function private.trg_mensagem_humano() from public, anon, authenticated;
drop trigger if exists messages_notifica_humano on public.messages;
create trigger messages_notifica_humano after insert on public.messages for each row execute function private.trg_mensagem_humano();

-- ---------------------------------------------------------------- 8. pós-pagamento (WF5): um registro por pedido, idempotente
create table if not exists public.pagamento_pos (
  order_id uuid primary key references public.orders (id) on delete cascade,
  evento_id uuid not null unique references public.eventos_pagamento (id) on delete cascade,
  banco_ok boolean not null default false,
  problemas jsonb not null default '[]'::jsonb,
  lucro_liquido numeric(12, 2),
  taxa_pct numeric(5, 2),
  msg_status text not null default 'pendente' check (msg_status in ('pendente', 'enviando', 'enviado', 'falhou_temp', 'falhou', 'ignorado_teste', 'sem_conversa')),
  msg_tentativas smallint not null default 0,
  msg_erro text,
  msg_inicio_em timestamptz,
  alerta_id uuid references public.alertas (id) on delete set null,
  criado_em timestamptz not null default now(),
  concluido_em timestamptz
);
alter table public.pagamento_pos enable row level security;
revoke all on table public.pagamento_pos from anon;
drop policy if exists pagamento_pos_select on public.pagamento_pos;
create policy pagamento_pos_select on public.pagamento_pos for select to authenticated using (private.is_staff());

create or replace function public.pagamento_pos_pendentes() returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('evento_id', e.id, 'order_id', e.order_id) order by e.criado_em)
    from (select * from public.eventos_pagamento where tipo = 'pagamento_confirmado' and processado_em is null and criado_em > now() - interval '3 days' order by criado_em limit 20) e), '[]'::jsonb);
end;
$$;

-- Parte de banco do WF5: revalida, define modo humano, cancela follow-ups e condições, prepara o alerta ao dono.
create or replace function public.pagamento_pos_processar(p_evento uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  e public.eventos_pagamento%rowtype; o public.orders%rowtype; pos public.pagamento_pos%rowtype; c public.contacts%rowtype;
  v_fin record; v_orc uuid; v_val jsonb; v_prob text[] := '{}'; v_itens text; v_prev text; v_ref text; v_alerta jsonb; v_cfg jsonb := private.notif_cfg();
  v_nome text; v_cv uuid; v_n_fu integer; v_n_cond integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into e from public.eventos_pagamento where id = p_evento and tipo = 'pagamento_confirmado';
  if not found then return jsonb_build_object('ok', false, 'motivo', 'evento_inexistente'); end if;
  select * into o from public.orders where id = e.order_id;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'pedido_inexistente'); end if;

  insert into public.pagamento_pos (order_id, evento_id, msg_status)
  values (o.id, e.id, case when o.teste then 'ignorado_teste' when o.conversation_id is null then 'sem_conversa' else 'pendente' end)
  on conflict (order_id) do nothing;
  select * into pos from public.pagamento_pos where order_id = o.id for update;
  if pos.banco_ok then
    return jsonb_build_object('ok', true, 'ja_processado', true, 'msg_status', pos.msg_status, 'order_id', o.id);
  end if;

  select * into c from public.contacts where id = o.contact_id;
  v_ref := 'SG-' || lpad(o.number::text, 4, '0');
  v_nome := coalesce(nullif(split_part(trim(coalesce(c.name, '')), ' ', 1), ''), 'cliente');
  select total, net_profit into v_fin from public.order_financials where order_id = o.id;

  -- 1) revalidação (pagamento nunca é desfeito: só registra e alerta)
  if exists (select 1 from public.order_items where order_id = o.id and (code is null or trim(code) = '')) then v_prob := array_append(v_prob, 'item_sem_sku'); end if;
  if coalesce(v_fin.net_profit, 0) < 0 then v_prob := array_append(v_prob, 'lucro_liquido_negativo'); end if;
  select id into v_orc from public.orcamentos where order_id = o.id order by criado_em desc limit 1;
  if v_orc is not null then
    begin
      v_val := public.validar_margem(v_orc);
      if coalesce(v_val ->> 'status', 'ok') <> 'ok' then v_prob := array_append(v_prob, 'margem_fora_da_regra:' || coalesce(v_val ->> 'motivo', 'sem_motivo')); end if;
    exception when others then null;   -- validação indisponível não vira falso alarme
    end;
  end if;

  -- 2) lucro líquido real com a taxa do método pago (confirmar_pagamento já gravou; aqui garante)
  update public.orders set lucro_liquido_real = coalesce(lucro_liquido_real, v_fin.net_profit), taxa_pagamento_real_pct = coalesce(taxa_pagamento_real_pct, payment_fee_pct) where id = o.id
  returning taxa_pagamento_real_pct into pos.taxa_pct;

  -- 3) o agente PARA nesta conversa; follow-ups pendentes cancelados; condições abertas do pedido invalidadas
  if o.conversation_id is not null then
    update public.conversations set modo_atendimento = 'humano', needs_human = true where id = o.conversation_id;
    v_cv := o.conversation_id;
  end if;
  update public.followup_fila set status = 'cancelado', motivo = 'pedido_pago'
   where status = 'pendente' and (order_id = o.id or orcamento_id in (select id from public.orcamentos where order_id = o.id)
         or (contact_id = o.contact_id and regra_codigo in ('F1', 'F2', 'F3', 'F4', 'PAG_1H', 'PAG_6H', 'PAG_24H')));
  get diagnostics v_n_fu = row_count;
  update public.condicoes_especiais set resultado = 'cancelada'
   where resultado = 'oferecida' and orcamento_id in (select id from public.orcamentos where order_id = o.id);
  get diagnostics v_n_cond = row_count;

  -- 4) alerta ao dono (pedido pago) e, se houver, alerta separado de fora das regras
  select string_agg(format('%sx %s%s', qty, left(description, 40), case when code is not null and trim(code) <> '' then ' (' || trim(code) || ')' else '' end), '; ' order by created_at)
    into v_itens from public.order_items where order_id = o.id;
  v_prev := coalesce(to_char(o.due_date, 'DD/MM'), 'a confirmar');
  v_alerta := public.alerta_criar('pedido_pago', 'alta', o.contact_id, o.conversation_id, o.id,
    format('%sPedido %s pago por %s: %s.', case when o.teste then '[TESTE] ' else '' end, v_ref, coalesce(c.name, 'cliente'), private.brl_milhar(v_fin.total)),
    jsonb_build_object('pedido', v_ref, 'cliente', coalesce(nullif(trim(c.name), ''), 'Cliente sem nome'), 'itens', left(coalesce(v_itens, 'sem itens'), 300),
      'valor', private.brl_milhar(v_fin.total), 'metodo', coalesce(e.payload ->> 'metodo', o.payment_method), 'lucro_liquido', private.brl_milhar(v_fin.net_profit),
      'previsao', v_prev, 'teste', o.teste, 'url', coalesce(v_cfg ->> 'url_base', 'https://crm.suagraficabh.com.br') || '/kanban?pedido=' || o.id::text),
    'pedido_pago:' || o.id::text);
  if array_length(v_prob, 1) > 0 then
    perform public.alerta_criar('pedido_fora_das_regras', 'alta', o.contact_id, o.conversation_id, o.id,
      format('Pedido %s pago, mas fora das regras: %s. O pagamento foi mantido.', v_ref, array_to_string(v_prob, ', ')),
      jsonb_build_object('pedido', v_ref, 'problemas', to_jsonb(v_prob)), 'fora_das_regras:' || o.id::text);
  end if;

  update public.pagamento_pos set banco_ok = true, problemas = to_jsonb(v_prob), lucro_liquido = v_fin.net_profit, taxa_pct = pos.taxa_pct,
    alerta_id = (v_alerta ->> 'alerta_id')::uuid where order_id = o.id;
  -- sem mensagem a enviar: o evento já está tratado
  if pos.msg_status in ('ignorado_teste', 'sem_conversa') then
    update public.pagamento_pos set concluido_em = now() where order_id = o.id;
    update public.eventos_pagamento set processado_em = now() where id = e.id;
  end if;
  insert into public.agent_logs (conversation_id, actor, action, detail, result)
  values (v_cv, 'sistema', 'pagamento_pos', jsonb_build_object('pedido', v_ref, 'problemas', to_jsonb(v_prob), 'followups_cancelados', v_n_fu, 'condicoes_canceladas', v_n_cond), 'ok');
  return jsonb_build_object('ok', true, 'order_id', o.id, 'msg_status', pos.msg_status, 'problemas', to_jsonb(v_prob), 'followups_cancelados', v_n_fu, 'condicoes_canceladas', v_n_cond);
end;
$$;
revoke execute on function public.pagamento_pos_pendentes() from public, anon, authenticated;
revoke execute on function public.pagamento_pos_processar(uuid) from public, anon, authenticated;
grant execute on function public.pagamento_pos_pendentes() to service_role;
grant execute on function public.pagamento_pos_processar(uuid) to service_role;

-- Reserva a mensagem ao cliente (impede envio duplo) e devolve o necessário para montar o texto.
create or replace function public.pagamento_pos_reservar_msg(p_order uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  pos public.pagamento_pos%rowtype; o public.orders%rowtype; c public.contacts%rowtype; cv public.conversations%rowtype; v_ref text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.pagamento_pos set msg_status = 'enviando', msg_inicio_em = now(), msg_tentativas = msg_tentativas + 1
   where order_id = p_order and banco_ok and msg_tentativas < 3
     and (msg_status in ('pendente', 'falhou_temp') or (msg_status = 'enviando' and msg_inicio_em < now() - interval '5 minutes'))
  returning * into pos;
  if not found then
    select * into pos from public.pagamento_pos where order_id = p_order;
    return jsonb_build_object('ok', true, 'enviar', false, 'msg_status', pos.msg_status);
  end if;
  select * into o from public.orders where id = p_order;
  select * into c from public.contacts where id = o.contact_id;
  select * into cv from public.conversations where id = o.conversation_id;
  v_ref := 'SG-' || lpad(o.number::text, 4, '0');
  return jsonb_build_object('ok', true, 'enviar', true, 'tentativa', pos.msg_tentativas,
    'wa_id', c.wa_id, 'conversation_id', cv.id, 'nome', coalesce(nullif(split_part(trim(coalesce(c.name, '')), ' ', 1), ''), 'cliente'),
    'pedido', v_ref, 'previsao', coalesce(to_char(o.due_date, 'DD/MM'), 'a confirmar'),
    'arte_status', o.art_status, 'entrega', o.delivery_method,
    'janela_ate', greatest(cv.last_inbound_at + interval '24 hours', coalesce(cv.ad_window_until, 'epoch'::timestamptz)));
end;
$$;

create or replace function public.pagamento_pos_msg_resultado(p_order uuid, p_status text, p_erro text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare pos public.pagamento_pos%rowtype; v_final text; v_ref text; o public.orders%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_status not in ('enviado', 'falhou_temp') then return jsonb_build_object('ok', false, 'motivo', 'status_invalido'); end if;
  select * into pos from public.pagamento_pos where order_id = p_order for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'sem_registro'); end if;
  v_final := case when p_status = 'falhou_temp' and pos.msg_tentativas >= 3 then 'falhou' else p_status end;
  update public.pagamento_pos set msg_status = v_final, msg_erro = left(p_erro, 300),
    concluido_em = case when v_final in ('enviado', 'falhou') then now() else null end where order_id = p_order;
  if v_final in ('enviado', 'falhou') then
    update public.eventos_pagamento set processado_em = now() where id = pos.evento_id;
  end if;
  if v_final = 'falhou' then
    select * into o from public.orders where id = p_order;
    v_ref := 'SG-' || lpad(o.number::text, 4, '0');
    perform public.alerta_criar('mensagem_cliente_falhou', 'alta', o.contact_id, o.conversation_id, o.id,
      format('Não consegui avisar o cliente do pedido %s depois de 3 tentativas. Envie a confirmação manualmente.', v_ref), jsonb_build_object('pedido', v_ref), 'msg_cliente_falhou:' || p_order::text);
  end if;
  return jsonb_build_object('ok', true, 'msg_status', v_final);
end;
$$;
revoke execute on function public.pagamento_pos_reservar_msg(uuid) from public, anon, authenticated;
revoke execute on function public.pagamento_pos_msg_resultado(uuid, text, text) from public, anon, authenticated;
grant execute on function public.pagamento_pos_reservar_msg(uuid) to service_role;
grant execute on function public.pagamento_pos_msg_resultado(uuid, text, text) to service_role;

-- destinatário e janela do dono (para o dispatcher escolher texto livre ou template)
create or replace function public.alerta_destino_dono() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_wa text; v_janela timestamptz;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select whatsapp_dono into v_wa from public.agente_config where id = 1;
  select greatest(cv.last_inbound_at + interval '24 hours', coalesce(cv.ad_window_until, 'epoch'::timestamptz)) into v_janela
    from public.conversations cv join public.contacts c on c.id = cv.contact_id where c.wa_id = v_wa;
  return jsonb_build_object('wa_id', v_wa, 'janela_ate', v_janela, 'janela_aberta', coalesce(v_janela > now(), false),
    'templates', coalesce((select jsonb_object_agg(name, status) from public.templates_cache where name in ('pedido_pago_dono', 'alerta_atencao_dono') and language = 'pt_BR'), '{}'::jsonb));
end;
$$;
revoke execute on function public.alerta_destino_dono() from public, anon, authenticated;
grant execute on function public.alerta_destino_dono() to service_role;

-- ---------------------------------------------------------------- 9. o número do dono nunca é atendido pelo agente
-- O dono responde os alertas pelo mesmo número comercial; sem esta trava o agente trataria o dono como cliente novo.
create or replace function public.agente_bloqueio(p_conversation uuid) returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  cfg record;
  v_global boolean;
  v_conv record;
  v_hora time;
  v_dow int;
  v_dias jsonb;
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

  select cv.contact_id, cv.modo_atendimento, cv.ai_handled, ct.optout, ct.wa_id into v_conv
  from public.conversations cv join public.contacts ct on ct.id = cv.contact_id where cv.id = p_conversation;
  if not found then return 'conversa_inexistente'; end if;
  if v_conv.wa_id is not distinct from cfg.whatsapp_dono then return 'numero_do_dono'; end if;
  if coalesce(v_conv.optout, false) then return 'optout'; end if;
  if coalesce(v_conv.modo_atendimento, 'ia') <> 'ia' or not coalesce(v_conv.ai_handled, true) then return 'modo_humano'; end if;

  if exists (
    select 1 from public.orders o
    where o.contact_id = v_conv.contact_id and o.stage in ('pago', 'arte', 'prova', 'producao')
  ) then return 'pedido_pago'; end if;
  return null;
end;
$$;

-- chaves VAPID geradas pela própria função na primeira vez, se os segredos de ambiente não existirem.
-- Tabela fechada: sem política, sem acesso de anon e de usuário logado; só a service role lê.
create table if not exists public.app_segredos (
  chave text primary key,
  valor text not null,
  criado_em timestamptz not null default now()
);
alter table public.app_segredos enable row level security;
revoke all on table public.app_segredos from anon, authenticated;
