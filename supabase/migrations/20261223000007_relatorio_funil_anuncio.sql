-- Relatório diário: funil de leads de anúncio por etapa (respondeu, orçamento, link, pagou) e comparação do grupo do teste
-- de 14 dias (F2_AD3H) com o histórico dos 30 dias anteriores ao teste. Só leitura. Aditiva e idempotente.
--  * coorte = leads de anúncio criados na janela (sem contatos e pedidos de teste);
--  * teste = criados desde app_settings.followup_teste_ad.inicio; histórico = os 30 dias antes disso;
--  * toques = F2_AD3H enviados, quantos responderam em 3 h e quantos pagaram em 48 h.

create or replace function private.meta_funil_ad_janela(p_ini timestamptz, p_fim timestamptz)
returns jsonb language sql stable security definer set search_path = '' as $$
  with ad as (
    select c.id, v.id as vid from public.contacts c left join public.conversations v on v.contact_id = c.id
     where c.first_referral is not null and not coalesce(c.is_teste, false) and not private.meta_eh_teste(c.id)
       and c.created_at >= p_ini and c.created_at < p_fim)
  select jsonb_build_object(
    'leads', count(*),
    'responderam', count(*) filter (where (select count(*) from public.messages m where m.conversation_id = ad.vid and m.direction = 'in') > 1),
    'orcamento', count(*) filter (where exists (select 1 from public.orcamentos q where q.contact_id = ad.id and q.pdf_enviado_em is not null)),
    'link', count(*) filter (where exists (select 1 from public.orders o join public.pagamentos p on p.order_id = o.id where o.contact_id = ad.id and p.eh_link and o.excluido_em is null)),
    'pagaram', count(*) filter (where exists (select 1 from public.orders o where o.contact_id = ad.id and o.payment_status = 'aprovado' and not coalesce(o.teste, false) and o.excluido_em is null)))
  from ad;
$$;
revoke all on function private.meta_funil_ad_janela(timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.meta_relatorio_funil_ad(p_dia date default ((now() at time zone 'America/Sao_Paulo')::date - 1))
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_fim timestamptz := ((p_dia + 1)::timestamp at time zone 'America/Sao_Paulo'); v_cfg jsonb; v_ini timestamptz; v_ate timestamptz; v_toques jsonb; v_teste jsonb := null; v_hist jsonb;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select s.value into v_cfg from public.app_settings s where s.key = 'followup_teste_ad';
  if v_cfg is null then
    return jsonb_build_object('teste', null, 'historico', private.meta_funil_ad_janela(v_fim - interval '30 days', v_fim));
  end if;
  v_ini := (v_cfg ->> 'inicio')::timestamptz; v_ate := (v_cfg ->> 'fim')::timestamptz;
  if v_fim > v_ini then v_teste := private.meta_funil_ad_janela(v_ini, least(v_fim, v_ate)); end if;
  v_hist := private.meta_funil_ad_janela(v_ini - interval '30 days', v_ini);
  select jsonb_build_object(
    'enviados', count(*) filter (where f.status = 'enviado'),
    'responderam_3h', count(*) filter (where f.status = 'enviado' and exists (select 1 from public.messages m where m.conversation_id = f.conversation_id and m.direction = 'in' and m.created_at > f.enviado_em and m.created_at < f.enviado_em + interval '3 hours')),
    'pagaram_48h', count(*) filter (where f.status = 'enviado' and exists (select 1 from public.orders o where o.contact_id = f.contact_id and o.payment_status = 'aprovado' and not coalesce(o.teste, false) and o.paid_at > f.enviado_em and o.paid_at < f.enviado_em + interval '48 hours')),
    'pulados_ou_cancelados', count(*) filter (where f.status in ('pulado', 'cancelado')),
    'pendentes', count(*) filter (where f.status in ('pendente', 'reservado')),
    'f2_substituidas', (select count(*) from public.followup_fila x where x.regra_codigo = 'F2' and x.motivo = 'substituido_pelo_teste_ad_3h'))
    into v_toques from public.followup_fila f where f.regra_codigo = 'F2_AD3H' and not coalesce(f.teste, false);
  return jsonb_build_object('teste', v_teste, 'historico', v_hist, 'toques', v_toques, 'inicio', v_ini, 'fim', v_ate,
    'dia_do_teste', greatest(least(ceil(extract(epoch from (v_fim - v_ini)) / 86400.0)::int, 14), 0), 'ligado', coalesce((v_cfg ->> 'ligado')::boolean, false));
end $$;
revoke all on function public.meta_relatorio_funil_ad(date) from public, anon;
grant execute on function public.meta_relatorio_funil_ad(date) to authenticated, service_role;

create or replace function private.meta_funil_texto(j jsonb)
returns text language sql immutable set search_path = '' as $$
  select 'leads ' || (j ->> 'leads') || ', responderam ' || (j ->> 'responderam') || ', orçamento ' || (j ->> 'orcamento')
      || ', link ' || (j ->> 'link') || ', pagaram ' || (j ->> 'pagaram')
      || coalesce(' (' || round(100.0 * (j ->> 'pagaram')::numeric / nullif((j ->> 'leads')::numeric, 0), 1) || '%)', '');
$$;

create or replace function private.meta_relatorio_texto(r jsonb)
returns text language sql immutable set search_path = '' as $$
  select 'CAPI Meta de ' || to_char((r ->> 'dia')::date, 'DD/MM') || E':\n'
    || 'Compras pagas: ' || (r ->> 'purchases_pagos') || ', enviadas à Meta: ' || (r ->> 'purchases_enviados')
    || ', com ctwa_clid: ' || (r ->> 'purchases_com_ctwa')
    || coalesce(' (' || (r ->> 'pct_purchases_com_ctwa') || '%)', '') || E'.\n'
    || 'Leads enviados: ' || coalesce(((r -> 'eventos') ->> 'LeadSubmitted|enviado'), '0')
    || ', checkouts enviados: ' || coalesce(((r -> 'eventos') ->> 'InitiateCheckout|enviado'), '0') || E'.\n'
    || 'Na fila: ' || (r ->> 'pendentes_agora') || ', com erro: ' || (r ->> 'com_erro_agora') || E'.\n'
    || case when jsonb_array_length(r -> 'pagos_7d_sem_envio') > 0
            then 'Pagos que NÃO chegaram na Meta (7 dias): ' || (select string_agg('#' || (x ->> 'pedido') || ' (' || (x ->> 'situacao') || ')', ', ') from jsonb_array_elements(r -> 'pagos_7d_sem_envio') x) || E'.'
            else 'Todos os pagos dos últimos 7 dias chegaram na Meta.' end
    || case when r ? 'origem' then
         E'\nCompra por origem na semana (pagaram/contatos): ' || private.meta_origem_texto(r #> '{origem,semana}') || E'.'
         || E'\nTempo mediano até pagar na semana: '
         || coalesce((r #>> '{origem,semana,mediana_horas_total}') || ' h' ||
              coalesce(' (anúncio ' || (r #>> '{origem,semana,mediana_horas_por_origem,anuncio}') || ' h)', ''), 'sem pagamentos na semana') || E'.'
         || E'\nEm 30 dias: ' || private.meta_origem_texto(r #> '{origem,mes}')
         || coalesce('; mediana ' || (r #>> '{origem,mes,mediana_horas_total}') || ' h', '') || E'.'
       else '' end
    || case when r ? 'funil_ad' and (r #> '{funil_ad,historico}') is not null then
         E'\nFunil de leads de anúncio, histórico de 30 dias antes do teste: ' || private.meta_funil_texto(r #> '{funil_ad,historico}') || E'.'
         || case when (r #> '{funil_ad,teste}') is not null then
              E'\nGrupo do teste (dia ' || (r #>> '{funil_ad,dia_do_teste}') || ' de 14): ' || private.meta_funil_texto(r #> '{funil_ad,teste}')
              || E'. Toques de 2 h 30: enviados ' || coalesce(r #>> '{funil_ad,toques,enviados}', '0') || ', responderam em 3 h ' || coalesce(r #>> '{funil_ad,toques,responderam_3h}', '0')
              || ', pagaram em 48 h ' || coalesce(r #>> '{funil_ad,toques,pagaram_48h}', '0') || E'.'
            else '' end
       else '' end;
$$;

create or replace function private.meta_relatorio_enviar()
returns void language plpgsql security definer set search_path = '' as $$
declare v_dia date := (now() at time zone 'America/Sao_Paulo')::date - 1; r jsonb; v_problema boolean;
begin
  perform private.meta_reprocessar();
  r := public.meta_relatorio(v_dia) || jsonb_build_object('origem', public.meta_relatorio_origem(v_dia), 'funil_ad', public.meta_relatorio_funil_ad(v_dia));
  insert into public.meta_relatorios (dia, dados) values (v_dia, r) on conflict (dia) do update set dados = excluded.dados, criado_em = now();
  v_problema := jsonb_array_length(r -> 'pagos_7d_sem_envio') > 0 or (r ->> 'com_erro_agora')::int > 0;
  perform public.alerta_criar('meta_capi_relatorio', case when v_problema then 'alta' else 'baixa' end, null, null, null,
    private.meta_relatorio_texto(r), r, 'meta_capi_relatorio:' || v_dia::text, array['whatsapp']);
exception when others then
  raise warning 'meta_relatorio_enviar: %', sqlerrm;
end $$;
revoke all on function private.meta_relatorio_enviar() from public, anon, authenticated;
