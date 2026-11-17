-- Rodada de 17/11/2026: atendimento sem repetição, mínimo por lote explicado, produto composto somado
-- e lembrete para conversa parada antes do orçamento. Aditiva e idempotente.

-- Auxiliar temporária: troca um trecho e acusa erro se ele não existir (evita patch que não pega).
create or replace function pg_temp.trocar(p_def text, p_velho text, p_novo text) returns text language plpgsql as $f$
begin
  if position(p_velho in p_def) = 0 then raise exception 'trecho não encontrado: %', left(p_velho, 80); end if;
  return replace(p_def, p_velho, p_novo);
end $f$;

create or replace function private.fmt_reais_at(p numeric) returns text language sql immutable set search_path = '' as
$$ select replace(to_char(p, 'FM9999999990.00'), '.', ',') $$;

-- 1) Trava da conversa: a rodada do modelo leva de 30 s a 2 min; com 60 s a trava soltava no meio e duas rodadas se atropelavam.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'agente_iniciar';
  if position('/* lock150 */' in v_def) = 0 then
    v_new := pg_temp.trocar(v_def, $q$interval '60 seconds'$q$, $q$interval '150 seconds'$q$);
    v_new := pg_temp.trocar(v_new, $q$-- Destrava automaticamente$q$, $q$/* lock150 */ -- Destrava automaticamente$q$);
    execute v_new;
  end if;
end $mig$;

-- 2) Não enviar resposta velha: se o cliente escreveu depois da mensagem que disparou a rodada, a resposta é descartada
--    e a rodada seguinte (que já está esperando) responde com tudo o que ele disse.
create or replace function public.agente_pode_enviar_rodada(p_conversation uuid, p_message uuid)
 returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_motivo text; m record;
begin
  v_motivo := public.agente_bloqueio(p_conversation);
  if v_motivo is null then
    select created_at, id into m from public.messages where id = p_message;
    if found and exists (select 1 from public.messages x where x.conversation_id = p_conversation and x.direction = 'in'
                            and (x.created_at, x.id) > (m.created_at, m.id)) then
      v_motivo := 'mensagem_nova';
    end if;
  end if;
  return jsonb_build_object('pode', v_motivo is null, 'motivo', v_motivo);
end $$;
revoke all on function public.agente_pode_enviar_rodada(uuid, uuid) from public, anon, authenticated;
grant execute on function public.agente_pode_enviar_rodada(uuid, uuid) to service_role;

-- 3) Resumo de produto composto (crachá + cordão): números prontos, o modelo só copia.
create or replace function private.resumo_composto(p_orc uuid) returns jsonb language sql stable security definer set search_path = '' as $$
  with l as (
    select i.descricao, i.quantidade * coalesce(c.quantidade, 1) as unidades, i.quantidade * i.preco_unitario as total, i.criado_em
      from public.orcamento_itens i left join public.catalogo c on c.sku = i.sku where i.orcamento_id = p_orc)
  select jsonb_build_object(
    'linhas', (select jsonb_agg(jsonb_build_object('descricao', descricao, 'unidades', unidades, 'valor_total', round(total, 2),
                 'valor_unitario', round(total / nullif(unidades, 0), 2)) order by criado_em) from l),
    'total_itens', round(sum(total), 2),
    'unidades_por_conjunto', case when count(distinct unidades) = 1 then max(unidades) end,
    'valor_por_conjunto', case when count(distinct unidades) = 1 then round(sum(total) / nullif(max(unidades), 0), 2) end,
    'orientacao', 'Produto composto (ex.: crachá + cordão): mostre cada item com o valor, depois o total dos itens e, se valor_por_conjunto vier preenchido, o valor por conjunto. Copie os números, nunca recalcule.')
  from l $$;

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'montar_orcamento';
  if position('/* resumo_composto */' in v_def) = 0 then
    v_new := pg_temp.trocar(v_def, $q$'upsell', v_up, 'avisos', to_jsonb(v_pub_avisos));$q$,
      $q$'upsell', v_up, 'avisos', to_jsonb(v_pub_avisos),
    'resumo_composto', case when jsonb_array_length(v_itens_out) > 1 then private.resumo_composto(v_id) end /* resumo_composto */);$q$);
    execute v_new;
  end if;
end $mig$;

-- 4) Busca: "crachá PVC" acha o PVC de 5 unidades (família "plástico") e mostra o lote maior quando vale a pena.
do $mig$
declare v_def text; v_new text; v_exot text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'buscar_produto';
  if position('/* lote_maior */' in v_def) = 0 then
    v_exot := $q$array['pvc','plastico','holografica','hotstamping','kraft','metalizad','madeira','acrilico','imantad']$q$;
    v_new := pg_temp.trocar(v_def, $q$v_acabamentos jsonb := '[]'::jsonb;$q$, $q$v_acabamentos jsonb := '[]'::jsonb; v_lote jsonb := null; v_min_exato numeric;$q$);
    v_new := pg_temp.trocar(v_new, $q$v_variantes := array(select distinct x from unnest(v_variantes) x);$q$,
      $q$v_variantes := array(select distinct x from unnest(v_variantes) x);
  if v_norm ~ '(^| )(cracha|credencial|identificacao)( |$)' and v_norm ~ '(^| )(pvc|plastico)( |$)' then /* cracha_pvc */
    v_variantes := array(select distinct x from unnest(v_variantes || array['cartao fidelidade plastico compacto', 'pvc branco 050']) x);
  end if;$q$);
    v_new := pg_temp.trocar(v_new, $q$where position(x in c.especificacao_normalizada) > 0 and position(x in v_norm) = 0)$q$,
      $q$where position(x in c.especificacao_normalizada) > 0 and position(x in v_norm) = 0 and not (x = 'plastico' and position('pvc' in v_norm) > 0) and not (x = 'pvc' and position('plastico' in v_norm) > 0) /* pvc_plastico */)$q$);
    v_new := pg_temp.trocar(v_new, $q$-- Acabamentos da categoria$q$,
      $q$if v_qtd is not null and jsonb_array_length(v_opcoes) > 0 then /* lote_maior */
    select min((o ->> 'preco')::numeric) into v_min_exato from jsonb_array_elements(v_opcoes) o where (o ->> 'quantidade')::integer = v_qtd;
    for r in
      select c.sku, c.categoria, c.descricao, c.cores, c.tamanho_mm, c.tamanho_final, c.gramatura_g, c.quantidade, c.prazo_dias_uteis
        from _bp_fam f join public.catalogo c on c.id = f.id
       where c.quantidade > v_qtd and c.quantidade <= greatest(v_qtd * 20, 100) and f.score >= v_maxscore * 0.85
         and not exists (select 1 from unnest($q$ || v_exot || $q$) x where position(x in c.especificacao_normalizada) > 0 and position(x in v_norm) = 0
                           and not (x = 'plastico' and position('pvc' in v_norm) > 0) and not (x = 'pvc' and position('plastico' in v_norm) > 0))
       order by c.preco_base_custo, f.score desc limit 1
    loop
      j := public.calcular_preco(r.sku, 1, '{}'::jsonb);
      if coalesce((j ->> 'ok')::boolean, false) and (v_min_exato is null or (j ->> 'preco_total')::numeric <= v_min_exato * 1.6) then
        v_lote := jsonb_build_object('sku', r.sku, 'descricao_curta', concat_ws(' ', initcap(lower(r.categoria)), r.descricao, r.cores, r.tamanho_mm),
          'quantidade', r.quantidade, 'preco', (j ->> 'preco_total')::numeric, 'preco_unitario', round((j ->> 'preco_total')::numeric / r.quantidade, 2),
          'prazo_dias_uteis', r.prazo_dias_uteis,
          'em_palavras', private.traduzir_especificacao(r.cores, r.gramatura_g, r.tamanho_mm, concat_ws(' ', r.categoria, r.descricao)));
      end if;
    end loop;
  end if;

  -- Acabamentos da categoria$q$);
    v_new := pg_temp.trocar(v_new, $q$'itens_sem_sku_encontrados', v_sem_sku,$q$,
      $q$'alternativa_lote_maior', v_lote,
    'orientacao_quantidade', case
      when v_lote is not null and v_existe then 'Mostre primeiro as opções na quantidade pedida. Depois, em uma frase, apresente o lote maior (alternativa_lote_maior): total R$ ' || private.fmt_reais_at((v_lote ->> 'preco')::numeric) || ' para ' || (v_lote ->> 'quantidade') || ' unidades (R$ ' || private.fmt_reais_at((v_lote ->> 'preco_unitario')::numeric) || ' cada), e pergunte qual ele prefere. Use só os valores da ferramenta.'
      when v_lote is not null then 'Esse produto não é vendido em ' || v_qtd || ' unidades. Explique em linguagem simples que o menor lote é de ' || (v_lote ->> 'quantidade') || ' unidades, por R$ ' || private.fmt_reais_at((v_lote ->> 'preco')::numeric) || ' no total (R$ ' || private.fmt_reais_at((v_lote ->> 'preco_unitario')::numeric) || ' cada), que costuma compensar e sobra para reposição, e pergunte se ele prefere o lote ou outra opção. Nunca diga só que o mínimo é essa quantidade.'
      end,
    'itens_sem_sku_encontrados', v_sem_sku,$q$);
    execute v_new;
  end if;
end $mig$;

-- 5) Lembretes para conversa parada antes do orçamento (Q1 em cerca de 40 min, Q2 em cerca de 20 h, sempre dentro da janela de 24 h).
alter table public.followup_regras drop constraint if exists followup_regras_referencia_check;
alter table public.followup_regras add constraint followup_regras_referencia_check
  check (referencia = any (array['orcamento_enviado'::text, 'link_pagamento'::text, 'pedido_entregue'::text, 'pedido_pago'::text, 'conversa_parada'::text]));

insert into public.followup_regras (codigo, descricao, referencia, atraso_minutos, hora_min, hora_max, ativo, revisar) values
  ('Q1', 'Conversa parada antes do orçamento: lembrete cerca de 40 minutos depois da última pergunta (mensagem livre)', 'conversa_parada', 40, 8, 20, true, false),
  ('Q2', 'Conversa parada antes do orçamento: último lembrete cerca de 20 horas depois da última mensagem do cliente, antes de fechar a janela de 24 h', 'conversa_parada', 1200, 8, 20, true, false)
on conflict (codigo) do nothing;

create or replace function private.fu_q2_horario(p_ts timestamptz, p_hmin integer, p_hmax integer) returns timestamptz
 language plpgsql immutable set search_path = '' as $$
declare v_l timestamp := p_ts at time zone 'America/Sao_Paulo';
begin
  if extract(hour from v_l) < p_hmin then v_l := date_trunc('day', v_l) - interval '1 day' + make_interval(hours => p_hmax - 1, mins => 30);
  elsif extract(hour from v_l) >= p_hmax then v_l := date_trunc('day', v_l) + make_interval(hours => p_hmax - 1, mins => 30);
  end if;
  return v_l at time zone 'America/Sao_Paulo';
end $$;

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'followup_agendar';
  if position('/* conversa_parada */' in v_def) = 0 then
    v_new := pg_temp.trocar(v_def, $q$  for q in select id from public.orders where stage = 'entregue'$q$,
      $q$  for r in select * from public.followup_regras where ativo and referencia = 'conversa_parada' loop /* conversa_parada */
    insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, teste)
    select cv.contact_id, cv.id, r.codigo, r.codigo || ':' || cv.id::text || ':' || (extract(epoch from cv.last_inbound_at))::bigint::text,
           case when r.codigo = 'Q1' then private.fu_proxima_janela(ult.criado + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max)
                else private.fu_q2_horario(cv.last_inbound_at + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max) end,
           'teste' = any (coalesce(ct.tags, '{}'))
      from public.conversations cv join public.contacts ct on ct.id = cv.contact_id
      cross join lateral (select m.created_at as criado, m.direction as dir from public.messages m where m.conversation_id = cv.id order by m.created_at desc limit 1) ult
     where cv.last_inbound_at is not null and cv.last_inbound_at > p_agora - interval '23 hours'
       and ult.dir = 'out' and ult.criado > cv.last_inbound_at
       and coalesce(cv.modo_atendimento, 'ia') = 'ia' and coalesce(cv.ai_handled, true) and not coalesce(cv.needs_human, false)
       and not coalesce(ct.optout, false)
       and not exists (select 1 from public.orcamentos o where o.contact_id = cv.contact_id and o.status in ('enviado', 'aceito', 'pago') and o.criado_em > p_agora - interval '10 days')
       and not exists (select 1 from public.orders x where x.contact_id = cv.contact_id and x.excluido_em is null and x.stage in ('pago', 'arte', 'prova', 'producao', 'entregue') and coalesce(x.paid_at, x.created_at) > p_agora - interval '30 days')
       and (r.codigo <> 'Q2' or ult.criado < p_agora - interval '3 hours')
    on conflict (chave) do nothing;
    get diagnostics v_n = row_count; v_orc := v_orc + v_n;
  end loop;
  for q in select id from public.orders where stage = 'entregue'$q$);
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'followup_reservar';
  if position('/* conversa_parada */' in v_def) = 0 then
    v_new := pg_temp.trocar(v_def, $q$regra_codigo ~ '^(F[1-4]|PAG_)'$q$, $q$regra_codigo ~ '^(F[1-4]|PAG_|Q[1-2])'$q$);
    v_new := pg_temp.trocar(v_new, $q$    elsif v_cadencia and coalesce(cv.modo_atendimento, 'ia') <> 'ia' then v_motivo := 'modo_humano';$q$,
      $q$    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and cv.last_inbound_at > f.criado_em then v_motivo := 'cliente_respondeu'; /* conversa_parada */
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and (cv.last_inbound_at is null or cv.last_inbound_at + interval '24 hours' < p_agora) then v_motivo := 'janela_fechada';
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and exists (select 1 from public.orcamentos oo where oo.contact_id = f.contact_id and oo.status in ('enviado', 'aceito') and oo.criado_em > p_agora - interval '10 days') then v_motivo := 'orcamento_enviado';
    elsif v_cadencia and coalesce(cv.modo_atendimento, 'ia') <> 'ia' then v_motivo := 'modo_humano';$q$);
    v_new := pg_temp.trocar(v_new, $q$elsif (select count(*) from public.followup_fila x where x.contact_id$q$,
      $q$elsif f.regra_codigo !~ '^Q' and (select count(*) from public.followup_fila x where x.contact_id$q$);
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'followup_montar';
  if position('/* conversa_parada */' in v_def) = 0 then
    v_new := pg_temp.trocar(v_def, $q$  elsif f.regra_codigo like 'PAG_%' then$q$,
      $q$  elsif f.regra_codigo = 'Q1' then /* conversa_parada */
    v_texto := case v_var
      when 0 then format('Oi, %s! Vi que ficou faltando só um detalhe pra eu montar o seu orçamento. Me responde por aqui que eu já resolvo rapidinho, tá bom?', n)
      else format('Oi, %s! Conseguiu ver a minha última mensagem? Me passa o que falta que eu já te mando o valor certinho.', n) end;
  elsif f.regra_codigo = 'Q2' then
    v_texto := format('Oi, %s! Ainda consigo te ajudar com o seu pedido? Se me passar só o que falta, eu já te mando o orçamento ainda hoje.', n);
  elsif f.regra_codigo like 'PAG_%' then$q$);
    execute v_new;
  end if;
end $mig$;

-- 6) Ajustes depois do primeiro disparo real: sem lembrete para quem já tem pedido (a conversa segue o fluxo do pedido),
--    e o último lembrete (Q2) não sai se o Q1 saiu há menos de 6 horas.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'followup_agendar';
  if position('/* q_sem_pedido */' in v_def) = 0 then
    v_new := pg_temp.trocar(v_def, $q$and ult.dir = 'out' and ult.criado > cv.last_inbound_at$q$,
      $q$and ult.dir = 'out' and ult.criado > cv.last_inbound_at and not exists (select 1 from public.orders xo where xo.contact_id = cv.contact_id and xo.excluido_em is null and xo.created_at > p_agora - interval '10 days') /* q_sem_pedido */$q$);
    execute v_new;
  end if;
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'followup_reservar';
  if position('/* q_sem_pedido */' in v_def) = 0 then
    v_new := pg_temp.trocar(v_def, $q$then v_motivo := 'cliente_respondeu'; /* conversa_parada */$q$,
      $q$then v_motivo := 'cliente_respondeu'; /* conversa_parada */
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and exists (select 1 from public.orders xo where xo.contact_id = f.contact_id and xo.excluido_em is null and xo.created_at > p_agora - interval '10 days') then v_motivo := 'pedido_existente'; /* q_sem_pedido */
    elsif v_cadencia and f.regra_codigo = 'Q2' and exists (select 1 from public.followup_fila x where x.contact_id = f.contact_id and x.regra_codigo = 'Q1' and x.status in ('enviado', 'reservado') and coalesce(x.enviado_em, x.reservado_em) > p_agora - interval '6 hours') then v_motivo := 'q1_recente';$q$);
    execute v_new;
  end if;
end $mig$;
