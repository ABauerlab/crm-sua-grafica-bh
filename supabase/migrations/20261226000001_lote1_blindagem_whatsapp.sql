-- Lote 1 da Auditoria 360 (26/11/2026): blindagem da API do WhatsApp e fim dos travamentos.
-- Itens #1 (trava global anti-spam e recusa), #8 (utilidade na reativação), #6 (vazamento:margem e rascunho
-- bloqueado), #7 (trava pós-pagamento) e #2 (loop de buscas e rodadas lentas). Aditiva e idempotente.

-- =====================================================================================
-- 1) Helpers de recusa e de trava diária
-- =====================================================================================
create or replace function private.msg_recusa_forte(p text)
 returns boolean language sql immutable set search_path to ''
as $f$
  select coalesce(p, '') ~* '(\magora\s+n[aã]o\M|\mno\s+momento\s+n[aã]o\M|\mpor\s+enquanto\s+n[aã]o\M|\mn[aã]o\s+por\s+enquanto\M|\mn[aã]o\s+quero\M|\mn[aã]o\s+tenho\s+interesse\M|\mn[aã]o\s+(preciso|faz\s+sentido|vou\s+(querer|seguir|fechar|precisar))\M|\msem\s+interesse\M|\mdesist\w*|\mdeixa\s+(pra\s+l[aá]|quieto|assim)\M|\mn[aã]o,?\s+obrigad[oa]\M|\mdepois\M|\mtalvez\s+mais\s+pra\s+frente\M|\mfica\s+(pra|para)\s+outra\s+vez\M|\mj[aá]\s+(fechei|resolvi|comprei|contratei)\M|\mj[aá]\s+tenho\s+(gr[aá]fica|fornecedor)\M|\mera\s+s[oó]\s+isso\M)';
$f$;

-- Contato que pediu para parar (flag optout ou consentimento de marketing recusado): nenhum envio proativo.
create or replace function private.contato_bloqueado_proativo(p_contact uuid)
 returns boolean language sql stable security definer set search_path to ''
as $f$
  select coalesce((select c.optout or c.marketing_consent = 'opted_out' from public.contacts c where c.id = p_contact), false);
$f$;

-- Quantas mensagens proativas o contato já recebeu hoje (America/Sao_Paulo), somando TODAS as origens:
-- followup_fila (F, PAG, Q, POS_, RECOMPRA_, CARRINHO_) e reativação manual (reativacoes_enviadas).
create or replace function private.proativas_hoje(p_contact uuid, p_agora timestamptz default now(), p_excluir_fila uuid default null)
 returns integer language sql stable security definer set search_path to ''
as $f$
  select (
    select count(*) from public.followup_fila x
     where x.contact_id = p_contact and x.status in ('enviado', 'reservado') and x.id is distinct from p_excluir_fila
       and (coalesce(x.enviado_em, x.reservado_em) at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date
  )::int + (
    select count(*) from public.reativacoes_enviadas r join public.conversations cv on cv.id = r.conversation_id
     where cv.contact_id = p_contact
       and (r.enviado_em at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date
  )::int;
$f$;
revoke execute on function private.proativas_hoje(uuid, timestamptz, uuid) from public, anon;
revoke execute on function private.contato_bloqueado_proativo(uuid) from public, anon;
grant execute on function private.proativas_hoje(uuid, timestamptz, uuid) to authenticated, service_role;
grant execute on function private.contato_bloqueado_proativo(uuid) to authenticated, service_role;

-- =====================================================================================
-- 2) followup_reservar: recusa desde a última proativa, opt-out total e trava diária global
-- =====================================================================================
create or replace function public.followup_reservar(p_familia text, p_limite integer default 20, p_agora timestamp with time zone default now())
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  f public.followup_fila%rowtype; r public.followup_regras%rowtype; o public.orcamentos%rowtype; ord public.orders%rowtype; ct public.contacts%rowtype; cv public.conversations%rowtype;
  v_cfg jsonb := private.fu_cfg(); v_max integer := coalesce((v_cfg ->> 'max_por_dia')::integer, 1);
  v_maxp integer := coalesce((v_cfg ->> 'max_proativas_dia')::integer, 1);
  v_itens jsonb := '[]'::jsonb; v_motivo text; v_novo timestamptz; v_hoje date := (p_agora at time zone 'America/Sao_Paulo')::date; v_cadencia boolean := p_familia = 'cadencia';
  v_desde timestamptz;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_familia not in ('cadencia', 'pos') then raise exception 'Família inválida.'; end if;
  for f in
    select * from public.followup_fila
     where status = 'pendente' and agendado_para <= p_agora
       and ((v_cadencia and regra_codigo ~ '^(F[1-4]|PAG_|Q[1-2])') or (not v_cadencia and regra_codigo ~ '^(POS_|RECOMPRA_)'))
     order by agendado_para limit greatest(p_limite, 1) for update skip locked
  loop
    v_motivo := null; v_novo := null;
    select * into r from public.followup_regras where codigo = f.regra_codigo;
    select * into ct from public.contacts where id = f.contact_id;
    select * into cv from public.conversations where id = coalesce(f.conversation_id, (select id from public.conversations where contact_id = f.contact_id limit 1));
    select * into o from public.orcamentos where id = f.orcamento_id;
    select * into ord from public.orders where id = f.order_id;
    -- última mensagem proativa que o contato recebeu (qualquer origem); sem nenhuma, olha os últimos 3 dias
    v_desde := coalesce(greatest(
      (select max(coalesce(x.enviado_em, x.reservado_em)) from public.followup_fila x where x.contact_id = f.contact_id and x.id <> f.id and x.status in ('enviado', 'reservado')),
      (select max(rr.enviado_em) from public.reativacoes_enviadas rr join public.conversations c2 on c2.id = rr.conversation_id where c2.contact_id = f.contact_id)
    ), p_agora - interval '3 days');

    if not coalesce(r.ativo, false) then v_motivo := 'regra_inativa';
    elsif coalesce(ct.optout, false) or ct.marketing_consent = 'opted_out' then v_motivo := 'optout'; /* optout_total */
    elsif v_cadencia and (
        coalesce(o.status, '') = 'pago' or coalesce(ord.payment_status, '') = 'aprovado' or coalesce(ord.payment_manual, false)
        or exists (select 1 from public.orders x where x.contact_id = f.contact_id and x.stage in ('pago', 'arte', 'prova', 'producao', 'entregue')
                      and coalesce(x.paid_at, x.created_at) >= coalesce(o.pdf_enviado_em, o.criado_em, f.criado_em))) then v_motivo := 'pago';
    elsif v_cadencia and f.regra_codigo ~ '^F[1-4]$' and (o.id is null or o.status not in ('enviado', 'aceito')) then v_motivo := 'orcamento_encerrado';
    elsif v_cadencia and f.regra_codigo ~ '^F[1-4]$' and o.validade_ate is not null and o.validade_ate < p_agora then v_motivo := 'orcamento_vencido';
    elsif v_cadencia and f.regra_codigo ~ '^PAG_' and not exists (
        select 1 from public.pagamentos p where p.order_id = f.order_id and p.eh_link and p.link_ativo and p.status = 'pendente' and (p.expira_em is null or p.expira_em > p_agora)) then v_motivo := 'link_inativo';
    elsif v_cadencia and f.regra_codigo ~ '^(F[1-4]|PAG_|Q[1-2])' and exists (
        select 1 from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.deleted_at is null and m.created_at > v_desde and private.msg_recusa_forte(m.body)) then v_motivo := 'cliente_recusou'; /* recusa_desde_proativa */
    elsif v_cadencia and f.regra_codigo ~ '^F[1-4]$' and exists (
        select 1 from (select m.body from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.body is not null and m.deleted_at is null order by m.created_at desc limit 2) z
         where z.body ~* '(n[aã]o,? *(n[aã]o|obrigad[oa]|valeu)|^\W*obrigad[oa]\W*$|^\W*valeu\W*$|n[aã]o (quero|preciso|tenho interesse|faz sentido|vou (querer|seguir|fechar|precisar))|sem interesse|deixa (pra l[aá]|quieto|assim)|desist|j[aá] (fechei|resolvi|comprei|contratei)|era s[oó] isso|por enquanto n[aã]o|n[aã]o por enquanto|talvez (depois|mais pra frente)|fica (pra|para) (depois|outra vez)|j[aá] tenho (gr[aá]fica|fornecedor)|n[aã]o,? obrigad)') then v_motivo := 'cliente_recusou'; /* f_recusou */
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and cv.last_inbound_at > f.criado_em then v_motivo := 'cliente_respondeu'; /* conversa_parada */
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and exists (
        select 1 from (select m.body from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.body is not null and m.deleted_at is null order by m.created_at desc limit 2) z
         where z.body ~* '(n[aã]o,? *(n[aã]o|obrigad[oa]|valeu)|\Wobrigad[oa]\W*$|^\W*valeu\W*$|n[aã]o (quero|preciso|tenho interesse|faz sentido|vou (querer|seguir|fechar|precisar))|sem interesse|deixa (pra l[aá]|quieto|assim)|desist|j[aá] (fechei|resolvi|comprei|contratei)|era s[oó] isso|por enquanto n[aã]o|n[aã]o por enquanto|talvez (depois|mais pra frente)|fica (pra|para) (depois|outra vez)|j[aá] tenho (gr[aá]fica|fornecedor)|vou (pensar|ver) (depois|com calma|melhor)|n[aã]o,? obrigad|abra[çc]o|tchau|at[eé] (mais|logo|a pr[oó]xima)|volt[oa] (depois|mais tarde)|vou (ver|pensar|juntar|organizar).*(dinheiro|valor|grana|depois)|(depois|mais tarde) eu (volto|te chamo|falo))') then v_motivo := 'cliente_recusou'; /* cliente_recusou despedida_24_11 */
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and private.proativas_hoje(f.contact_id, p_agora, f.id) >= v_maxp then v_motivo := 'trava_diaria'; /* trava_diaria_global */
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and exists (
        select 1 from public.followup_fila x where x.contact_id = f.contact_id and x.id <> f.id and x.regra_codigo ~ '^Q[1-2]$' and x.status in ('enviado', 'reservado')
           and coalesce(x.enviado_em, x.reservado_em) > p_agora - make_interval(mins => coalesce((v_cfg ->> 'q_intervalo_min')::integer, 120))) then v_motivo := 'q_intervalo'; /* q_cadencia */
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and (
        select count(*) from public.followup_fila x where x.contact_id = f.contact_id and x.id <> f.id and x.regra_codigo ~ '^Q[1-2]$' and x.status in ('enviado', 'reservado')
           and (coalesce(x.enviado_em, x.reservado_em) at time zone 'America/Sao_Paulo')::date = v_hoje) >= coalesce((v_cfg ->> 'q_max_dia')::integer, 2) then v_motivo := 'q_limite_dia';
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and exists (select 1 from public.orders xo where xo.contact_id = f.contact_id and xo.excluido_em is null and xo.created_at > p_agora - interval '10 days') then v_motivo := 'pedido_existente'; /* q_sem_pedido */
    elsif v_cadencia and f.regra_codigo = 'Q2' and exists (select 1 from public.followup_fila x where x.contact_id = f.contact_id and x.regra_codigo = 'Q1' and x.status in ('enviado', 'reservado') and coalesce(x.enviado_em, x.reservado_em) > p_agora - interval '6 hours') then v_motivo := 'q1_recente';
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and (cv.last_inbound_at is null or cv.last_inbound_at + interval '24 hours' < p_agora) then v_motivo := 'janela_fechada';
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and exists (select 1 from public.orcamentos oo where oo.contact_id = f.contact_id and oo.status in ('enviado', 'aceito') and oo.criado_em > p_agora - interval '10 days') then v_motivo := 'orcamento_enviado';
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

    if private.fu_pausada() then v_novo := p_agora + interval '60 minutes';
    elsif f.regra_codigo ~ '^Q[1-2]$' and exists (
        select 1 from (select m.body, m.created_at from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.body is not null and m.deleted_at is null order by m.created_at desc limit 1) z
         where z.created_at > p_agora - interval '3 hours'
           and z.body ~* '(j[aá] (te )?(respondo|volto|mando|falo|retorno|aviso|dou)|(respondo|retorno|aviso|volto|te dou)( a resposta)? (j[aá]|mais tarde|depois)|estou (em|no|na) (trabalho|servi[cç]o|reuni[aã]o|aula)|t[oô] (em|no|na) (trabalho|servi[cç]o|reuni[aã]o|aula)|minutinho|instantinho|aguard[eo]|mais tarde|daqui a pouco|depois (eu )?(te )?(falo|respondo|mando|aviso)|vou (ver|olhar|conferir|verificar|consultar|falar|conversar|pensar)|vou ver com)') then v_novo := p_agora + interval '90 minutes'; /* q_volta */
    elsif extract(hour from p_agora at time zone 'America/Sao_Paulo') < r.hora_min or extract(hour from p_agora at time zone 'America/Sao_Paulo') >= r.hora_max then
      v_novo := private.fu_proxima_janela(p_agora, r.hora_min, r.hora_max);
    elsif f.regra_codigo !~ '^Q' and private.proativas_hoje(f.contact_id, p_agora, f.id) >= v_maxp then /* trava_diaria_global */
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
$function$;

-- Recusa chegou: cancela na hora os follow-ups pendentes do contato (não espera a hora do envio).
create or replace function private.trg_recusa_cancela_followups()
 returns trigger language plpgsql security definer set search_path to ''
as $f$
begin
  if new.direction = 'in' and new.body is not null and private.msg_recusa_forte(new.body) then
    update public.followup_fila f set status = 'cancelado', motivo = 'cliente_recusou'
      from public.conversations cv
     where cv.id = new.conversation_id and f.contact_id = cv.contact_id and f.status = 'pendente'
       and f.regra_codigo ~ '^(F[1-4]|PAG_|Q[1-2]|CARRINHO)';
  end if;
  return new;
exception when others then
  return new; -- nunca bloqueia a gravação da mensagem recebida
end;
$f$;
revoke execute on function private.trg_recusa_cancela_followups() from public, anon, authenticated;
drop trigger if exists messages_recusa_cancela_followups on public.messages;
create trigger messages_recusa_cancela_followups after insert on public.messages
  for each row when (new.direction = 'in') execute function private.trg_recusa_cancela_followups();

-- =====================================================================================
-- 3) Carrinho abandonado: respeita opt-out e a trava diária
-- =====================================================================================
do $do$
declare v_def text; v_old text := 'if v_contact is not null and v_conv_id is not null and v_janela_aberta and not v_ja_comprou then';
begin
  select pg_get_functiondef('private.carrinho_abandonado_varrer(timestamp with time zone)'::regprocedure) into v_def;
  if position('proativas_hoje' in v_def) > 0 then return; end if;
  if position(v_old in v_def) = 0 then raise exception 'carrinho_abandonado_varrer: trecho esperado não encontrado'; end if;
  execute replace(v_def, v_old, 'if v_contact is not null and v_conv_id is not null and v_janela_aberta and not v_ja_comprou and private.proativas_hoje(v_contact) = 0 and not private.contato_bloqueado_proativo(v_contact) then');
end $do$;

-- =====================================================================================
-- 4) Reativação manual: uma por contato, sem opt-out, sem orcamento_pronto velho, 1 proativa por dia
-- =====================================================================================
alter table public.reativacoes_enviadas drop constraint if exists reativacoes_enviadas_canal_check;
alter table public.reativacoes_enviadas add constraint reativacoes_enviadas_canal_check check (canal in ('template', 'livre'));

create or replace function public.reativacao_reservar(p_order uuid, p_conversation uuid, p_template text, p_canal text, p_por uuid default null)
 returns jsonb language plpgsql security definer set search_path to ''
as $f$
declare o public.orders%rowtype; v_idade numeric; v_id uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orders where id = p_order;
  if not found or o.conversation_id is null or o.conversation_id <> p_conversation then
    return jsonb_build_object('ok', false, 'motivo', 'pedido_inexistente', 'mensagem', 'Pedido não encontrado para esta conversa.');
  end if;
  perform pg_advisory_xact_lock(hashtext('proativa:' || o.contact_id::text));
  if private.contato_bloqueado_proativo(o.contact_id) then
    return jsonb_build_object('ok', false, 'motivo', 'opted_out', 'mensagem', 'Este contato pediu para não receber mensagens. Nenhum envio proativo é permitido.');
  end if;
  if private.proativas_hoje(o.contact_id) >= 1 then
    return jsonb_build_object('ok', false, 'motivo', 'trava_diaria', 'mensagem', 'Este contato já recebeu uma mensagem proativa hoje. Só 1 por dia, somando follow-ups e reativações.');
  end if;
  if p_template = 'orcamento_pronto' then
    select extract(epoch from (now() - coalesce(oc.pdf_enviado_em, oc.criado_em))) / 3600 into v_idade
      from public.orcamentos oc where oc.order_id = o.id order by oc.criado_em desc limit 1;
    if coalesce(v_idade, extract(epoch from (now() - o.created_at)) / 3600) > 24 then
      return jsonb_build_object('ok', false, 'motivo', 'orcamento_pronto_vencido', 'mensagem', 'O template orcamento_pronto (utilidade) só vale para orçamento com até 24 h. Acima disso, só template de marketing com opt-in.');
    end if;
  end if;
  insert into public.reativacoes_enviadas (order_id, conversation_id, stage, canal, template_name, enviado_por)
  values (o.id, o.conversation_id, o.stage, p_canal, p_template, p_por) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$f$;
revoke execute on function public.reativacao_reservar(uuid, uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.reativacao_reservar(uuid, uuid, text, text, uuid) to service_role;

create or replace function public.reativacao_cancelar(p_id uuid)
 returns void language plpgsql security definer set search_path to ''
as $f$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  delete from public.reativacoes_enviadas where id = p_id;
end;
$f$;
revoke execute on function public.reativacao_cancelar(uuid) from public, anon, authenticated;
grant execute on function public.reativacao_cancelar(uuid) to service_role;

-- Lista: um card por contato (etapa mais avançada), sem opt-out, com a idade do orçamento e o aviso de proativa hoje.
drop function if exists public.pagamentos_pendentes_reativar_listar();
create or replace function public.pagamentos_pendentes_reativar_listar()
returns table (
  order_id uuid, conversation_id uuid, number int, contact_name text, wa_id text, stage text, title text, total numeric,
  payment_link text, motivo_perda text, marketing_consent text, janela_aberta boolean, created_at timestamptz, dias_aberto int,
  ultima_reativacao_em timestamptz, idade_horas numeric, proativa_hoje boolean
)
language sql stable security invoker set search_path = public, private
as $$
  with base as (
    select
      o.id as oid, o.conversation_id as cid, o.number as num, c.name as cname, c.wa_id as wa, o.stage as stg, o.title as ttl,
      coalesce(f.total, 0) as tot, o.payment_link as plink, o.motivo_perda as mperda, c.marketing_consent as mk,
      ((conv.last_inbound_at is not null and conv.last_inbound_at + interval '24 hours' > now())
        or (conv.ad_window_until is not null and conv.ad_window_until > now())) as janela,
      o.created_at as criado, (current_date - o.created_at::date)::int as dias, ult.enviado_em as ult,
      coalesce((select extract(epoch from (now() - coalesce(oc.pdf_enviado_em, oc.criado_em))) / 3600
                  from public.orcamentos oc where oc.order_id = o.id order by oc.criado_em desc limit 1),
               extract(epoch from (now() - o.created_at)) / 3600)::numeric as idade,
      private.proativas_hoje(o.contact_id) >= 1 as hoje,
      row_number() over (partition by o.contact_id order by case o.stage when 'aguardando_pagamento' then 0 when 'cotando' then 1 else 2 end, o.created_at desc) as rn
    from public.orders o
    join public.contacts c on c.id = o.contact_id
    join public.conversations conv on conv.id = o.conversation_id
    left join public.order_financials f on f.order_id = o.id
    left join lateral (select max(r.enviado_em) as enviado_em from public.reativacoes_enviadas r where r.order_id = o.id) ult on true
    where private.is_staff()
      and o.conversation_id is not null and o.excluido_em is null and o.cancelado_em is null and o.arquivado_em is null
      and o.created_at::date < current_date
      and not coalesce(c.optout, false) and c.marketing_consent <> 'opted_out'
      and (
        (o.stage = 'aguardando_pagamento' and o.payment_status = 'pendente' and o.payment_link is not null)
        or (o.stage = 'cotando' and exists (select 1 from public.orcamentos oc where oc.order_id = o.id and oc.status in ('enviado', 'expirado')))
        or (o.stage = 'perdido')
      )
  )
  select oid, cid, num, cname, wa, stg, ttl, tot, plink, mperda, mk, janela, criado, dias, ult, round(idade, 1), hoje
    from base where rn = 1 order by criado asc;
$$;
revoke all on function public.pagamentos_pendentes_reativar_listar() from public, anon;
grant execute on function public.pagamentos_pendentes_reativar_listar() to authenticated;

-- =====================================================================================
-- 5) Trava de saída: vazamento:margem só em contexto financeiro interno
-- =====================================================================================
do $do$
declare
  v_def text;
  v_old text := $old$array['margem', '\mmargem\M(?!\s+(de\s+|da\s+|do\s+)?(seguran[cç]a|sangria|corte|branca|interna|externa|impress[aã]o|arte|papel))'],$old$;
  v_new text := $new$array['margem', '(\mnossa\s+margem\M(?!\s+(de\s+|da\s+|do\s+)?(seguran[cç]a|sangria|corte|branca|interna|externa|impress[aã]o|arte|papel))|\mmargem\s+(de\s+|da\s+|do\s+)?(lucro|l[ií]quida|bruta|comercial)\M|\mlucro\s+(m[ií]nimo|l[ií]quido|bruto)\M)'], /* margem_financeira */$new$;
begin
  select pg_get_functiondef('public.agente_saida_base_execucao(uuid, text)'::regprocedure) into v_def;
  if position('margem_financeira' in v_def) > 0 then return; end if;
  if position(v_old in v_def) = 0 then raise exception 'agente_saida_base_execucao: regra margem esperada não encontrada'; end if;
  execute replace(v_def, v_old, v_new);
end $do$;

-- Qualquer bloqueio da trava de saída grava o rascunho e os motivos em agent_logs (auditoria).
do $do$
declare
  v_def text;
  v_old text := E'  return r;\nend;\n$function$';
  v_new text := E'  if not coalesce((r ->> ''ok'')::boolean, true) then /* saida_rascunho_bloqueado */\n'
    || E'    insert into public.agent_logs (conversation_id, actor, action, detail, result, workflow)\n'
    || E'    select ex.conversation_id, ''ia'', ''saida_rascunho_bloqueado'',\n'
    || E'           jsonb_build_object(''motivos'', r -> ''motivos'', ''soft_only'', r -> ''soft_only'', ''rascunho'', left(coalesce(p_texto, ''''), 4000)),\n'
    || E'           ''bloqueado'', ''private.agente_saida_segura''\n'
    || E'      from public.agente_execucoes ex where ex.id = p_execucao;\n'
    || E'  end if;\n  return r;\nend;\n$function$';
begin
  select pg_get_functiondef('public.agente_saida_segura(uuid, text)'::regprocedure) into v_def;
  if position('saida_rascunho_bloqueado' in v_def) > 0 then return; end if;
  if position(v_old in v_def) = 0 then raise exception 'agente_saida_segura: final esperado não encontrado'; end if;
  execute replace(v_def, v_old, v_new);
end $do$;

-- =====================================================================================
-- 6) Trava pós-pagamento ampliada (cor, texto, logo, endereço, impressão, logística e priorização)
-- =====================================================================================
create or replace function private.saida_travas_extra(p_exec uuid, p_texto text)
 returns text[]
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare v text[] := '{}'; v_pago boolean := false; v_ct uuid; v_sem_nome boolean;
begin
  if coalesce(p_texto, '') = '' then return v; end if;
  if p_texto ~* '((entreg\w+|levamos|enviamos|mandamos)[^.!?]{0,60}(toda|todo|qualquer)[^.!?]{0,15}(bh|belo horizonte|regi[aã]o|cidade)|motoboy[^.!?]{0,40}(toda|todo|qualquer|regi[aã]o))' then
    v := array_append(v, 'promessa:frete_fora_da_ferramenta');
  end if;
  if p_texto ~* '((conseguimos|d[aá] (pra|para)|garanto|entregamos|fica pronto|ficam prontos|pronto a tempo|consigo deixar pronto)[^.!?]{0,160}(at[eé]|para|pra) (a |o )?(segunda|ter[cç]a|quarta|quinta|sexta|s[aá]bado|domingo|amanh[aã]|hoje))'
     and p_texto !~ '[0-9]{1,2}/[0-9]{1,2}' then
    v := array_append(v, 'promessa:prazo_sem_ferramenta');
  end if;
  if p_texto ~* '((vai|v[aã]o|vais|quer|gostaria de|precisa de|prefere)[^.!?]{0,25}nota fiscal[^.!?]{0,80}\?|nota fiscal para (esse|este) pedido\?)' then
    select ex.contact_id into v_ct from public.agente_execucoes ex where ex.id = p_exec;
    select exists (select 1 from public.orders o where o.contact_id = v_ct and o.excluido_em is null and (o.payment_status = 'aprovado' or o.payment_manual)
                     and coalesce(o.paid_at, o.created_at) > now() - interval '30 days') into v_pago;
    if not v_pago then v := array_append(v, 'promessa:nf_antes_do_pagamento'); end if;
  end if;
  if p_texto ~* '(\y(oi|ol[aá]|opa)[,!]?\s+cliente\y|,\s*cliente\s*[!.])' then
    select ex.contact_id into v_ct from public.agente_execucoes ex where ex.id = p_exec;
    select private.fu_nome(c.name) is null into v_sem_nome from public.contacts c where c.id = v_ct;
    if coalesce(v_sem_nome, true) then
      v := array_append(v, 'saudacao:cliente_sem_nome');
    end if;
  end if;
  -- Pós-pagamento: a Laura nunca confirma alteração (arte, cor, texto, logo, endereço, impressão) nem promete
  -- logística ou prioridade. Frases de "vou verificar com o responsável se ainda dá" passam (saida_sem_verificacao).
  if private.saida_sem_verificacao(p_texto) ~* '((j[aá]\s+)?(anotei|anotamos|confirmei|confirmamos|alterei|ajustei|troquei|mudei|providenciei|combinei|avisei|repassei|encaminhei|registrei|priorizei|priorizamos|marquei)[^.!?]{0,90}(furo|carteirinha|tamanho|acabamento|quantidade|lamina[cç][aã]o|verniz|corte|papel|modelo|arte|produ[cç][aã]o|cor|cores|texto|logo|logotipo|endere[cç]o|impress[aã]o|entrega|envio|sa[ií]da|hor[aá]rio|prazo|prioridade|retirada|frete)|(estou|estamos|vou|vamos|iremos|irei)\s+(organizando|organizar|prioriz\w+|adiantando|adiantar|antecipando|antecipar|encaixando|encaixar|agendando|agendar|separando|separar|ajustando|ajustar|alterando|alterar|trocando|trocar|mudando|mudar|garantindo|garantir)[^.!?]{0,60}(envio|entrega|sa[ií]da|produ[cç][aã]o|pedido|arte|prazo|hor[aá]rio|retirada|cor|texto|logo|endere[cç]o|impress[aã]o)|(vai|v[aã]o|ir[aá]|ficar[aã]o?)\s+(sair|ficar)[^.!?]{0,50}(sem (o )?furo|igual|iguaizinh|como (voc[eê]|vc) pediu)|(consigo|conseguimos|podemos|d[aá] (pra|para)|posso)\s+(sim\s+)?(trocar|alterar|mudar|ajustar|tirar o furo)|(sem problema|perfeito|combinado|fechado)[^.!?]{0,40}(trocar|alterar|mudar|ajustar|sem furo))' then
    select ex.contact_id into v_ct from public.agente_execucoes ex where ex.id = p_exec;
    if exists (select 1 from public.orders o where o.contact_id = v_ct and o.excluido_em is null and (o.payment_status = 'aprovado' or o.payment_manual)
                 and coalesce(o.stage, '') not in ('entregue', 'perdido', 'cancelado')) then
      v := array_append(v, 'promessa:alteracao_pos_pagamento'); /* alteracao_pos_pagamento */
    end if;
  end if;
  return v;
end $function$;

-- =====================================================================================
-- 7) Loop de buscas e rodadas lentas
-- =====================================================================================
alter table public.agente_execucoes add column if not exists buscas jsonb not null default '[]'::jsonb;

create or replace function private.jaccard_tokens(a text, b text)
 returns numeric language sql immutable set search_path to ''
as $f$
  select case when (select count(*) from (select unnest(regexp_split_to_array(coalesce(a, ''), '\s+')) union select unnest(regexp_split_to_array(coalesce(b, ''), '\s+'))) u) = 0 then 0
         else (select count(*) from (select unnest(regexp_split_to_array(coalesce(a, ''), '\s+')) intersect select unnest(regexp_split_to_array(coalesce(b, ''), '\s+'))) i)::numeric
              / (select count(*) from (select unnest(regexp_split_to_array(coalesce(a, ''), '\s+')) union select unnest(regexp_split_to_array(coalesce(b, ''), '\s+'))) u) end;
$f$;

-- A assinatura de 2 argumentos vira de 3 (p_args opcional): quem chama com 2 continua funcionando.
drop function if exists public.agente_tool_inicio(uuid, text);
create or replace function public.agente_tool_inicio(p_execucao uuid, p_ferramenta text, p_args jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  cfg record; v_n integer; v_total integer; v_falha text; v_ferr jsonb; v_buscas jsonb := '[]'::jsonb;
  v_termo text; v_qtd text; v_bloqueio text; v_idem integer; v_len integer; v_vazias integer; v_sim integer;
begin
  select * into cfg from public.agente_config where id = 1;
  if exists (select 1 from public.agente_execucoes ex where ex.id = p_execucao and ex.rascunho) /* rascunho_bloqueio */
     and p_ferramenta not in ('buscar_produto', 'buscar_conhecimento', 'montar_orcamento', 'verificar_frete', 'salvar_contato') then
    return jsonb_build_object('permitido', false, 'motivo', 'rascunho');
  end if;
  update public.agente_execucoes
  set ferramentas = jsonb_set(ferramentas, array[p_ferramenta], to_jsonb(coalesce((ferramentas ->> p_ferramenta)::int, 0) + 1))
  where id = p_execucao
  returning ferramentas, teste_falha, buscas into v_ferr, v_falha, v_buscas;
  if v_ferr is null then return jsonb_build_object('permitido', false, 'motivo', 'sem_execucao'); end if;
  v_n := (v_ferr ->> p_ferramenta)::int;
  select coalesce(sum(value::int), 0) into v_total from jsonb_each_text(v_ferr);
  if v_n > cfg.max_ferramenta_por_rodada or v_total > cfg.max_chamadas_por_rodada then
    perform public.agente_log(p_execucao, 'loop_ferramenta', p_ferramenta, null, 0, 0, null, jsonb_build_object('chamadas', v_n, 'total', v_total), 'bloqueado');
    return jsonb_build_object('permitido', false, 'motivo', 'loop', 'chamadas', v_n);
  end if;

  -- Freio específico das buscas (o teto global de 20 distintas continua valendo): 4a busca idêntica, 3 buscas
  -- seguidas sem nenhum resultado, ou 5 buscas seguidas quase iguais (sem progresso) encerram o loop.
  if p_ferramenta = 'buscar_produto' then
    v_termo := btrim(regexp_replace(lower(extensions.unaccent(coalesce(p_args ->> 'termo', ''))), '[^a-z0-9 ]+', ' ', 'g'));
    v_termo := regexp_replace(v_termo, '\s+', ' ', 'g');
    v_qtd := coalesce(p_args ->> 'quantidade', '');
    v_len := jsonb_array_length(v_buscas);
    if v_termo <> '' then
      select count(*) into v_idem from jsonb_array_elements(v_buscas) b where b ->> 't' = v_termo and coalesce(b ->> 'q', '') = v_qtd;
      if v_idem >= 3 then v_bloqueio := 'busca_repetida'; end if;
      if v_bloqueio is null and v_len >= 5 then
        select count(*) into v_sim from (select b from jsonb_array_elements(v_buscas) with ordinality t(b, i) order by i desc limit 5) x
         where private.jaccard_tokens(x.b ->> 't', v_termo) >= 0.5;
        if v_sim >= 5 then v_bloqueio := 'busca_sem_progresso'; end if;
      end if;
    end if;
    if v_bloqueio is null and v_len >= 3 then
      select count(*) filter (where (x.b ->> 'v') = 'true') into v_vazias from (select b from jsonb_array_elements(v_buscas) with ordinality t(b, i) order by i desc limit 3) x;
      if v_vazias = 3 then v_bloqueio := 'buscas_sem_retorno'; end if;
    end if;
    if v_bloqueio is not null then
      perform public.agente_log(p_execucao, 'loop_ferramenta', p_ferramenta, null, 0, 0, null,
        jsonb_build_object('motivo', v_bloqueio, 'termo', v_termo, 'quantidade', v_qtd, 'buscas', v_len), 'bloqueado');
      return jsonb_build_object('permitido', false, 'motivo', v_bloqueio, 'chamadas', v_n);
    end if;
    update public.agente_execucoes set buscas = v_buscas || jsonb_build_array(jsonb_build_object('t', v_termo, 'q', v_qtd, 'v', null)) where id = p_execucao;
  end if;
  return jsonb_build_object('permitido', true, 'simular_falha', coalesce(v_falha = p_ferramenta, false), 'chamada', v_n);
end;
$function$;

create or replace function public.agente_tool_fim(p_execucao uuid, p_ferramenta text, p_duracao_ms integer, p_ok boolean, p_skus text[] DEFAULT '{}'::text[], p_valores numeric[] DEFAULT '{}'::numeric[], p_resumo text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_conv uuid; v_contact uuid; v_teste boolean := false; k integer;
begin
  update public.agente_execucoes set
    skus_vistos = (select coalesce(array_agg(distinct s), '{}') from unnest(skus_vistos || coalesce(p_skus, '{}')) s where s is not null and s <> ''),
    valores_vistos = (select coalesce(array_agg(distinct round(v, 2)), '{}') from unnest(valores_vistos || coalesce(p_valores, '{}')) v where v is not null)
  where id = p_execucao
  returning conversation_id into v_conv;

  -- marca se a última busca voltou vazia (alimenta o freio de buscas sem retorno)
  if p_ferramenta = 'buscar_produto' then
    update public.agente_execucoes
       set buscas = jsonb_set(buscas, array[(jsonb_array_length(buscas) - 1)::text, 'v'], to_jsonb(not p_ok or coalesce(array_length(p_skus, 1), 0) = 0), true)
     where id = p_execucao and jsonb_array_length(buscas) > 0;
  end if;

  if p_ok and p_ferramenta in ('gerar_pdf_orcamento', 'enviar_foto_produto') and v_conv is not null then
    select c.id, c.is_teste into v_contact, v_teste from public.conversations cv join public.contacts c on c.id = cv.contact_id where cv.id = v_conv;
    if coalesce(v_teste, false) then
      if p_ferramenta = 'gerar_pdf_orcamento' then
        update public.orcamentos set pdf_enviado_em = now(), pdf_gerado_em = coalesce(pdf_gerado_em, now()), status = case when status = 'rascunho' then 'enviado' else status end
         where id = (select id from public.orcamentos where contact_id = v_contact and status in ('rascunho', 'enviado') and pdf_enviado_em is null order by criado_em desc limit 1);
      else
        for k in 1 .. 3 loop
          insert into public.messages (conversation_id, wa_message_id, direction, type, body, status, created_at)
          values (v_conv, 'teste.opcao.' || gen_random_uuid()::text, 'out', 'text', 'Opção ' || k || ' (foto e ficha enviadas)', 'sent', now() - make_interval(secs => (4 - k)));
        end loop;
      end if;
    end if;
  end if;

  return public.agente_log(p_execucao, 'ferramenta', p_ferramenta, null, 0, 0, p_duracao_ms,
    jsonb_build_object('resumo', left(coalesce(p_resumo, ''), 300)), case when p_ok then 'ok' else 'falhou' end);
end;
$function$;

-- Rodada acima de 90 s gera alerta (uma vez por execução); acima de 300 s, parada: destrava e deixa a retomada refazer.
create or replace function private.agente_alertar_lenta(p_execucao uuid, p_seg numeric)
 returns void language plpgsql security definer set search_path to ''
as $f$
declare ex record; v_nome text;
begin
  select e.id, e.conversation_id, e.contact_id, coalesce(e.teste, false) as teste into ex from public.agente_execucoes e where e.id = p_execucao;
  if not found or ex.teste then return; end if;
  select coalesce(c.name, c.wa_id) into v_nome from public.contacts c where c.id = ex.contact_id;
  perform public.alerta_criar('agente_lento', 'baixa', ex.contact_id, ex.conversation_id, null,
    'A Laura levou ' || round(p_seg)::text || ' s para responder ' || coalesce(v_nome, 'um cliente') || ' (limite de alerta: 90 s).',
    jsonb_build_object('execucao_id', ex.id, 'segundos', round(p_seg)), 'agente_lento:' || ex.id::text, array['push']);
exception when others then
  null; -- o alerta nunca derruba o atendimento
end;
$f$;
revoke execute on function private.agente_alertar_lenta(uuid, numeric) from public, anon, authenticated;

create or replace function public.agente_finalizar(p_execucao uuid, p_status text default 'concluida'::text, p_motivo text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_seg numeric;
begin
  update public.agente_execucoes set status = p_status, motivo = coalesce(p_motivo, motivo), finalizado_em = now() where id = p_execucao
    returning extract(epoch from (now() - iniciado_em)) into v_seg;
  if coalesce(v_seg, 0) > 90 then perform private.agente_alertar_lenta(p_execucao, v_seg); end if;
  return (select jsonb_build_object('ok', true, 'tokens', tokens_entrada + tokens_saida, 'custo', custo_estimado) from public.agente_execucoes where id = p_execucao);
end;
$function$;

create or replace function private.agente_vigia_rodadas()
 returns jsonb language plpgsql security definer set search_path to ''
as $f$
declare r record; v_alertas int := 0; v_destravadas int := 0;
begin
  for r in
    select e.id, extract(epoch from (now() - e.iniciado_em)) as seg from public.agente_execucoes e
     where e.status = 'rodando' and coalesce(e.teste, false) = false and e.iniciado_em < now() - interval '90 seconds' and e.iniciado_em > now() - interval '3 hours'
  loop
    perform private.agente_alertar_lenta(r.id, r.seg); v_alertas := v_alertas + 1;
    if r.seg > 300 then
      update public.agente_execucoes set status = 'erro', motivo = 'timeout_vigia', finalizado_em = now() where id = r.id and status = 'rodando';
      insert into public.agent_logs (conversation_id, actor, action, detail, result, workflow)
      select conversation_id, 'sistema', 'rodada_travada', jsonb_build_object('execucao_id', r.id, 'segundos', round(r.seg)), 'destravada', 'private.agente_vigia_rodadas'
        from public.agente_execucoes where id = r.id;
      v_destravadas := v_destravadas + 1;
    end if;
  end loop;
  return jsonb_build_object('alertas', v_alertas, 'destravadas', v_destravadas);
end;
$f$;
revoke execute on function private.agente_vigia_rodadas() from public, anon, authenticated;

do $do$
begin
  begin perform cron.unschedule('agente-vigia-rodadas'); exception when others then null; end;
  perform cron.schedule('agente-vigia-rodadas', '* * * * *', 'select private.agente_vigia_rodadas()');
end $do$;
