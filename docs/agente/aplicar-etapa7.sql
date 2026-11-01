-- Etapa 7: follow-ups (com condição especial), pós-venda e recompra, status do pedido, painel de pedidos e observabilidade.
-- Aditiva e idempotente. Toda decisão (quem recebe, quando, qual texto, qual condição) é do banco; o n8n só orquestra e o modelo não escolhe nada.
-- Funções que o n8n e as Edge Functions chamam aceitam `p_agora` para os testes com relógio acelerado.

-- ---------------------------------------------------------------------------------------------------------------------
-- 0. Configuração (editável pelo dono)
-- ---------------------------------------------------------------------------------------------------------------------
insert into public.app_settings (key, value) values
  ('followup', '{"max_por_dia":1,"exigir_optin_marketing":true,"tentativas_max":3,"liberar_travados_min":15}'),
  ('retirada', '{"endereco":"R. Rio de Janeiro, 462, 22º andar, Sala 2217, Centro, Belo Horizonte, MG, 30160-040","horario_texto":"segunda a quinta das 9h às 17h e sexta das 9h às 18h30"}'),
  ('observabilidade', '{"teto_custo_dia_brl":15,"custo_template_marketing_brl":0.35,"custo_template_utilidade_brl":0.04,"nota":"custos de template são estimativas; revise com a fatura da Meta"}')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------------------------------------------------
-- 1. Colunas novas
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.followup_fila drop constraint if exists followup_fila_status_check;
alter table public.followup_fila add constraint followup_fila_status_check
  check (status in ('pendente', 'reservado', 'enviado', 'cancelado', 'pulado', 'erro'));
alter table public.followup_fila add column if not exists via text check (via is null or via in ('livre', 'template', 'simulado'));
alter table public.followup_fila add column if not exists reservado_em timestamptz;
alter table public.followup_fila add column if not exists template text;
alter table public.followup_fila add column if not exists wa_message_id text;
alter table public.followup_fila add column if not exists condicao_id uuid references public.condicoes_especiais (id) on delete set null;
alter table public.followup_fila add column if not exists manual boolean not null default false;
alter table public.followup_fila add column if not exists grupo_produto text;
alter table public.followup_fila add column if not exists produto text;
alter table public.followup_fila add column if not exists teste boolean not null default false;
create index if not exists followup_fila_contato_idx on public.followup_fila (contact_id, enviado_em desc);
create index if not exists followup_fila_regra_idx on public.followup_fila (regra_codigo, status);

alter table public.condicoes_especiais add column if not exists followup_codigo text;
alter table public.condicoes_especiais add column if not exists followup_via text;
alter table public.condicoes_especiais add column if not exists followup_enviado_em timestamptz;
alter table public.precos_praticados add column if not exists followup_codigo text;
alter table public.precos_praticados add column if not exists followup_via text;
alter table public.precos_praticados add column if not exists followup_em timestamptz;

alter table public.orders add column if not exists enviado_fabrica_em timestamptz;
alter table public.orders add column if not exists subestatus_em timestamptz;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orders_subestatus_check') then
    alter table public.orders add constraint orders_subestatus_check
      check (subestatus_pedido is null or subestatus_pedido in ('em_producao', 'pronto_retirada', 'saiu_entrega'));
  end if;
end $$;
create index if not exists orders_fabrica_idx on public.orders (stage) where enviado_fabrica_em is null;

-- Avisos de status do pedido (idempotência: nunca dois avisos do mesmo tipo; a tela mostra o resultado)
create table if not exists public.pedido_avisos (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  tipo text not null check (tipo in ('pronto_retirada', 'saiu_entrega')),
  status text not null default 'pendente' check (status in ('pendente', 'reservado', 'enviado', 'falhou', 'pulado')),
  via text check (via is null or via in ('livre', 'template', 'simulado')),
  wa_message_id text,
  tentativas smallint not null default 0,
  erro text,
  criado_em timestamptz not null default now(),
  reservado_em timestamptz,
  proxima_tentativa timestamptz not null default now(),
  enviado_em timestamptz,
  unique (order_id, tipo)
);
alter table public.pedido_avisos enable row level security;
revoke all on table public.pedido_avisos from anon;
drop policy if exists pedido_avisos_dono on public.pedido_avisos;
create policy pedido_avisos_dono on public.pedido_avisos for select to authenticated using (private.is_staff());
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'pedido_avisos') then
    alter publication supabase_realtime add table public.pedido_avisos;
  end if;
exception when others then null; end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 2. Auxiliares
-- ---------------------------------------------------------------------------------------------------------------------
-- Próxima hora válida (America/Sao_Paulo) dentro de [hmin, hmax)
create or replace function private.fu_proxima_janela(p_ts timestamptz, p_hmin int, p_hmax int) returns timestamptz
language plpgsql immutable set search_path = ''
as $$
declare v_l timestamp := p_ts at time zone 'America/Sao_Paulo';
begin
  if extract(hour from v_l) < p_hmin then v_l := date_trunc('day', v_l) + make_interval(hours => p_hmin);
  elsif extract(hour from v_l) >= p_hmax then v_l := date_trunc('day', v_l) + interval '1 day' + make_interval(hours => p_hmin);
  end if;
  return v_l at time zone 'America/Sao_Paulo';
end;
$$;

create or replace function private.fu_cfg() returns jsonb
language sql stable set search_path = ''
as $$ select coalesce((select value from public.app_settings where key = 'followup'), '{}'::jsonb); $$;

create or replace function private.fu_nome(p_nome text) returns text
language sql immutable set search_path = ''
as $$ select coalesce(nullif(initcap(split_part(trim(coalesce(p_nome, '')), ' ', 1)), ''), 'cliente'); $$;

create or replace function private.fu_pausada() returns boolean
language sql stable set search_path = ''
as $$
  select not (coalesce((select ia_ligada from public.agente_config where id = 1), false)
              and coalesce((select (value ->> 'enabled')::boolean from public.app_settings where key = 'agent'), false));
$$;

-- Próximo horário de atendimento a partir de p_ts: {quando, aberto_agora, abre, fecha, dia}
create or replace function private.proximo_atendimento(p_ts timestamptz) returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  h jsonb; v_l timestamp := p_ts at time zone 'America/Sao_Paulo'; d date; i int; k text; ab time; fe time; v_dias text[] := array['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado'];
begin
  select horario_atendimento into h from public.parametros_comerciais limit 1;
  for i in 0..21 loop
    d := v_l::date + i;
    k := (array['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sab'])[extract(dow from d)::int + 1];
    continue when h is null or h -> k is null or jsonb_typeof(h -> k) = 'null' or not public.is_business_day(d);
    ab := (h -> k ->> 'abre')::time; fe := (h -> k ->> 'fecha')::time;
    if i = 0 and v_l::time >= fe then continue; end if;
    if i = 0 and v_l::time >= ab then
      return jsonb_build_object('quando', p_ts, 'aberto_agora', true, 'fecha', to_char(fe, 'HH24"h"MI'), 'abre', to_char(ab, 'HH24"h"MI'), 'dia', v_dias[extract(dow from d)::int + 1], 'data', to_char(d, 'DD/MM'));
    end if;
    return jsonb_build_object('quando', (d + ab) at time zone 'America/Sao_Paulo', 'aberto_agora', false, 'fecha', to_char(fe, 'HH24"h"MI'),
      'abre', to_char(ab, 'HH24"h"MI'), 'dia', v_dias[extract(dow from d)::int + 1], 'data', to_char(d, 'DD/MM'));
  end loop;
  return jsonb_build_object('quando', null, 'aberto_agora', false);
end;
$$;

-- hora cheia: "09h00" vira "9h"
create or replace function private.fu_hora_txt(p_hhmm text) returns text
language sql immutable set search_path = ''
as $$ select regexp_replace(regexp_replace(p_hhmm, '^0', ''), 'h00$', 'h'); $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 3. Subestatus limpo ao sair da Produção
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function private.orders_subestatus_ajusta() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.stage is distinct from old.stage then
    new.subestatus_pedido := case when new.stage = 'producao' then 'em_producao' else null end;
    new.subestatus_em := case when new.stage = 'producao' then now() else null end;
  end if;
  return new;
end;
$$;
drop trigger if exists orders_subestatus_ajusta on public.orders;
create trigger orders_subestatus_ajusta before update of stage on public.orders for each row execute function private.orders_subestatus_ajusta();

-- ---------------------------------------------------------------------------------------------------------------------
-- 4. Agendamento da fila (varredura idempotente; chave única por regra e origem)
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function private.fu_agendar_pos(p_order uuid, p_agora timestamptz default now()) returns integer
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; r record; v_ref timestamptz; v_n integer := 0; v_id uuid; v_prod text;
begin
  select * into o from public.orders where id = p_order;
  if not found or o.stage <> 'entregue' then return 0; end if;
  v_ref := coalesce(o.delivered_at, o.stage_entered_at, p_agora);
  for r in select * from public.followup_regras where ativo and referencia = 'pedido_entregue' loop
    v_prod := null;
    if r.grupo_produto is not null then
      select i.description into v_prod from public.order_items i join public.catalogo c on c.sku = i.code
       where i.order_id = o.id
         and upper(extensions.unaccent(coalesce(c.grupo_produto, c.categoria, ''))) like upper(extensions.unaccent(split_part(r.grupo_produto, ' ', 1))) || '%'
       limit 1;
      continue when v_prod is null;   -- esse pedido não tem o produto da regra
    else
      select i.description into v_prod from public.order_items i where i.order_id = o.id order by i.created_at limit 1;
    end if;
    insert into public.followup_fila (contact_id, conversation_id, order_id, regra_codigo, chave, agendado_para, grupo_produto, produto, teste)
    select o.contact_id, o.conversation_id, o.id, r.codigo, r.codigo || ':' || o.id::text,
           private.fu_proxima_janela(v_ref + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max), r.grupo_produto,
           left(coalesce(v_prod, o.title), 80), coalesce(o.teste, false)
    on conflict (chave) do nothing returning id into v_id;
    if v_id is not null then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end;
$$;
revoke execute on function private.fu_agendar_pos(uuid, timestamptz) from public, anon, authenticated;

create or replace function private.orders_entregue_agenda() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.stage = 'entregue' and old.stage is distinct from 'entregue' then
    perform private.fu_agendar_pos(new.id);
    update public.followup_fila set status = 'cancelado', motivo = 'pedido_entregue'
     where order_id = new.id and status = 'pendente' and regra_codigo like 'PAG%';
  end if;
  return new;
end;
$$;
drop trigger if exists orders_entregue_agenda on public.orders;
create trigger orders_entregue_agenda after update of stage on public.orders for each row execute function private.orders_entregue_agenda();

create or replace function public.followup_agendar(p_agora timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_orc integer := 0; v_pag integer := 0; v_pos integer := 0; r record; q record; v_n integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  -- cadência do orçamento enviado: F1 a F4
  for r in select * from public.followup_regras where ativo and referencia = 'orcamento_enviado' loop
    insert into public.followup_fila (contact_id, conversation_id, orcamento_id, regra_codigo, chave, agendado_para, teste, produto)
    select o.contact_id, o.conversation_id, o.id, r.codigo, r.codigo || ':' || o.id::text,
           private.fu_proxima_janela(o.pdf_enviado_em + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max), o.teste,
           (select left(i.descricao, 80) from public.orcamento_itens i where i.orcamento_id = o.id order by i.criado_em limit 1)
      from public.orcamentos o
     where o.status = 'enviado' and o.pdf_enviado_em is not null and o.origem_id is null and o.pdf_enviado_em > p_agora - interval '10 days'
       and not exists (select 1 from public.conversations cv where cv.id = o.conversation_id and cv.last_inbound_at > o.pdf_enviado_em + interval '1 minute')
    on conflict (chave) do nothing;
    get diagnostics v_n = row_count; v_orc := v_orc + v_n;
  end loop;
  -- pagamento pendente: link ativo sem pagamento
  for r in select * from public.followup_regras where ativo and referencia = 'link_pagamento' loop
    insert into public.followup_fila (contact_id, conversation_id, orcamento_id, order_id, regra_codigo, chave, agendado_para, teste)
    select ord.contact_id, ord.conversation_id,
           (select oc.id from public.orcamentos oc where oc.order_id = ord.id order by oc.criado_em desc limit 1), ord.id,
           r.codigo, r.codigo || ':' || ord.id::text,
           private.fu_proxima_janela(p.criado_em + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max), coalesce(ord.teste, false)
      from public.pagamentos p join public.orders ord on ord.id = p.order_id
     where p.eh_link and p.link_ativo and p.status = 'pendente' and (p.expira_em is null or p.expira_em > p_agora)
       and ord.payment_status <> 'aprovado' and ord.stage in ('novo', 'cotando', 'aguardando_pagamento')
       and p.criado_em > p_agora - interval '3 days'
    on conflict (chave) do nothing;
    get diagnostics v_n = row_count; v_pag := v_pag + v_n;
  end loop;
  -- pós-venda: pedidos entregues sem as linhas ainda (o gatilho cobre o fluxo normal; isto cobre atrasos e importações)
  for q in select id from public.orders where stage = 'entregue' and delivered_at > p_agora - interval '120 days' loop
    v_pos := v_pos + private.fu_agendar_pos(q.id, p_agora);
  end loop;
  return jsonb_build_object('ok', true, 'orcamento', v_orc, 'pagamento', v_pag, 'pos', v_pos);
end;
$$;
revoke execute on function public.followup_agendar(timestamptz) from public, anon;

-- O agente pode reagendar depois que o cliente respondeu (ex.: "vou pensar"): reabre a linha cancelada por resposta
create or replace function public.agente_agendar_followup(p_conversation uuid, p_tipo text, p_quando text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_cv public.conversations%rowtype; v_orc record; v_regra record; v_codigo text; v_base timestamptz; v_quando timestamptz; v_id uuid; v_chave text;
begin
  select * into v_cv from public.conversations where id = p_conversation;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'conversa_inexistente'); end if;
  v_codigo := case
    when p_tipo = 'orcamento' and p_quando = '2h' then 'F1' when p_tipo = 'orcamento' and p_quando = '20h' then 'F2'
    when p_tipo = 'orcamento' and p_quando = 'dia2' then 'F3' when p_tipo = 'orcamento' and p_quando = 'dia5' then 'F4'
    when p_tipo = 'pagamento' and p_quando = '1h' then 'PAG_1H' when p_tipo = 'pagamento' and p_quando = '6h' then 'PAG_6H'
    when p_tipo = 'pagamento' and p_quando = '24h' then 'PAG_24H' end;
  if v_codigo is null then return jsonb_build_object('ok', false, 'motivo', 'combinacao_invalida', 'orientacao', 'tipo orcamento: 2h, 20h, dia2, dia5. tipo pagamento: 1h, 6h, 24h.'); end if;
  select * into v_regra from public.followup_regras where codigo = v_codigo and ativo;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'regra_inativa'); end if;
  select id, coalesce(pdf_enviado_em, atualizado_em) as ref into v_orc from public.orcamentos
   where contact_id = v_cv.contact_id and status in ('rascunho', 'enviado', 'aceito') and (validade_ate is null or validade_ate > now())
   order by criado_em desc limit 1;
  if v_orc.id is null then return jsonb_build_object('ok', false, 'motivo', 'sem_orcamento_aberto'); end if;
  v_base := coalesce(v_orc.ref, now());
  v_quando := private.fu_proxima_janela(greatest(v_base + make_interval(mins => v_regra.atraso_minutos), now()), v_regra.hora_min, v_regra.hora_max);
  v_chave := v_codigo || ':' || v_orc.id::text;
  insert into public.followup_fila (contact_id, conversation_id, orcamento_id, regra_codigo, chave, agendado_para)
  values (v_cv.contact_id, p_conversation, v_orc.id, v_codigo, v_chave, v_quando)
  on conflict (chave) do update set status = 'pendente', motivo = null, agendado_para = excluded.agendado_para, conversation_id = excluded.conversation_id
    where public.followup_fila.status = 'cancelado' and public.followup_fila.motivo = 'cliente_respondeu'
  returning id into v_id;
  return jsonb_build_object('ok', true, 'ja_agendado', v_id is null, 'regra', v_codigo,
    'quando', to_char(v_quando at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI'));
end;
$$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 5. Reserva dos envios devidos (as guardas ficam aqui, em SQL)
-- ---------------------------------------------------------------------------------------------------------------------
-- p_familia: 'cadencia' (F1 a F4 e PAG_*) ou 'pos' (POS_ENTREGA e RECOMPRA_*)
create or replace function public.followup_reservar(p_familia text, p_limite integer default 20, p_agora timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  f public.followup_fila%rowtype; r public.followup_regras%rowtype; o public.orcamentos%rowtype; ord public.orders%rowtype; ct public.contacts%rowtype; cv public.conversations%rowtype;
  v_cfg jsonb := private.fu_cfg(); v_max integer := coalesce((v_cfg ->> 'max_por_dia')::integer, 1); v_tent integer := coalesce((v_cfg ->> 'tentativas_max')::integer, 3);
  v_itens jsonb := '[]'::jsonb; v_motivo text; v_novo timestamptz; v_hoje date := (p_agora at time zone 'America/Sao_Paulo')::date; v_ref timestamptz; v_cadencia boolean := p_familia = 'cadencia';
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_familia not in ('cadencia', 'pos') then raise exception 'Família inválida.'; end if;
  for f in
    select * from public.followup_fila
     where status = 'pendente' and agendado_para <= p_agora
       and ((v_cadencia and regra_codigo ~ '^(F[1-4]|PAG_)') or (not v_cadencia and regra_codigo ~ '^(POS_|RECOMPRA_)'))
     order by agendado_para limit greatest(p_limite, 1) for update skip locked
  loop
    v_motivo := null; v_novo := null;
    select * into r from public.followup_regras where codigo = f.regra_codigo;
    select * into ct from public.contacts where id = f.contact_id;
    select * into cv from public.conversations where id = coalesce(f.conversation_id, (select id from public.conversations where contact_id = f.contact_id limit 1));
    select * into o from public.orcamentos where id = f.orcamento_id;
    select * into ord from public.orders where id = f.order_id;

    -- cancelamentos definitivos
    if not coalesce(r.ativo, false) then v_motivo := 'regra_inativa';
    elsif coalesce(ct.optout, false) then v_motivo := 'optout';
    elsif v_cadencia and (
        coalesce(o.status, '') = 'pago' or coalesce(ord.payment_status, '') = 'aprovado' or coalesce(ord.payment_manual, false)
        or exists (select 1 from public.orders x where x.contact_id = f.contact_id and x.stage in ('pago', 'arte', 'prova', 'producao', 'entregue')
                      and coalesce(x.paid_at, x.created_at) >= coalesce(o.pdf_enviado_em, o.criado_em, f.criado_em))) then v_motivo := 'pago';
    elsif v_cadencia and f.regra_codigo ~ '^F[1-4]$' and (o.id is null or o.status not in ('enviado', 'aceito')) then v_motivo := 'orcamento_encerrado';
    elsif v_cadencia and f.regra_codigo ~ '^F[1-4]$' and o.validade_ate is not null and o.validade_ate < p_agora then v_motivo := 'orcamento_vencido';
    elsif v_cadencia and f.regra_codigo ~ '^PAG_' and not exists (
        select 1 from public.pagamentos p where p.order_id = f.order_id and p.eh_link and p.link_ativo and p.status = 'pendente' and (p.expira_em is null or p.expira_em > p_agora)) then v_motivo := 'link_inativo';
    elsif v_cadencia and coalesce(cv.modo_atendimento, 'ia') <> 'ia' then v_motivo := 'modo_humano';
    elsif not v_cadencia and f.regra_codigo like 'RECOMPRA_%' and exists (
        select 1 from public.orders x join public.order_items xi on xi.order_id = x.id join public.catalogo xc on xc.sku = xi.code
         where x.contact_id = f.contact_id and x.id <> f.order_id and x.created_at > coalesce(ord.delivered_at, ord.stage_entered_at)
           and upper(extensions.unaccent(coalesce(xc.grupo_produto, xc.categoria, ''))) like upper(extensions.unaccent(split_part(coalesce(f.grupo_produto, ''), ' ', 1))) || '%') then v_motivo := 'recomprou';
    elsif not v_cadencia and f.regra_codigo like 'RECOMPRA_%' and ct.marketing_consent = 'opted_out' then v_motivo := 'optout';
    end if;
    if v_motivo is not null then
      update public.followup_fila set status = case when v_motivo in ('modo_humano', 'link_inativo') then 'pulado' else 'cancelado' end, motivo = v_motivo where id = f.id;
      continue;
    end if;

    -- adiamentos (continuam pendentes)
    if private.fu_pausada() then v_novo := p_agora + interval '60 minutes';
    elsif extract(hour from p_agora at time zone 'America/Sao_Paulo') < r.hora_min or extract(hour from p_agora at time zone 'America/Sao_Paulo') >= r.hora_max then
      v_novo := private.fu_proxima_janela(p_agora, r.hora_min, r.hora_max);
    elsif (select count(*) from public.followup_fila x where x.contact_id = f.contact_id and x.id <> f.id and x.status in ('enviado', 'reservado')
             and (coalesce(x.enviado_em, x.reservado_em) at time zone 'America/Sao_Paulo')::date = v_hoje) >= v_max then
      v_novo := private.fu_proxima_janela((date_trunc('day', p_agora at time zone 'America/Sao_Paulo') + interval '1 day' + make_interval(hours => r.hora_min)) at time zone 'America/Sao_Paulo', r.hora_min, r.hora_max);
    end if;
    if v_novo is not null then
      update public.followup_fila set agendado_para = greatest(v_novo, p_agora + interval '1 minute'), motivo = 'adiado' where id = f.id;
      continue;
    end if;

    update public.followup_fila set status = 'reservado', reservado_em = p_agora, tentativas = tentativas + 1, motivo = null where id = f.id;
    v_itens := v_itens || jsonb_build_object(
      'fila_id', f.id, 'regra', f.regra_codigo, 'tentativa', f.tentativas + 1,
      'gatilho', r.gatilho_condicao, 'precisa_condicao', r.gatilho_condicao is not null and f.condicao_id is null,
      'orcamento_id', f.orcamento_id, 'conversation_id', cv.id, 'contact_id', f.contact_id,
      'simular', 'teste' = any (coalesce(ct.tags, '{}')) or f.teste);
  end loop;
  return jsonb_build_object('ok', true, 'itens', v_itens);
end;
$$;
revoke execute on function public.followup_reservar(text, integer, timestamptz) from public, anon, authenticated;
grant execute on function public.followup_reservar(text, integer, timestamptz) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------
-- 6. Montagem da mensagem (textos pré-escritos com variáveis; nenhum valor é calculado aqui)
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.followup_montar(p_fila uuid, p_agora timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  f public.followup_fila%rowtype; r public.followup_regras%rowtype; o public.orcamentos%rowtype; ord public.orders%rowtype; ct public.contacts%rowtype; cv public.conversations%rowtype;
  c public.condicoes_especiais%rowtype; n text; v_num text; v_val text; v_pronto text; v_prod text; v_link text; v_var integer; v_janela boolean; v_texto text; v_tpl text; v_params jsonb;
  v_up text; v_cond_vigente boolean := false; v_ped text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into f from public.followup_fila where id = p_fila;
  if not found then return jsonb_build_object('ok', false, 'acao', 'pular', 'motivo', 'fila_inexistente'); end if;
  select * into r from public.followup_regras where codigo = f.regra_codigo;
  select * into ct from public.contacts where id = f.contact_id;
  select * into cv from public.conversations where id = coalesce(f.conversation_id, (select id from public.conversations where contact_id = f.contact_id limit 1));
  if f.orcamento_id is not null then select * into o from public.orcamentos where id = f.orcamento_id; end if;
  if f.order_id is not null then select * into ord from public.orders where id = f.order_id; end if;
  n := private.fu_nome(ct.name);
  v_var := abs(hashtext(f.id::text)) % 2;
  v_janela := cv.last_inbound_at is not null and cv.last_inbound_at + interval '24 hours' > p_agora;
  v_num := case when o.id is not null then private.orcamento_numero(o.numero) end;
  v_ped := case when ord.id is not null then 'SG-' || lpad(ord.number::text, 4, '0') end;
  v_val := case when o.validade_ate is not null then to_char(o.validade_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"') else 'a data combinada' end;
  v_pronto := to_char(o.data_prevista, 'DD/MM');
  v_prod := coalesce(f.produto, (select left(i.descricao, 80) from public.orcamento_itens i where i.orcamento_id = o.id order by i.criado_em limit 1), 'pedido');

  -- condição especial: a ferramenta já rodou (ou não); o banco só lê o resultado
  if f.regra_codigo in ('F3', 'F4', 'PAG_24H') then
    select * into c from public.condicoes_especiais
     where (orcamento_id = f.orcamento_id or orcamento_novo_id = f.orcamento_id) and resultado = 'oferecida' and valida_ate > p_agora
       and (f.regra_codigo = 'PAG_24H' or (gatilho = r.gatilho_condicao and criado_em >= coalesce(f.reservado_em, f.criado_em) - interval '2 minutes') or id = f.condicao_id)
     order by criado_em desc limit 1;
    v_cond_vigente := found;
    if v_cond_vigente and f.regra_codigo <> 'PAG_24H' then update public.followup_fila set condicao_id = c.id where id = f.id; end if;
  end if;

  if f.regra_codigo = 'F1' then
    v_texto := case v_var
      when 0 then format('Oi, %s! Passando pra saber se ficou alguma dúvida sobre o orçamento %s. A gente cuida da arte e entrega com data certa. Se quiser ajustar quantidade, acabamento ou prazo, é só me falar que eu resolvo rapidinho.', n, v_num)
      else format('Oi, %s! Conseguiu dar uma olhada no orçamento %s? Qualquer dúvida sobre o material ou a arte, me chama por aqui que eu te ajudo.%s', n, v_num,
                  case when o.data_prevista is not null then ' Fechando, o pedido fica pronto dia ' || v_pronto || '.' else '' end) end;
  elsif f.regra_codigo = 'F2' then
    v_texto := format('Oi, %s! O orçamento %s vale até %s%s. Quer que eu reenvie o link de pagamento?', n, v_num, v_val,
                      case when o.data_prevista is not null then ', e fechando hoje ele fica pronto dia ' || v_pronto else '' end);
    v_tpl := 'orcamento_vence_hoje'; v_params := jsonb_build_array(n, v_num, v_val);
  elsif f.regra_codigo in ('F3', 'F4') and v_cond_vigente then
    v_link := coalesce(c.link_pagamento, (select oc.link_pagamento from public.orcamentos oc where oc.id = c.orcamento_novo_id));
    v_texto := format('Oi, %s! %s no seu orçamento %s: %s. Vale até %s.%s', n,
                      case when f.regra_codigo = 'F4' then 'Última chamada, consegui uma condição especial' else 'Consegui uma condição especial' end, v_num, c.texto_curto,
                      to_char(c.valida_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"'),
                      case when v_link is not null then ' Segue o link atualizado: ' || v_link else ' Quer que eu envie o link de pagamento atualizado?' end);
    v_tpl := 'condicao_especial_orcamento'; v_params := jsonb_build_array(n, v_num, c.texto_curto, to_char(c.valida_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"'));
  elsif f.regra_codigo = 'F3' then
    v_texto := format('Oi, %s! Seu orçamento %s vale até %s. Dá pra fechar e garantir a entrega no prazo. Quer que eu reenvie o link de pagamento?', n, v_num, v_val);
    v_tpl := 'orcamento_vence_hoje'; v_params := jsonb_build_array(n, v_num, v_val);
  elsif f.regra_codigo = 'F4' then
    v_texto := format('Oi, %s, passando pra saber se ainda faz sentido seguir com o seu pedido de %s. Se quiser ajustar quantidade ou acabamento, me chama por aqui que a gente resolve rápido.', n, v_prod);
    v_tpl := 'ultima_chance_orcamento'; v_params := jsonb_build_array(n, v_prod);
  elsif f.regra_codigo like 'PAG_%' then
    select p.link into v_link from public.pagamentos p where p.order_id = f.order_id and p.eh_link and p.link_ativo and p.status = 'pendente' order by p.criado_em desc limit 1;
    v_num := coalesce(v_num, v_ped);
    if v_link is null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'link_inativo'); end if;
    v_texto := case f.regra_codigo
      when 'PAG_1H' then format('Oi, %s! Seu orçamento %s está aguardando o pagamento. O link é %s. O Pix pode ser pago de qualquer banco. Se precisar de ajuda, é só responder por aqui.', n, v_num, v_link)
      when 'PAG_6H' then format('Oi, %s! Só lembrando do pagamento do orçamento %s: %s. Se surgiu alguma dúvida, me fala que eu resolvo.', n, v_num, v_link)
      else format('Oi, %s! Seu orçamento %s ainda está aguardando o pagamento: %s.%s', n, v_num, v_link,
                  case when v_cond_vigente then ' A condição especial vale só até ' || to_char(c.valida_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"') || ' e depois volta ao preço normal.' else ' Se precisar de ajuda, é só responder por aqui.' end) end;
    v_tpl := 'pagamento_pendente'; v_params := jsonb_build_array(n, v_num, v_link);
  elsif f.regra_codigo = 'POS_ENTREGA' then
    v_up := case upper(extensions.unaccent(coalesce(f.produto, '')))
      when '' then 'Se precisar de mais alguma coisa, é só chamar por aqui.'
      else case when upper(extensions.unaccent(f.produto)) like '%CARTA%' then 'Aproveita e me fala se quer adesivos ou panfletos combinando com o cartão.'
                when upper(extensions.unaccent(f.produto)) like '%ADESIV%' then 'Se quiser, já monto também um cartão de visita combinando.'
                when upper(extensions.unaccent(f.produto)) like '%PANFLET%' or upper(extensions.unaccent(f.produto)) like '%FLYER%' then 'Se quiser, já monto também cartões ou adesivos combinando.'
                else 'Se precisar de mais alguma coisa, é só chamar por aqui.' end end;
    v_texto := format('Oi, %s! Seu pedido %s foi entregue. Deu tudo certo? %s', n, v_ped, v_up);
    v_tpl := 'pos_venda_satisfacao'; v_params := jsonb_build_array(n, v_ped);
  elsif f.regra_codigo like 'RECOMPRA_%' then
    v_prod := coalesce(f.produto, 'pedido');
    v_texto := format('Oi, %s! Já faz um tempinho desde o seu pedido de %s. Quer repor ou incluir algo novo? Me responde por aqui que eu monto o orçamento rapidinho.', n, v_prod);
    v_tpl := 'recompra_lembrete'; v_params := jsonb_build_array(n, v_prod);
  else
    return jsonb_build_object('ok', false, 'acao', 'pular', 'motivo', 'regra_sem_texto');
  end if;

  -- F1 não tem template: janela fechada pula (nunca paga template fora de hora por uma pergunta)
  if not v_janela and v_tpl is null then
    return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'janela_fechada');
  end if;
  return jsonb_build_object('ok', true, 'acao', 'enviar', 'via', case when v_janela then 'livre' else 'template' end,
    'texto', v_texto, 'template', v_tpl, 'params', v_params, 'conversation_id', cv.id, 'regra', f.regra_codigo,
    'janela_ate', cv.last_inbound_at + interval '24 hours', 'com_condicao', v_cond_vigente and f.regra_codigo <> 'PAG_24H',
    'simular', 'teste' = any (coalesce(ct.tags, '{}')) or f.teste);
end;
$$;
revoke execute on function public.followup_montar(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.followup_montar(uuid, timestamptz) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------
-- 7. Resultado do envio (registra em condicoes_especiais e precos_praticados; F4 fecha como lead frio)
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.followup_resultado(p_fila uuid, p_ok boolean, p_via text default null, p_wa text default null, p_erro text default null, p_permanente boolean default false, p_agora timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare f public.followup_fila%rowtype; v_tent integer := coalesce((private.fu_cfg() ->> 'tentativas_max')::integer, 3); v_orcs uuid[];
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into f from public.followup_fila where id = p_fila for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'fila_inexistente'); end if;
  if f.status = 'enviado' then return jsonb_build_object('ok', true, 'ja_registrado', true); end if;
  if p_ok then
    update public.followup_fila set status = 'enviado', enviado_em = p_agora, via = coalesce(p_via, 'livre'), wa_message_id = p_wa, motivo = null where id = f.id;
    -- registro para o aprendizado de preços e o relatório semanal
    v_orcs := array[f.orcamento_id];
    if f.condicao_id is not null then
      select array_remove(array[orcamento_id, orcamento_novo_id], null) into v_orcs from public.condicoes_especiais where id = f.condicao_id;
      update public.condicoes_especiais set followup_codigo = f.regra_codigo, followup_via = coalesce(p_via, 'livre'), followup_enviado_em = p_agora where id = f.condicao_id;
    end if;
    if f.orcamento_id is not null then
      update public.precos_praticados set followup_codigo = f.regra_codigo, followup_via = coalesce(p_via, 'livre'), followup_em = p_agora
       where orcamento_id = any (coalesce(v_orcs, array[f.orcamento_id])) and resultado = 'aberto';
    end if;
    if f.regra_codigo = 'F4' then
      update public.contacts set status_lead = 'frio' where id = f.contact_id and status_lead not in ('cliente', 'frio');
      update public.followup_fila set status = 'cancelado', motivo = 'cadencia_encerrada' where orcamento_id = f.orcamento_id and status = 'pendente' and regra_codigo ~ '^F[1-4]$';
    end if;
    return jsonb_build_object('ok', true, 'status', 'enviado');
  end if;
  if p_permanente or f.tentativas >= v_tent then
    update public.followup_fila set status = case when p_permanente then 'pulado' else 'erro' end, motivo = left(coalesce(p_erro, 'falha'), 120) where id = f.id;
    if not p_permanente then
      perform public.alerta_criar('erro_followup', 'baixa', f.contact_id, f.conversation_id, f.order_id, 'Follow-up ' || f.regra_codigo || ' não foi enviado depois de ' || f.tentativas || ' tentativas.', '{}'::jsonb, 'fu_erro:' || f.id::text, null);
    end if;
    return jsonb_build_object('ok', true, 'status', case when p_permanente then 'pulado' else 'erro' end);
  end if;
  update public.followup_fila set status = 'pendente', motivo = left(coalesce(p_erro, 'falha'), 120), agendado_para = p_agora + make_interval(mins => 10 * f.tentativas) where id = f.id;
  return jsonb_build_object('ok', true, 'status', 'pendente', 'retentativa', true);
end;
$$;
revoke execute on function public.followup_resultado(uuid, boolean, text, text, text, boolean, timestamptz) from public, anon, authenticated;
grant execute on function public.followup_resultado(uuid, boolean, text, text, text, boolean, timestamptz) to service_role;

-- Libera linhas reservadas há muito tempo (execução do n8n que caiu). Seguro: a reserva só é refeita se ainda couber nas tentativas.
create or replace function public.followup_liberar_travados(p_agora timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_min integer := coalesce((private.fu_cfg() ->> 'liberar_travados_min')::integer, 15); a integer; b integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.followup_fila set status = 'pendente', motivo = 'liberado_travado'
   where status = 'reservado' and reservado_em < p_agora - make_interval(mins => v_min) and tentativas < 3;
  get diagnostics a = row_count;
  update public.followup_fila set status = 'erro', motivo = 'travado'
   where status = 'reservado' and reservado_em < p_agora - make_interval(mins => v_min) and tentativas >= 3;
  update public.pedido_avisos set status = 'pendente', erro = 'liberado_travado'
   where status = 'reservado' and reservado_em < p_agora - make_interval(mins => v_min) and tentativas < 3;
  get diagnostics b = row_count;
  return jsonb_build_object('ok', true, 'followups', a, 'avisos', b);
end;
$$;
revoke execute on function public.followup_liberar_travados(timestamptz) from public, anon, authenticated;
grant execute on function public.followup_liberar_travados(timestamptz) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------
-- 8. Status do pedido (CRM -> fila -> WF8)
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.pedido_definir_subestatus(p_order uuid, p_sub text, p_rastreio text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_av public.pedido_avisos%rowtype; v_rast text := nullif(left(btrim(coalesce(p_rastreio, '')), 300), '');
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_sub not in ('em_producao', 'pronto_retirada', 'saiu_entrega') then return jsonb_build_object('ok', false, 'motivo', 'subestatus_invalido'); end if;
  select * into o from public.orders where id = p_order for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'pedido_inexistente'); end if;
  if o.stage <> 'producao' then return jsonb_build_object('ok', false, 'motivo', 'fora_da_producao', 'mensagem', 'O subestatus vale só para pedidos em Produção.'); end if;
  if p_sub = 'pronto_retirada' and o.delivery_method = 'uber' then return jsonb_build_object('ok', false, 'motivo', 'entrega_nao_e_retirada', 'mensagem', 'Este pedido é para entrega, não para retirada.'); end if;
  update public.orders set subestatus_pedido = p_sub, subestatus_em = now(), delivery_tracking = coalesce(v_rast, delivery_tracking) where id = o.id;
  insert into public.order_events (order_id, kind, message) values (o.id, 'delivery',
    case p_sub when 'em_producao' then 'Subestatus: em produção' when 'pronto_retirada' then 'Subestatus: pronto para retirada' else 'Subestatus: saiu para entrega' end);
  if p_sub = 'em_producao' then return jsonb_build_object('ok', true, 'subestatus', p_sub); end if;
  insert into public.pedido_avisos (order_id, tipo) values (o.id, p_sub) on conflict (order_id, tipo) do nothing;
  select * into v_av from public.pedido_avisos where order_id = o.id and tipo = p_sub;
  if v_av.status in ('enviado') then return jsonb_build_object('ok', true, 'subestatus', p_sub, 'aviso', 'ja_enviado'); end if;
  if v_av.status in ('falhou', 'pulado') then
    update public.pedido_avisos set status = 'pendente', tentativas = 0, erro = null, proxima_tentativa = now() where id = v_av.id;
  end if;
  return jsonb_build_object('ok', true, 'subestatus', p_sub, 'aviso', 'agendado');
end;
$$;
revoke execute on function public.pedido_definir_subestatus(uuid, text, text) from public, anon;

create or replace function public.pedido_marcar_entregue(p_order uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orders where id = p_order for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'pedido_inexistente'); end if;
  if o.stage = 'entregue' then return jsonb_build_object('ok', true, 'ja_entregue', true); end if;
  if o.stage <> 'producao' then return jsonb_build_object('ok', false, 'motivo', 'fora_da_producao', 'mensagem', 'Só pedidos em Produção podem ser marcados como entregues.'); end if;
  update public.orders set stage = 'entregue' where id = o.id;
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.pedido_marcar_entregue(uuid) from public, anon;

-- WF8: reserva os avisos pendentes (um aviso por pedido e tipo, para sempre)
create or replace function public.pedido_avisos_reservar(p_limite integer default 20, p_agora timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare a public.pedido_avisos%rowtype; o public.orders%rowtype; ct public.contacts%rowtype; v_itens jsonb := '[]'::jsonb;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  for a in select * from public.pedido_avisos where status = 'pendente' and proxima_tentativa <= p_agora order by criado_em limit greatest(p_limite, 1) for update skip locked loop
    select * into o from public.orders where id = a.order_id;
    select * into ct from public.contacts where id = o.contact_id;
    if o.stage <> 'producao' or o.subestatus_pedido is distinct from a.tipo then
      update public.pedido_avisos set status = 'pulado', erro = 'status_mudou' where id = a.id; continue;
    end if;
    if not (o.payment_status = 'aprovado' or o.payment_manual) then
      update public.pedido_avisos set status = 'pulado', erro = 'pedido_nao_pago' where id = a.id; continue;
    end if;
    update public.pedido_avisos set status = 'reservado', reservado_em = p_agora, tentativas = tentativas + 1 where id = a.id;
    v_itens := v_itens || jsonb_build_object('aviso_id', a.id, 'tipo', a.tipo, 'order_id', o.id, 'conversation_id', o.conversation_id,
      'simular', 'teste' = any (coalesce(ct.tags, '{}')) or coalesce(o.teste, false));
  end loop;
  return jsonb_build_object('ok', true, 'itens', v_itens);
end;
$$;
revoke execute on function public.pedido_avisos_reservar(integer, timestamptz) from public, anon, authenticated;
grant execute on function public.pedido_avisos_reservar(integer, timestamptz) to service_role;

create or replace function public.pedido_aviso_montar(p_aviso uuid, p_agora timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  a public.pedido_avisos%rowtype; o public.orders%rowtype; ct public.contacts%rowtype; cv public.conversations%rowtype; n text; v_ped text; v_ret jsonb; v_prox jsonb;
  v_linha text; v_texto text; v_tpl text; v_params jsonb; v_janela boolean; v_link text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into a from public.pedido_avisos where id = p_aviso;
  if not found then return jsonb_build_object('ok', false, 'acao', 'pular', 'motivo', 'aviso_inexistente'); end if;
  select * into o from public.orders where id = a.order_id;
  select * into ct from public.contacts where id = o.contact_id;
  select * into cv from public.conversations where id = coalesce(o.conversation_id, (select id from public.conversations where contact_id = o.contact_id limit 1));
  n := private.fu_nome(ct.name); v_ped := 'SG-' || lpad(o.number::text, 4, '0');
  v_janela := cv.last_inbound_at is not null and cv.last_inbound_at + interval '24 hours' > p_agora;
  if a.tipo = 'pronto_retirada' then
    select value into v_ret from public.app_settings where key = 'retirada';
    v_prox := private.proximo_atendimento(p_agora);
    v_linha := case when (v_prox ->> 'aberto_agora')::boolean then 'Pode retirar hoje até as ' || private.fu_hora_txt(v_prox ->> 'fecha') || '.'
                    when v_prox ->> 'quando' is not null then 'Estamos fora do horário agora. Nosso próximo atendimento é ' || (v_prox ->> 'dia') || ', dia ' || (v_prox ->> 'data') || ', a partir das ' || private.fu_hora_txt(v_prox ->> 'abre') || '.'
                    else '' end;
    v_texto := format('Oi, %s! Seu pedido %s está pronto para retirada. Endereço: %s. Atendimento: %s. %s Quando chegar, é só avisar por aqui.', n, v_ped, v_ret ->> 'endereco', v_ret ->> 'horario_texto', v_linha);
    v_tpl := 'pedido_pronto_retirada'; v_params := jsonb_build_array(n, v_ped);
  else
    v_link := nullif(btrim(coalesce(o.delivery_tracking, '')), '');
    v_texto := format('Oi, %s! Seu pedido %s saiu para entrega. %s Qualquer dúvida, é só responder esta mensagem.', n, v_ped,
                      case when v_link is not null then 'Acompanhe por aqui: ' || v_link || '.' else 'O entregador já está a caminho.' end);
    v_tpl := 'pedido_saiu_entrega'; v_params := jsonb_build_array(n, v_ped, coalesce(v_link, 'o entregador já está a caminho'));
  end if;
  return jsonb_build_object('ok', true, 'acao', 'enviar', 'via', case when v_janela then 'livre' else 'template' end, 'texto', v_texto, 'template', v_tpl, 'params', v_params,
    'conversation_id', cv.id, 'tipo', a.tipo);
end;
$$;
revoke execute on function public.pedido_aviso_montar(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.pedido_aviso_montar(uuid, timestamptz) to service_role;

create or replace function public.pedido_aviso_resultado(p_aviso uuid, p_ok boolean, p_via text default null, p_wa text default null, p_erro text default null, p_permanente boolean default false, p_agora timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare a public.pedido_avisos%rowtype; o public.orders%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into a from public.pedido_avisos where id = p_aviso for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'aviso_inexistente'); end if;
  if a.status = 'enviado' then return jsonb_build_object('ok', true, 'ja_registrado', true); end if;
  select * into o from public.orders where id = a.order_id;
  if p_ok then
    update public.pedido_avisos set status = 'enviado', via = coalesce(p_via, 'livre'), wa_message_id = p_wa, enviado_em = p_agora, erro = null where id = a.id;
    insert into public.order_events (order_id, kind, message) values (a.order_id, 'delivery',
      'Aviso de ' || case a.tipo when 'pronto_retirada' then 'pronto para retirada' else 'saída para entrega' end || ' enviado ao cliente (' || coalesce(p_via, 'livre') || ')');
    return jsonb_build_object('ok', true, 'status', 'enviado');
  end if;
  if p_permanente or a.tentativas >= 3 then
    update public.pedido_avisos set status = 'falhou', erro = left(coalesce(p_erro, 'falha'), 120) where id = a.id;
    insert into public.order_events (order_id, kind, message) values (a.order_id, 'delivery', 'Não foi possível avisar o cliente (' || left(coalesce(p_erro, 'falha'), 80) || '). Avise pelo chat.');
    perform public.alerta_criar('aviso_pedido_falhou', 'alta', o.contact_id, o.conversation_id, o.id, 'O aviso de status do pedido não chegou ao cliente. Avise pelo chat.', '{}'::jsonb, 'aviso_falhou:' || a.id::text, null);
    return jsonb_build_object('ok', true, 'status', 'falhou');
  end if;
  update public.pedido_avisos set status = 'pendente', erro = left(coalesce(p_erro, 'falha'), 120), proxima_tentativa = p_agora + make_interval(mins => 2 * a.tentativas) where id = a.id;
  return jsonb_build_object('ok', true, 'status', 'pendente', 'retentativa', true);
end;
$$;
revoke execute on function public.pedido_aviso_resultado(uuid, boolean, text, text, text, boolean, timestamptz) from public, anon, authenticated;
grant execute on function public.pedido_aviso_resultado(uuid, boolean, text, text, text, boolean, timestamptz) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------
-- 9. Recompra: lista no CRM e disparo manual
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.recompra_lista() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x ->> 'quando') from (
    select jsonb_build_object('fila_id', f.id, 'order_id', f.order_id, 'regra', f.regra_codigo, 'produto', f.produto, 'status', f.status, 'motivo', f.motivo,
      'quando', f.agendado_para, 'enviado_em', f.enviado_em, 'contato', coalesce(c.name, c.wa_id), 'contact_id', c.id, 'optout', c.optout,
      'pedido', 'SG-' || lpad(o.number::text, 4, '0'), 'entregue_em', o.delivered_at,
      'pode_disparar', f.status in ('pendente', 'pulado', 'erro', 'cancelado') and not coalesce(c.optout, false)) as x
    from public.followup_fila f join public.contacts c on c.id = f.contact_id join public.orders o on o.id = f.order_id
    where f.regra_codigo like 'RECOMPRA_%' and f.criado_em > now() - interval '180 days') s), '[]'::jsonb);
end;
$$;
revoke execute on function public.recompra_lista() from public, anon;

create or replace function public.recompra_disparar(p_fila uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare f public.followup_fila%rowtype; c public.contacts%rowtype; r public.followup_regras%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into f from public.followup_fila where id = p_fila for update;
  if not found or f.regra_codigo not like 'RECOMPRA_%' then return jsonb_build_object('ok', false, 'motivo', 'linha_invalida'); end if;
  select * into c from public.contacts where id = f.contact_id;
  if coalesce(c.optout, false) then return jsonb_build_object('ok', false, 'motivo', 'optout', 'mensagem', 'O cliente pediu para não receber promoções.'); end if;
  if f.status in ('enviado', 'reservado') then return jsonb_build_object('ok', false, 'motivo', 'ja_enviado', 'mensagem', 'O lembrete deste ciclo já foi enviado.'); end if;
  select * into r from public.followup_regras where codigo = f.regra_codigo;
  update public.followup_fila set status = 'pendente', motivo = 'disparo_manual', manual = true, tentativas = 0,
    agendado_para = private.fu_proxima_janela(now(), r.hora_min, r.hora_max) where id = f.id;
  return jsonb_build_object('ok', true, 'agendado_para', (select agendado_para from public.followup_fila where id = f.id));
end;
$$;
revoke execute on function public.recompra_disparar(uuid) from public, anon;

-- ---------------------------------------------------------------------------------------------------------------------
-- 10. Painel de pedidos: lista para o fornecedor
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.fornecedor_lista_pendente() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'itens', coalesce((select jsonb_agg(x order by x ->> 'sku') from (
      select jsonb_build_object('sku', coalesce(i.code, 'SEM SKU'), 'descricao', max(i.description), 'quantidade', sum(i.qty), 'pedidos', jsonb_agg(distinct 'SG-' || lpad(o.number::text, 4, '0'))) as x
      from public.orders o join public.order_items i on i.order_id = o.id
      where o.enviado_fabrica_em is null and (o.payment_status = 'aprovado' or o.payment_manual) and o.stage in ('pago', 'arte', 'prova', 'producao') and not coalesce(o.teste, false)
      group by coalesce(i.code, 'SEM SKU')) s), '[]'::jsonb),
    'pedidos', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'numero', 'SG-' || lpad(o.number::text, 4, '0')) order by o.number) from public.orders o
      where o.enviado_fabrica_em is null and (o.payment_status = 'aprovado' or o.payment_manual) and o.stage in ('pago', 'arte', 'prova', 'producao') and not coalesce(o.teste, false)), '[]'::jsonb));
end;
$$;
revoke execute on function public.fornecedor_lista_pendente() from public, anon;

create or replace function public.fornecedor_marcar_enviado(p_orders uuid[]) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_n integer;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.orders set enviado_fabrica_em = now() where id = any (p_orders) and enviado_fabrica_em is null;
  get diagnostics v_n = row_count;
  insert into public.order_events (order_id, kind, message) select id, 'delivery', 'Enviado à fábrica' from public.orders where id = any (p_orders) and enviado_fabrica_em >= now() - interval '5 seconds';
  return jsonb_build_object('ok', true, 'marcados', v_n);
end;
$$;
revoke execute on function public.fornecedor_marcar_enviado(uuid[]) from public, anon;

-- ---------------------------------------------------------------------------------------------------------------------
-- 11. Observabilidade: erros dos workflows, teto de custo do dia e painel do agente
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function public.agente_erro_registrar(p_workflow text, p_workflow_id text, p_no text, p_mensagem text, p_execucao text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_msg text := left(regexp_replace(coalesce(p_mensagem, 'sem mensagem'), '\s+', ' ', 'g'), 240); v_wf text := left(coalesce(p_workflow, 'desconhecido'), 80); v_lib jsonb := '{}'::jsonb; v_al jsonb;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  insert into public.agent_logs (actor, action, detail, result, workflow)
  values ('sistema', 'erro_workflow', jsonb_build_object('workflow_id', p_workflow_id, 'no', left(p_no, 80), 'execucao', p_execucao), v_msg, v_wf);
  -- reprocesso seguro: só destrava linhas reservadas das filas idempotentes; o próximo agendamento refaz o envio
  if v_wf ~ 'WF[5-8]' then v_lib := public.followup_liberar_travados(); end if;
  v_al := public.alerta_criar('erro_workflow', 'alta', null, null, null, 'Erro no workflow ' || v_wf || ' (nó ' || coalesce(left(p_no, 60), '?') || '): ' || left(v_msg, 120),
    jsonb_build_object('workflow', v_wf, 'execucao', p_execucao), 'erro_wf:' || v_wf || ':' || to_char(date_trunc('hour', now()) + floor(extract(minute from now()) / 30) * interval '30 minutes', 'YYYYMMDDHH24MI'), null);
  return jsonb_build_object('ok', true, 'liberados', v_lib, 'alerta', v_al);
end;
$$;
revoke execute on function public.agente_erro_registrar(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.agente_erro_registrar(text, text, text, text, text) to service_role;

create or replace function public.custo_dia_ia(p_agora timestamptz default now()) returns numeric
language sql stable security definer set search_path = ''
as $$
  select coalesce(sum(custo_estimado), 0)::numeric from public.agente_execucoes
   where not teste and (iniciado_em at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date;
$$;
revoke execute on function public.custo_dia_ia(timestamptz) from public, anon, authenticated;
grant execute on function public.custo_dia_ia(timestamptz) to service_role;

create or replace function public.observabilidade_checar(p_agora timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_cfg jsonb; v_teto numeric; v_custo numeric; v_dia text := to_char(p_agora at time zone 'America/Sao_Paulo', 'YYYYMMDD'); v_al jsonb;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select value into v_cfg from public.app_settings where key = 'observabilidade';
  v_teto := coalesce((v_cfg ->> 'teto_custo_dia_brl')::numeric, 15);
  v_custo := public.custo_dia_ia(p_agora);
  if v_custo > v_teto then
    v_al := public.alerta_criar('custo_dia', 'alta', null, null, null, format('O custo estimado da IA hoje passou do teto: R$ %s de R$ %s.', to_char(v_custo, 'FM999990D00'), to_char(v_teto, 'FM999990D00')),
      jsonb_build_object('custo', v_custo, 'teto', v_teto), 'custo_dia:' || v_dia, null);
  end if;
  return jsonb_build_object('ok', true, 'custo_dia', v_custo, 'teto', v_teto, 'acima', v_custo > v_teto, 'alerta', v_al);
end;
$$;
revoke execute on function public.observabilidade_checar(timestamptz) from public, anon, authenticated;
grant execute on function public.observabilidade_checar(timestamptz) to service_role;

create or replace function public.painel_agente(p_de timestamptz default now() - interval '30 days', p_ate timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_obs jsonb; v_mkt numeric; v_utl numeric; v_mes_ini timestamptz := date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  v_res jsonb;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select value into v_obs from public.app_settings where key = 'observabilidade';
  v_mkt := coalesce((v_obs ->> 'custo_template_marketing_brl')::numeric, 0.35); v_utl := coalesce((v_obs ->> 'custo_template_utilidade_brl')::numeric, 0.04);
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', p_de, 'ate', p_ate),
    'ia_ligada', not private.fu_pausada(),
    'conversas_ia', (select count(distinct conversation_id) from public.agente_execucoes where not teste and status = 'concluida' and iniciado_em between p_de and p_ate),
    'orcamentos_enviados', (select count(*) from public.orcamentos where not teste and origem_id is null and pdf_enviado_em between p_de and p_ate),
    'funil', jsonb_build_object(
      'conversas', (select count(distinct conversation_id) from public.agente_execucoes where not teste and status = 'concluida' and iniciado_em between p_de and p_ate),
      'orcamentos', (select count(*) from public.orcamentos where not teste and origem_id is null and pdf_enviado_em between p_de and p_ate),
      'com_link', (select count(*) from public.orcamentos where not teste and origem_id is null and pdf_enviado_em between p_de and p_ate and link_pagamento is not null),
      'pagos', (select count(*) from public.orcamentos where not teste and origem_id is null and pdf_enviado_em between p_de and p_ate and status = 'pago')),
    'pedidos_pagos_do_agente', (select count(*) from public.orders o where not coalesce(o.teste, false) and o.paid_at between p_de and p_ate
        and exists (select 1 from public.agente_execucoes e where e.conversation_id = o.conversation_id and not e.teste)),
    'tokens_por_conversa', (select coalesce(round(avg(t))::int, 0) from (select sum(tokens_entrada + tokens_saida) t from public.agente_execucoes where not teste and iniciado_em between p_de and p_ate group by conversation_id) x),
    'custo_por_conversa', (select coalesce(round(avg(c)::numeric, 4), 0) from (select sum(custo_estimado) c from public.agente_execucoes where not teste and iniciado_em between p_de and p_ate group by conversation_id) x),
    'custo_dia', public.custo_dia_ia(),
    'teto_custo_dia', coalesce((v_obs ->> 'teto_custo_dia_brl')::numeric, 15),
    'custo_templates_mes', (select coalesce(round(sum(case when tc.category = 'MARKETING' then v_mkt else v_utl end)::numeric, 2), 0)
        from public.messages m join public.conversations cv on cv.id = m.conversation_id
        left join public.templates_cache tc on tc.name = m.template_name and tc.language = 'pt_BR'
        where m.direction = 'out' and m.template_name is not null and m.created_at >= v_mes_ini
          and not (cv.ad_window_until is not null and cv.ad_window_until >= m.created_at)),
    'templates_enviados_mes', (select count(*) from public.messages m where m.direction = 'out' and m.template_name is not null and m.created_at >= v_mes_ini),
    'tempo_resposta_seg', (select coalesce(round(avg(extract(epoch from (e.finalizado_em - m.created_at)))::numeric), 0)
        from public.agente_execucoes e join public.messages m on m.id = e.message_id where not e.teste and e.status = 'concluida' and e.finalizado_em is not null and e.iniciado_em between p_de and p_ate),
    'chamadas_ao_dono', (select count(*) from public.alertas where tipo like 'agente%' and criado_em between p_de and p_ate),
    'erros_recentes', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('quando', l.created_at, 'workflow', l.workflow, 'mensagem', l.result) x from public.agent_logs l
         where l.action = 'erro_workflow' order by l.created_at desc limit 10) s), '[]'::jsonb),
    'erros_agente', (select count(*) from public.agente_execucoes where not teste and status = 'erro' and iniciado_em between p_de and p_ate),
    'condicoes', (select jsonb_build_object(
        'concedidas', count(*), 'convertidas', count(*) filter (where resultado = 'aceita'), 'enviadas', count(*) filter (where followup_enviado_em is not null),
        'desconto_medio_sobre_lucro_pct', coalesce(round(avg(case when tipo = 'desconto' and coalesce(lucro_liquido_antes, 0) > 0 then desconto_reais / lucro_liquido_antes * 100 end)::numeric, 1), 0))
        from public.condicoes_especiais where criado_em between p_de and p_ate),
    'margem_liquida_real_pct', (select coalesce(round(avg(o.lucro_liquido_real / nullif(f.total, 0) * 100)::numeric, 1), 0)
        from public.orders o join public.order_financials f on f.order_id = o.id where not coalesce(o.teste, false) and o.paid_at between p_de and p_ate and o.lucro_liquido_real is not null),
    'followups', coalesce((select jsonb_object_agg(regra_codigo, n) from (
        select regra_codigo, count(*) n from public.followup_fila where status = 'enviado' and enviado_em between p_de and p_ate group by regra_codigo) s), '{}'::jsonb),
    'leads_frios', (select count(*) from public.contacts where status_lead = 'frio')
  ) into v_res;
  return v_res;
end;
$$;
revoke execute on function public.painel_agente(timestamptz, timestamptz) from public, anon;

-- A cadência F3/F4 (dia 2 e dia 5) precisa de orçamento ainda válido para a ferramenta de condição especial funcionar.
-- A validade de 48 h (Etapa 4) fazia o orçamento vencer antes do F3; sobe para 7 dias (168 h) só se ainda estiver no padrão. Revisável em Configurações.
update public.parametros_comerciais set validade_orcamento_horas = 168 where validade_orcamento_horas = 48;

notify pgrst, 'reload schema';
