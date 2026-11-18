-- Rodada 18/11/2026 (G1 e G2 do diário do tráfego pago, 17/11):
--  G1: lembrete Q1/Q2 não insiste (intervalo mínimo e teto por dia), espera quando o cliente avisa que volta, reconhece mais recusas
--      e muda o texto a cada envio.
--  G2: orçamento enviado em aberto nunca fica sem acompanhamento: se o cliente respondeu e silenciou, os lembretes F voltam a valer
--      (modo IA); em modo humano gera alerta ao dono em vez de lembrete automático.
-- Aditiva e idempotente (patch por marcador sobre a definição atual de followup_reservar).

-- Parâmetros novos (padrões também no código): intervalo mínimo entre Q (min), máximo de Q por dia e silêncio do humano (min).
update public.app_settings
   set value = value || jsonb_build_object('q_intervalo_min', 120, 'q_max_dia', 2)
 where key = 'followup' and not (value ? 'q_intervalo_min');

do $m$
declare
  d text; n text;
  a1 text := $q$elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and exists (select 1 from public.orders xo where xo.contact_id = f.contact_id and xo.excluido_em is null and xo.created_at > p_agora - interval '10 days') then v_motivo := 'pedido_existente'; /* q_sem_pedido */$q$;
  a2 text := $q$if private.fu_pausada() then v_novo := p_agora + interval '60 minutes';$q$;
  a3 text := $q$|era s[oó] isso)$q$;
begin
  select pg_get_functiondef('public.followup_reservar(text,integer,timestamptz)'::regprocedure) into d;
  if position('q_cadencia' in d) > 0 then return; end if;
  if position(a1 in d) = 0 or position(a2 in d) = 0 or position(a3 in d) = 0 then
    raise exception 'followup_reservar mudou: ajuste os âncoras do patch (q_cadencia).';
  end if;
  -- 1) mais frases de recusa
  n := replace(d, a3, $q$|era s[oó] isso|por enquanto n[aã]o|n[aã]o por enquanto|talvez (depois|mais pra frente)|fica (pra|para) (depois|outra vez)|j[aá] tenho (gr[aá]fica|fornecedor)|vou (pensar|ver) (depois|com calma|melhor)|n[aã]o,? obrigad)$q$);
  -- 2) intervalo mínimo e teto diário dos lembretes de conversa parada
  n := replace(n, a1,
    $q$elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and exists (
        select 1 from public.followup_fila x where x.contact_id = f.contact_id and x.id <> f.id and x.regra_codigo ~ '^Q[1-2]$' and x.status in ('enviado', 'reservado')
           and coalesce(x.enviado_em, x.reservado_em) > p_agora - make_interval(mins => coalesce((v_cfg ->> 'q_intervalo_min')::integer, 120))) then v_motivo := 'q_intervalo'; /* q_cadencia */
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and (
        select count(*) from public.followup_fila x where x.contact_id = f.contact_id and x.id <> f.id and x.regra_codigo ~ '^Q[1-2]$' and x.status in ('enviado', 'reservado')
           and (coalesce(x.enviado_em, x.reservado_em) at time zone 'America/Sao_Paulo')::date = v_hoje) >= coalesce((v_cfg ->> 'q_max_dia')::integer, 2) then v_motivo := 'q_limite_dia';
    $q$ || a1);
  -- 3) cliente avisou que volta: espera (até 3 h depois da mensagem dele) em vez de cutucar
  n := replace(n, a2,
    a2 || $q$
    elsif f.regra_codigo ~ '^Q[1-2]$' and exists (
        select 1 from (select m.body, m.created_at from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.body is not null and m.deleted_at is null order by m.created_at desc limit 1) z
         where z.created_at > p_agora - interval '3 hours'
           and z.body ~* '(j[aá] (te )?(respondo|volto|mando|falo|retorno|aviso|dou)|(respondo|retorno|aviso|volto|te dou)( a resposta)? (j[aá]|mais tarde|depois)|estou (em|no|na) (trabalho|servi[cç]o|reuni[aã]o|aula)|t[oô] (em|no|na) (trabalho|servi[cç]o|reuni[aã]o|aula)|minutinho|instantinho|aguard[eo]|mais tarde|daqui a pouco|depois (eu )?(te )?(falo|respondo|mando|aviso)|vou (ver|olhar|conferir|verificar|consultar|falar|conversar|pensar)|vou ver com)') then v_novo := p_agora + interval '90 minutes'; /* q_volta */$q$);
  execute n;
end
$m$;

-- 4) texto do lembrete varia a cada envio e cita o assunto quando conhecido
create or replace function private.fu_texto_q(p_regra text, p_conv uuid, p_nome text, p_var integer)
returns text language plpgsql stable security definer set search_path = '' as $f$
declare v_ja integer; v_v integer; v_ass text := private.fu_assunto(p_conv);
begin
  select count(*) into v_ja from public.followup_fila x join public.conversations cv on cv.contact_id = x.contact_id
   where cv.id = p_conv and x.regra_codigo ~ '^Q[1-2]$' and x.status in ('enviado', 'reservado');
  v_v := (coalesce(p_var, 0) + coalesce(v_ja, 0)) % 4;
  if p_regra = 'Q1' then
    return case v_v
      when 0 then format('Oi, %s! Assim que puder, me responde por aqui pra gente já seguir%s, combinado?', p_nome, case when v_ass is not null then ' com os ' || v_ass else ' com o seu orçamento' end)
      when 1 then format('Oi, %s! Ficou alguma dúvida%s? Me diz o que falta que eu resolvo rapidinho.', p_nome, case when v_ass is not null then ' sobre os ' || v_ass else '' end)
      when 2 then format('%s, tô por aqui quando você quiser retomar%s. É só me chamar!', p_nome, case when v_ass is not null then ' os ' || v_ass else '' end)
      else format('Oi, %s! Se ajudar, eu já adianto o que for preciso pra fechar%s. Posso seguir?', p_nome, case when v_ass is not null then ' os ' || v_ass else '' end) end;
  elsif p_regra = 'Q2' then
    return format('Oi, %s! Última chamada: se ainda fizer sentido pra você, é só me responder por aqui que eu já sigo e te entrego o material o quanto antes. Posso contar com você?', p_nome);
  end if;
  return null;
end $f$;
revoke all on function private.fu_texto_q(text, uuid, text, integer) from public, anon, authenticated;

-- 5) G2: orçamento enviado e em aberto não fica sem acompanhamento depois que o cliente respondeu
create or replace function private.followup_orcamentos_abertos(p_agora timestamptz default now())
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare
  o record; r record; v_base timestamptz; v_ult_out timestamptz; v_ult timestamptz; v_reat integer := 0; v_ins integer := 0; v_al integer := 0; v_humano boolean; v_n integer;
begin
  for o in
    select oc.id, oc.numero, oc.total, oc.contact_id, oc.conversation_id, oc.order_id, oc.pdf_enviado_em, cv.id as cv_id, cv.last_inbound_at, cv.modo_atendimento, cv.ai_handled
      from public.orcamentos oc join public.conversations cv on cv.id = coalesce(oc.conversation_id, (select c2.id from public.conversations c2 where c2.contact_id = oc.contact_id limit 1))
     where oc.status = 'enviado' and oc.pdf_enviado_em is not null and oc.origem_id is null and coalesce(oc.teste, false) = false
       and oc.pdf_enviado_em > p_agora - interval '10 days' and (oc.validade_ate is null or oc.validade_ate > p_agora)
       and cv.last_inbound_at is not null and cv.last_inbound_at > oc.pdf_enviado_em + interval '1 minute'
       and not exists (select 1 from public.orders x where x.contact_id = oc.contact_id and x.excluido_em is null and x.payment_status = 'aprovado' and coalesce(x.paid_at, x.created_at) >= oc.pdf_enviado_em)
  loop
    select max(m.created_at) into v_ult_out from public.messages m where m.conversation_id = o.cv_id and m.direction = 'out' and m.deleted_at is null;
    v_ult := greatest(o.last_inbound_at, coalesce(v_ult_out, o.last_inbound_at));
    v_humano := coalesce(o.modo_atendimento, 'ia') <> 'ia' or not coalesce(o.ai_handled, true);
    if v_humano then
      -- modo humano: a Laura não cutuca; o dono é avisado (no máximo 1 aviso a cada 6 h por orçamento)
      if v_ult < p_agora - interval '90 minutes' then
        perform public.alerta_criar('agente_chamado', 'media', o.contact_id, o.cv_id, o.order_id,
          'Orçamento ' || o.numero || ' (R$ ' || to_char(o.total, 'FM999G999D00') || ') está em atendimento humano e o cliente não responde há ' || greatest(1, round(extract(epoch from p_agora - v_ult) / 3600))::text || ' h. A Laura não faz lembrete em modo humano.',
          jsonb_build_object('orcamento_id', o.id, 'origem', 'lead_humano_parado'),
          'lead_humano:' || o.id || ':' || floor(extract(epoch from p_agora) / 21600)::bigint::text, null);
        v_al := v_al + 1;
      end if;
    elsif v_ult < p_agora - interval '30 minutes' then
      v_base := v_ult;
      for r in select * from public.followup_regras where ativo and referencia = 'orcamento_enviado' order by atraso_minutos loop
        if exists (select 1 from public.followup_fila x where x.orcamento_id = o.id and x.regra_codigo = r.codigo and x.status in ('enviado', 'reservado', 'pendente')) then continue; end if;
        -- F1 a F4 de um orçamento só saem uma vez cada; reativa a linha cancelada por resposta ou cria a que nunca existiu
        update public.followup_fila x
           set status = 'pendente', motivo = null, tentativas = 0,
               agendado_para = private.fu_proxima_janela(v_base + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max)
         where x.orcamento_id = o.id and x.regra_codigo = r.codigo and x.status = 'cancelado' and x.motivo in ('cliente_respondeu', 'cliente_recusou_reaberto');
        get diagnostics v_n = row_count; v_reat := v_reat + v_n;
        if v_n = 0 and not exists (select 1 from public.followup_fila x where x.orcamento_id = o.id and x.regra_codigo = r.codigo) then
          insert into public.followup_fila (contact_id, conversation_id, orcamento_id, regra_codigo, chave, agendado_para, teste, produto)
          values (o.contact_id, o.cv_id, o.id, r.codigo, r.codigo || ':' || o.id::text,
                  private.fu_proxima_janela(v_base + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max), false,
                  (select left(i.descricao, 80) from public.orcamento_itens i where i.orcamento_id = o.id order by i.criado_em limit 1))
          on conflict (chave) do nothing;
          get diagnostics v_n = row_count; v_ins := v_ins + v_n;
        end if;
      end loop;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'reativados', v_reat, 'criados', v_ins, 'alertas_humano', v_al);
end $f$;
revoke all on function private.followup_orcamentos_abertos(timestamptz) from public, anon, authenticated;

do $c$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('followup-orcamentos-abertos') where exists (select 1 from cron.job where jobname = 'followup-orcamentos-abertos');
    perform cron.schedule('followup-orcamentos-abertos', '*/10 * * * *', 'select private.followup_orcamentos_abertos()');
  end if;
end $c$;
