-- Etapa 8C: o contexto do agente passa a listar TODOS os orçamentos abertos da cliente (até 4), cada um com seus itens,
-- para o agente tratar produtos diferentes como pedidos independentes (antes só o mais recente aparecia, sem itens).
-- Aditivo: 'orcamento_aberto' (o mais recente) continua igual; entra o campo novo 'orcamentos_abertos'.
create or replace function public.agente_contexto_base(p_conversation uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  cv public.conversations%rowtype;
  ct public.contacts%rowtype;
  cfg record;
  v_agora timestamptz := now() at time zone 'America/Sao_Paulo';
  v_dias text[] := array['domingo', 'segunda-feira', 'terça-feira', 'quarta-feira', 'quinta-feira', 'sexta-feira', 'sábado'];
  v_corte timestamptz;
  v_ref jsonb;
  v_ad text;
  v_prod jsonb;
  v_hist jsonb;
  v_orc jsonb;
  v_orcs jsonb;
  v_pedido text;
  v_recorrente boolean;
begin
  select * into cv from public.conversations where id = p_conversation;
  if not found then return jsonb_build_object('erro', 'conversa_inexistente'); end if;
  select * into ct from public.contacts where id = cv.contact_id;
  select * into cfg from public.agente_config where id = 1;

  v_ref := coalesce(cv.last_referral, ct.first_referral);
  v_ad := v_ref ->> 'source_id';
  select jsonb_build_object('descricao', c.descricao, 'sku', a.sku, 'quantidade_exemplo', c.quantidade) into v_prod
  from public.anuncios_produtos a left join public.catalogo c on c.sku = a.sku
  where a.ad_id = v_ad and a.ativo limit 1;

  select max(created_at) into v_corte from public.messages where conversation_id = p_conversation and direction = 'out';
  select coalesce(jsonb_agg(jsonb_build_object('quem', case when t.direction = 'in' then 'cliente' else 'voce' end, 'texto', left(coalesce(t.body, '[' || t.type || ']'), 400)) order by t.created_at), '[]'::jsonb)
  into v_hist
  from (
    select direction, body, type, created_at from public.messages
    where conversation_id = p_conversation and created_at <= coalesce(v_corte, '-infinity'::timestamptz)
    order by created_at desc limit coalesce(cfg.historico_mensagens, 6)
  ) t;

  select jsonb_build_object(
    'orcamento_id', o.id, 'numero', 'SG-' || lpad(o.numero::text, 4, '0'), 'status', o.status, 'total', o.total,
    'validade', to_char(o.validade_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI'),
    'data_prevista', to_char(o.data_prevista, 'DD/MM/YYYY'),
    'pdf_enviado', o.pdf_enviado_em is not null,
    'link_pagamento_valido', (o.link_pagamento is not null and coalesce(o.link_pagamento_expira_em, now() - interval '1 second') > now()))
  into v_orc
  from public.orcamentos o
  where o.contact_id = cv.contact_id and o.status in ('rascunho', 'enviado', 'aceito') and (o.validade_ate is null or o.validade_ate > now())
  order by o.criado_em desc limit 1;

  -- todos os orçamentos abertos, do mais novo ao mais antigo, com os itens de cada um
  select coalesce(jsonb_agg(x.j order by x.criado_em desc), '[]'::jsonb) into v_orcs from (
    select o.criado_em, jsonb_build_object(
      'orcamento_id', o.id, 'numero', 'SG-' || lpad(o.numero::text, 4, '0'), 'status', o.status, 'total', o.total,
      'data_prevista', to_char(o.data_prevista, 'DD/MM/YYYY'),
      'pdf_enviado', o.pdf_enviado_em is not null,
      'link_pagamento_valido', (o.link_pagamento is not null and coalesce(o.link_pagamento_expira_em, now() - interval '1 second') > now()),
      'itens', coalesce((select jsonb_agg(jsonb_build_object('produto', left(coalesce(i.descricao, ''), 90), 'pacotes', i.quantidade,
                          'unidades', case when c.quantidade is not null then c.quantidade * i.quantidade end) order by i.criado_em, i.id)
                           from public.orcamento_itens i left join public.catalogo c on c.sku = i.sku where i.orcamento_id = o.id), '[]'::jsonb)) j
    from public.orcamentos o
    where o.contact_id = cv.contact_id and o.status in ('rascunho', 'enviado', 'aceito') and (o.validade_ate is null or o.validade_ate > now())
    order by o.criado_em desc limit 4
  ) x;

  select o.stage into v_pedido from public.orders o where o.contact_id = cv.contact_id order by o.created_at desc limit 1;
  select exists (select 1 from public.orders o where o.contact_id = cv.contact_id and o.stage in ('entregue', 'recompra')) into v_recorrente;

  return jsonb_build_object(
    'agora', v_dias[extract(dow from v_agora)::int + 1] || ', ' || to_char(v_agora, 'DD/MM/YYYY "às" HH24:MI'),
    'hoje_iso', to_char(v_agora, 'YYYY-MM-DD'),
    'contato', jsonb_build_object(
      'primeiro_nome', nullif(initcap(split_part(coalesce(ct.name, ''), ' ', 1)), ''), 'segmento', ct.segment,
      'bairro', ct.bairro, 'cep', ct.cep, 'situacao', ct.status_lead, 'cliente_recorrente', v_recorrente),
    'anuncio', case when v_ref is null then null else jsonb_build_object(
      'titulo', left(coalesce(v_ref ->> 'headline', ''), 120), 'texto', left(coalesce(v_ref ->> 'body', ''), 160),
      'produto', v_prod) end,
    'etapa', jsonb_build_object('conversa', cv.stage, 'pedido', v_pedido),
    'resumo', cv.summary,
    'dados_coletados', coalesce(cv.collected_data, '{}'::jsonb) - 'teste_falha' - 'resumo_ate',
    'ultimas_mensagens', v_hist,
    'orcamento_aberto', v_orc,
    'orcamentos_abertos', v_orcs,
    'primeiro_contato', not exists (select 1 from public.messages where conversation_id = p_conversation and direction = 'out'),
    'nome_atendente', cfg.nome_atendente);
end;
$function$;
