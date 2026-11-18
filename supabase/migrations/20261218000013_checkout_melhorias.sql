-- 18/11/2026 (noite, 2): melhorias do checkout próprio depois do primeiro teste real (Pix).
-- 1) parcelamento: até 12x no cartão (até 2x sem juros; de 3x a 12x o Mercado Pago cobra os juros do cliente);
-- 2) mais upsell: trocar a quantidade (tiragem maior), até 5 sugestões e até 5 itens extras;
-- 3) toda mudança no checkout atualiza o pedido, o orçamento e o valor do link na hora;
-- 4) lembrete automático no WhatsApp: checkout aberto e 15 minutos sem pagar (regra PAG_CHK).
-- Aditiva e idempotente.

-- ---------------------------------------------------------------- 3) mudança no checkout atualiza pedido, orçamento e link
create or replace function private.checkout_sincronizar_orcamento(p_order uuid) returns void
language plpgsql security definer set search_path = ''
as $f$
declare o public.orcamentos%rowtype; v_bruto numeric; v_desc_pct numeric; v_arte numeric; v_total numeric;
begin
  -- o valor do link ativo (sem tentativa de pagamento presa) acompanha o pedido
  select total into v_total from public.order_financials where order_id = p_order;
  if coalesce(v_total, 0) > 0 then
    update public.pagamentos set valor = v_total, atualizado_em = now()
     where order_id = p_order and eh_link and link_ativo and mp_payment_id is null and valor is distinct from v_total;
  end if;
  select * into o from public.orcamentos where order_id = p_order and status in ('rascunho', 'enviado', 'aceito') order by criado_em desc limit 1;
  if not found then return; end if;
  delete from public.orcamento_itens where orcamento_id = o.id;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, custo_unitario)
  select o.id, nullif(btrim(oi.code), ''), oi.description, oi.qty, oi.unit_price, oi.unit_cost
    from public.order_items oi where oi.order_id = p_order and oi.description !~* '^cria[cç][aã]o de arte';
  select coalesce(sum(oi.qty * oi.unit_price), 0) into v_arte from public.order_items oi where oi.order_id = p_order and oi.description ~* '^cria[cç][aã]o de arte';
  select coalesce(sum(oi.qty * oi.unit_price), 0), coalesce(max(o2.discount_pct), 0) into v_bruto, v_desc_pct
    from public.order_items oi join public.orders o2 on o2.id = oi.order_id where oi.order_id = p_order and oi.description !~* '^cria[cç][aã]o de arte';
  update public.orcamentos set desconto_valor = round(v_bruto * v_desc_pct / 100, 2), itens_exibicao = null, arte_valor = round(v_arte, 2),
         arte_modo = case when v_arte > 0 then 'paga' when arte_modo = 'paga' then 'nenhuma' else arte_modo end
   where id = o.id;
end;
$f$;
revoke all on function private.checkout_sincronizar_orcamento(uuid) from public, anon, authenticated;

-- até 5 itens extras
do $m$
declare d text;
begin
  select pg_get_functiondef('public.checkout_adicionar_produto(text,text)'::regprocedure) into d;
  if position('>= 5 then' in d) = 0 then
    d := replace(d, 'description !~* ''^(cria[cç][aã]o de arte|confer[eê]ncia e ajuste)'') >= 3 then', 'description !~* ''^(cria[cç][aã]o de arte|confer[eê]ncia e ajuste)'') >= 5 then');
    if position('>= 5 then' in d) = 0 then raise exception 'checkout_adicionar_produto mudou: ajuste o patch.'; end if;
    execute d;
  end if;
end $m$;

-- ---------------------------------------------------------------- 2) mais upsell
-- Sugestões: até 5 cards, com mais combinações por categoria
create or replace function private.checkout_sugestoes(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_contact uuid; v_conv uuid; v_cats text[]; v_qtd integer; v_texto text; v_out jsonb := '[]'::jsonb; r record; p record;
begin
  select contact_id, conversation_id into v_contact, v_conv from public.orders where id = p_order;
  select coalesce(array_agg(distinct e.categoria_slug), '{}'), coalesce(max(e.quantidade), 1) into v_cats, v_qtd
    from public.order_items oi join public.ecommerce_products e on e.sku = oi.code where oi.order_id = p_order;
  select lower(coalesce(string_agg(body, ' '), '')) into v_texto from (
    select body from public.messages where conversation_id = v_conv and direction = 'in' and deleted_at is null and body is not null
       and created_at > now() - interval '30 days' order by created_at desc limit 60) m;

  for r in
    with par(origem, destino, motivo, pts) as (values
      ('cartoes|cartao', 'pastas', 'Cartão e pasta andam juntos: apresente sua empresa por completo.', 10),
      ('cartoes|cartao', 'adesivos', 'Um adesivo da sua marca em cada entrega faz o cliente lembrar de você.', 8),
      ('cartoes|cartao', 'cartoes-fidelidade', 'Cartão fidelidade faz o cliente voltar: mais vendas com o mesmo cliente.', 7),
      ('panfleto|filipeta|folhas', 'banners-faixas-lonas-e-tecidos', 'Panfleto convida, banner chama a atenção na porta do seu negócio.', 10),
      ('panfleto|filipeta|folhas', 'cartoes-de-visita', 'Quem pega o panfleto leva o seu cartão para ligar depois.', 8),
      ('panfleto|filipeta|folhas', 'adesivos', 'Adesivo da sua marca para colar no que você entrega.', 7),
      ('adesivo|rotulo', 'sacolas-e-sacos', 'Leve sacolas com a sua marca e entregue o adesivo com mais charme.', 10),
      ('adesivo|rotulo', 'cartoes-de-visita', 'Adesivo chama atenção, o cartão fecha o contato.', 8),
      ('adesivo|rotulo', 'tags', 'Tags para etiquetar e deixar o produto com cara de loja.', 7),
      ('banner|lona|faixa|wind', 'cartoes-de-visita', 'Quem vê o banner leva o seu cartão no bolso.', 10),
      ('banner|lona|faixa|wind', 'panfletos-flyers-e-folhetos', 'Banner na porta e panfleto na mão: divulgação completa.', 8),
      ('pasta', 'cartoes-de-visita', 'Pasta pronta merece o cartão de visita para acompanhar.', 10),
      ('pasta', 'envelopes', 'Envelope com a sua marca para enviar propostas.', 8),
      ('pasta', 'adesivos', 'Feche a pasta com um adesivo da sua marca.', 7),
      ('sacola|caixa|embalagem', 'adesivos', 'Feche a embalagem com um adesivo da sua marca.', 10),
      ('sacola|caixa|embalagem', 'tags', 'Tags com a sua marca deixam a embalagem mais bonita.', 8),
      ('sacola|caixa|embalagem', 'cartoes-de-visita', 'Um cartão dentro de cada embalagem aproxima o cliente.', 7)),
    mencao(destino, termo) as (values
      ('pastas', 'pasta'), ('adesivos', 'adesiv|r[oó]tulo'), ('cartoes-de-visita', 'cart[aã]o|cart[oõ]es'),
      ('sacolas-e-sacos', 'sacola|sacos'), ('banners-faixas-lonas-e-tecidos', 'banner|lona|faixa'),
      ('tags', 'tag|etiqueta'), ('envelopes', 'envelope'), ('cartoes-fidelidade', 'fidelidade')),
    casa as (
      select destino, (array_agg(motivo order by pts desc))[1] as motivo, max(pts) as pts, false as citou
        from par where exists (select 1 from unnest(v_cats) c where c ~ origem) group by destino),
    padrao as (
      select 'cartoes-de-visita'::text as destino, 'O cartão de visita é o item que mais combina com qualquer pedido.'::text as motivo, 5 as pts, false as citou
       where not exists (select 1 from casa)),
    cit as (
      select m.destino, 'Você comentou isso na conversa: vale incluir no mesmo pedido.'::text as motivo, 6 as pts, true as citou
        from mencao m where v_texto ~ m.termo),
    todas as (
      select destino, (array_agg(motivo order by pts desc))[1] as motivo, sum(pts) as pts, bool_or(citou) as citou
        from (select * from casa union all select * from padrao union all select * from cit) x group by destino)
    select t.destino, t.motivo, t.citou, h.comprou, t.pts + case when h.comprou then 4 else 0 end as pontos
      from todas t
      cross join lateral (select exists (select 1 from public.orders o2 join public.order_items i2 on i2.order_id = o2.id
                                           join public.ecommerce_products e2 on e2.sku = i2.code
                                          where o2.contact_id = v_contact and o2.payment_status = 'aprovado' and e2.categoria_slug = t.destino) as comprou) h
     where not (t.destino = any (v_cats))
       and not exists (select 1 from public.order_items i3 join public.ecommerce_products e3 on e3.sku = i3.code where i3.order_id = p_order and i3.checkout_extra and e3.categoria_slug = t.destino)
     order by pontos desc, t.destino limit 5
  loop
    select e.ref, e.sku_slug, e.titulo, e.variante, e.quantidade, e.preco, e.parcela_2x, e.prazo_dias_uteis, e.fotos ->> 0 as foto into p
      from public.ecommerce_products e
     where e.categoria_slug = r.destino and e.ativo and e.preco > 0
     order by (e.fotos = '[]'::jsonb), abs(coalesce(e.quantidade, 1) - v_qtd), e.preco limit 1;
    if found then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'ref', p.ref, 'slug', p.sku_slug, 'titulo', p.titulo || coalesce(' · ' || p.variante, ''), 'quantidade', p.quantidade,
        'preco', p.preco, 'parcela_2x', p.parcela_2x, 'prazo_dias_uteis', p.prazo_dias_uteis, 'foto', p.foto,
        'motivo', r.motivo,
        'selo', case when r.citou then 'Você comentou na conversa' when r.comprou then 'Reposição' else 'Combina com o seu pedido' end));
    end if;
  end loop;
  return v_out;
end;
$$;
revoke all on function private.checkout_sugestoes(uuid) from public, anon, authenticated;

-- Tiragens do mesmo produto (mesma versão), para o cliente levar mais por menos por unidade
create or replace function private.checkout_quantidades(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare it record; cur record; v_out jsonb := '[]'::jsonb; v_ops jsonb; o record;
begin
  for it in select oi.id, oi.code, oi.qty, oi.description from public.order_items oi
             where oi.order_id = p_order and oi.code is not null and oi.qty = 1 order by oi.created_at limit 2 loop
    select e.produto_slug, e.variante, e.quantidade, e.preco into cur from public.ecommerce_products e where e.sku = it.code;
    if not found or cur.quantidade is null then continue; end if;
    select coalesce(jsonb_agg(jsonb_build_object('ref', x.ref, 'quantidade', x.quantidade, 'preco', x.preco, 'unitario', round(x.preco / nullif(x.quantidade, 0), 3),
                    'atual', x.sku = it.code) order by x.quantidade), '[]'::jsonb) into v_ops
      from (select e.ref, e.sku, e.quantidade, e.preco from public.ecommerce_products e
             where e.produto_slug = cur.produto_slug and e.variante is not distinct from cur.variante and e.ativo and e.preco > 0 and e.quantidade is not null
               and (e.quantidade between cur.quantidade / 4 and cur.quantidade * 6 or e.sku = it.code)
             order by e.quantidade limit 8) x;
    if jsonb_array_length(v_ops) >= 2 then
      v_out := v_out || jsonb_build_array(jsonb_build_object('item_id', it.id, 'descricao', it.description, 'opcoes', v_ops));
    end if;
  end loop;
  return v_out;
end;
$$;
revoke all on function private.checkout_quantidades(uuid) from public, anon, authenticated;

-- carregar: até 12 parcelas (2 sem juros) e as tiragens
do $m$
declare d text;
begin
  select pg_get_functiondef('public.checkout_carregar(text)'::regprocedure) into d;
  if position('checkout_quantidades' in d) = 0 then
    d := replace(d, '''max_parcelas'', least(coalesce(pr.parcelas_sem_juros_max, 2), 2),', '''max_parcelas'', 12, ''parcelas_sem_juros'', least(coalesce(pr.parcelas_sem_juros_max, 2), 2),');
    d := replace(d, '''faltando'', to_jsonb(v_faltando),', '''faltando'', to_jsonb(v_faltando), ''quantidades'', case when v_estado in (''aberto'', ''em_analise'') then private.checkout_quantidades(o.id) else ''[]''::jsonb end,');
    if position('checkout_quantidades' in d) = 0 or position('''parcelas_sem_juros''' in d) = 0 then raise exception 'checkout_carregar mudou: ajuste o patch.'; end if;
    execute d;
  end if;
end $m$;

-- Trocar a tiragem de um item (mesmo produto e versão): o preço vem de calcular_preco (planilha, com piso)
create or replace function public.checkout_trocar_quantidade(p_token text, p_item uuid, p_ref text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; it public.order_items%rowtype; cur record; nw record; r jsonb; v_custo numeric; v_prazo integer; v_total numeric; v_link timestamptz; v_desc text;
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  if o.payment_status = 'aprovado' then return jsonb_build_object('ok', false, 'erro', 'pedido_ja_pago'); end if;
  select expira_em into v_link from public.pagamentos where order_id = o.id and eh_link and link_ativo order by criado_em desc limit 1;
  if v_link is null or v_link <= now() then return jsonb_build_object('ok', false, 'erro', 'link_expirado'); end if;
  select * into it from public.order_items where id = p_item and order_id = o.id and code is not null and qty = 1;
  if not found then return jsonb_build_object('ok', false, 'erro', 'item_nao_encontrado'); end if;
  select produto_slug, variante into cur from public.ecommerce_products where sku = it.code;
  if not found then return jsonb_build_object('ok', false, 'erro', 'produto_fora_da_vitrine'); end if;
  select sku, titulo, variante, quantidade into nw from public.ecommerce_products
   where ref = btrim(coalesce(p_ref, '')) and ativo and produto_slug = cur.produto_slug and variante is not distinct from cur.variante;
  if not found then return jsonb_build_object('ok', false, 'erro', 'opcao_invalida'); end if;
  if nw.sku = it.code then return jsonb_build_object('ok', true, 'sem_mudanca', true); end if;
  if exists (select 1 from public.order_items where order_id = o.id and code = nw.sku) then return jsonb_build_object('ok', false, 'erro', 'ja_no_pedido'); end if;
  r := public.calcular_preco(nw.sku, 1, jsonb_build_object('entrega', 'retirada'));
  if r is null or not coalesce((r ->> 'ok')::boolean, false) then return jsonb_build_object('ok', false, 'erro', 'produto_indisponivel'); end if;
  select custo, prazo_dias_uteis into v_custo, v_prazo from public.catalogo where sku = nw.sku;
  v_desc := nw.titulo || ' · ' || coalesce(nw.quantidade, 1)::text || ' un.' || coalesce(' · ' || nw.variante, '');
  update public.order_items set code = nw.sku, description = v_desc, unit_cost = coalesce(v_custo, 0), unit_price = (r ->> 'preco_total')::numeric, lead_days = v_prazo where id = it.id;
  perform private.checkout_sincronizar_orcamento(o.id);
  insert into public.order_events (order_id, kind, message) values (o.id, 'price', 'Cliente trocou a quantidade no checkout: ' || it.description || ' por ' || v_desc || '.');
  perform private.checkout_evento(o.id, 'quantidade_trocada', jsonb_build_object('ref', p_ref));
  select total into v_total from public.order_financials where order_id = o.id;
  return jsonb_build_object('ok', true, 'total', v_total);
end;
$$;
revoke all on function public.checkout_trocar_quantidade(text, uuid, text) from public, anon, authenticated;
grant execute on function public.checkout_trocar_quantidade(text, uuid, text) to service_role;

-- as demais mudanças também acertam o valor do link (a arte e o item extra já chamavam a sincronização)

-- ---------------------------------------------------------------- 4) lembrete: checkout aberto e 15 minutos sem pagar
do $m$
declare c text;
begin
  for c in select conname from pg_constraint where conrelid = 'public.followup_regras'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%referencia%' loop
    execute format('alter table public.followup_regras drop constraint %I', c);
  end loop;
  alter table public.followup_regras add constraint followup_regras_referencia_check
    check (referencia = any (array['orcamento_enviado', 'link_pagamento', 'pedido_entregue', 'pedido_pago', 'conversa_parada', 'checkout_aberto']));
end $m$;

insert into public.followup_regras (codigo, descricao, referencia, atraso_minutos, template_janela_fechada, hora_min, hora_max, ativo, revisar)
values ('PAG_CHK', 'Cliente abriu o checkout e ficou 15 minutos sem pagar (Pix de qualquer banco e cartão em até 2x sem juros)', 'checkout_aberto', 15, 'pagamento_pendente', 8, 20, true, false)
on conflict (codigo) do nothing;

do $m$
declare d text;
begin
  select pg_get_functiondef('public.followup_montar(uuid,timestamptz)'::regprocedure) into d;
  if position('PAG_CHK' in d) = 0 then
    d := replace(d, 'v_texto := case f.regra_codigo when ''PAG_20M'' then',
      'v_texto := case f.regra_codigo when ''PAG_CHK'' then format(''Oi, %s! Vi que você abriu o link do pedido %s e ainda não finalizou. Ficou alguma dúvida? O Pix de qualquer banco cai na hora e o cartão vai em até 2x sem juros: %s Posso te ajudar com alguma coisa?'', n, v_num, v_link) when ''PAG_20M'' then');
    if position('PAG_CHK' in d) = 0 then raise exception 'followup_montar mudou: ajuste o patch do PAG_CHK.'; end if;
    execute d;
  end if;
end $m$;

-- Registrar o evento "aberto" agenda o lembrete (uma vez por pedido); nunca bloqueia o checkout
create or replace function private.checkout_evento(p_order uuid, p_tipo text, p_detalhe jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = ''
as $$
declare ord public.orders%rowtype;
begin
  insert into public.checkout_eventos (order_id, tipo, detalhe) values (p_order, p_tipo, coalesce(p_detalhe, '{}'::jsonb));
  if p_tipo = 'aberto' then
    begin
      select * into ord from public.orders where id = p_order;
      if ord.payment_status is distinct from 'aprovado' and ord.cancelado_em is null and ord.excluido_em is null and ord.conversation_id is not null
         and not exists (select 1 from public.followup_fila where order_id = p_order and regra_codigo like 'PAG\_%' and status = 'enviado' and enviado_em > now() - interval '30 minutes') then
        -- o lembrete de 20 min depois do link seria um segundo toque colado neste
        update public.followup_fila set status = 'cancelado', motivo = 'substituido_pelo_checkout_aberto'
         where order_id = p_order and regra_codigo = 'PAG_20M' and status = 'pendente';
        insert into public.followup_fila (contact_id, conversation_id, orcamento_id, order_id, regra_codigo, chave, agendado_para, teste)
        select ord.contact_id, ord.conversation_id, (select oc.id from public.orcamentos oc where oc.order_id = ord.id order by oc.criado_em desc limit 1), ord.id,
               r.codigo, r.codigo || ':' || ord.id::text, private.fu_proxima_janela(now() + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max), coalesce(ord.teste, false)
          from public.followup_regras r where r.codigo = 'PAG_CHK' and r.ativo
        on conflict (chave) do nothing;
      end if;
    exception when others then
      raise warning 'lembrete do checkout não agendado: %', sqlerrm;
    end;
  end if;
end;
$$;
revoke all on function private.checkout_evento(uuid, text, jsonb) from public, anon, authenticated;
