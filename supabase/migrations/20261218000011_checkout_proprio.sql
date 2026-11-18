-- 18/11/2026: checkout próprio da gráfica (https://suagraficabh.com.br/pagar/<token>).
-- O cliente paga Pix ou cartão (até 2x sem juros) dentro do nosso site, sem abrir o app do Mercado Pago.
-- Aditiva e idempotente. Tudo é lido e gravado só pela service role (Edge Functions checkout-dados e checkout-mp-processar);
-- o público nunca acessa as tabelas. Nenhuma resposta traz SKU, custo, piso, margem ou fornecedor.

-- 1) Token do checkout: um por pedido, estável (o mesmo link serve de novo quando o dono renova a validade)
alter table public.orders add column if not exists checkout_token text;
alter table public.orders alter column checkout_token set default replace(gen_random_uuid()::text, '-', '');
update public.orders set checkout_token = replace(gen_random_uuid()::text, '-', '') where checkout_token is null;
alter table public.orders alter column checkout_token set not null;
create unique index if not exists orders_checkout_token_uq on public.orders (checkout_token);

-- Itens que o cliente acrescentou no checkout (só estes podem ser removidos por ele)
alter table public.order_items add column if not exists checkout_extra boolean not null default false;

-- 2) Linha do tempo do checkout (abriu, preencheu, tentou pagar, recusou, erro técnico). Só o dono lê.
create table if not exists public.checkout_eventos (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  tipo text not null check (length(tipo) between 2 and 40),
  detalhe jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now()
);
create index if not exists checkout_eventos_order_idx on public.checkout_eventos (order_id, criado_em desc);
alter table public.checkout_eventos enable row level security;
revoke all on public.checkout_eventos from anon;
drop policy if exists checkout_eventos_select on public.checkout_eventos;
create policy checkout_eventos_select on public.checkout_eventos for select to authenticated using (private.is_staff());

-- 3) Auxiliares internos
create or replace function private.checkout_pedido(p_token text) returns public.orders
language plpgsql stable security definer set search_path = ''
as $$
declare o public.orders%rowtype;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then return null; end if;
  select * into o from public.orders where checkout_token = p_token;
  if not found then return null; end if;
  return o;
end;
$$;
revoke all on function private.checkout_pedido(text) from public, anon, authenticated;

create or replace function private.checkout_evento(p_order uuid, p_tipo text, p_detalhe jsonb default '{}'::jsonb) returns void
language sql security definer set search_path = ''
as $$ insert into public.checkout_eventos (order_id, tipo, detalhe) values (p_order, p_tipo, coalesce(p_detalhe, '{}'::jsonb)); $$;
revoke all on function private.checkout_evento(uuid, text, jsonb) from public, anon, authenticated;

-- Mantém o orçamento (e o PDF) iguais ao pedido depois de uma mudança feita no checkout.
-- Mesma regra de public.pedido_sincronizar_orcamento, sem exigir usuário logado.
create or replace function private.checkout_sincronizar_orcamento(p_order uuid) returns void
language plpgsql security definer set search_path = ''
as $f$
declare o public.orcamentos%rowtype; v_bruto numeric; v_desc_pct numeric; v_arte numeric;
begin
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

-- 4) Sugestões do checkout: combina o que o cliente já leva, a conversa dos últimos 30 dias, o histórico de compras e a quantidade.
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
    with par(origem, destino, motivo) as (values
      ('cartoes|cartao', 'pastas', 'Cartão e pasta andam juntos: apresente sua empresa por completo.'),
      ('panfleto|filipeta|folhas', 'banners-faixas-lonas-e-tecidos', 'Panfleto convida, banner chama a atenção na porta do seu negócio.'),
      ('adesivo|rotulo', 'sacolas-e-sacos', 'Leve sacolas com a sua marca e entregue o adesivo com mais charme.'),
      ('banner|lona|faixa|wind', 'cartoes-de-visita', 'Quem vê o banner leva o seu cartão no bolso.'),
      ('pasta', 'cartoes-de-visita', 'Pasta pronta merece o cartão de visita para acompanhar.'),
      ('sacola|caixa|embalagem', 'adesivos', 'Feche a embalagem com um adesivo da sua marca.')),
    mencao(destino, termo) as (values
      ('pastas', 'pasta'), ('adesivos', 'adesiv|r[oó]tulo'), ('cartoes-de-visita', 'cart[aã]o|cart[oõ]es'),
      ('sacolas-e-sacos', 'sacola|sacos'), ('banners-faixas-lonas-e-tecidos', 'banner|lona|faixa')),
    casa as (
      select destino, (array_agg(motivo))[1] as motivo, 10 as pts, false as citou
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
     order by pontos desc, t.destino limit 3
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

-- 5) Carregar o checkout (resumo público do pedido)
create or replace function public.checkout_carregar(p_token text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders%rowtype; c public.contacts%rowtype; orc public.orcamentos%rowtype; pr public.parametros_comerciais%rowtype;
  v_fin record; v_link record; v_pag record; v_estado text; v_itens jsonb; v_arte_atual text; v_arte_inclusa boolean := false; v_faltando text[] := '{}';
  v_total numeric; v_gross numeric; v_ent text; v_doc text;
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  select * into c from public.contacts where id = o.contact_id;
  select * into pr from public.parametros_comerciais where id = 1;
  select * into orc from public.orcamentos where order_id = o.id order by criado_em desc limit 1;
  select gross, total into v_fin from public.order_financials where order_id = o.id;
  v_total := coalesce(v_fin.total, 0); v_gross := coalesce(v_fin.gross, 0);
  select expira_em, criado_em into v_link from public.pagamentos where order_id = o.id and eh_link and link_ativo order by criado_em desc limit 1;
  select status, metodo, aprovado_em into v_pag from public.pagamentos where order_id = o.id and status in ('aprovado', 'em_analise') order by (status = 'aprovado') desc, criado_em desc limit 1;

  v_estado := case
    when o.payment_status = 'aprovado' then 'pago'
    when o.cancelado_em is not null or o.excluido_em is not null then 'cancelado'
    when v_link.expira_em is null or v_link.expira_em <= now() then 'expirado'
    when v_pag.status = 'em_analise' then 'em_analise'
    else 'aberto' end;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', case when oi.checkout_extra then oi.id end, 'descricao', oi.description, 'quantidade', oi.qty,
      'unitario', oi.unit_price, 'subtotal', round(oi.qty * oi.unit_price, 2), 'extra', oi.checkout_extra,
      'tipo', case when oi.description ~* '^(cria[cç][aã]o de arte|confer[eê]ncia e ajuste)' then 'arte' else 'produto' end) order by oi.created_at), '[]'::jsonb)
    into v_itens from public.order_items oi where oi.order_id = o.id;

  select case when exists (select 1 from public.order_items where order_id = o.id and description ~* '^cria[cç][aã]o de arte') then 'criacao'
              when exists (select 1 from public.order_items where order_id = o.id and description ~* '^confer[eê]ncia e ajuste') then 'conferencia'
              else 'pronta' end into v_arte_atual;
  if v_arte_atual = 'pronta' and (o.art_mode = 'criamos' or orc.arte_modo in ('paga', 'com_frete')) then v_arte_atual := 'criacao'; v_arte_inclusa := true; end if;

  v_doc := regexp_replace(coalesce(c.document, ''), '\D', '', 'g');
  if length(btrim(coalesce(c.name, ''))) < 3 then v_faltando := array_append(v_faltando, 'nome'); end if;
  if coalesce(c.email, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_faltando := array_append(v_faltando, 'email'); end if;
  if length(v_doc) not in (11, 14) then v_faltando := array_append(v_faltando, 'documento'); end if;

  v_ent := case
    when orc.frete_modo = 'uber_cliente' or o.delivery_method = 'uber' then 'Entrega combinada pelo WhatsApp'
    when orc.entrega in ('bike', 'uber') then 'Entrega na região central' || coalesce(' (' || nullif(orc.bairro, '') || ')', '')
    else 'Retirada agendada no balcão da Praça Sete' end;

  if v_estado = 'aberto' and not exists (select 1 from public.checkout_eventos where order_id = o.id and tipo = 'aberto' and criado_em > now() - interval '10 minutes') then
    perform private.checkout_evento(o.id, 'aberto', '{}'::jsonb);
  end if;

  return jsonb_build_object(
    'ok', true, 'estado', v_estado,
    'pedido', jsonb_build_object('numero', 'SG-' || lpad(o.number::text, 4, '0'), 'criado_em', o.created_at, 'teste', o.teste),
    'itens', v_itens,
    'subtotal', v_gross, 'desconto_valor', round(v_gross - v_total, 2), 'desconto_pct', o.discount_pct, 'total', v_total,
    'entrega', jsonb_build_object('texto', v_ent, 'frete_gratis', true),
    'prazo', jsonb_build_object('data_prevista', coalesce(o.due_date, orc.data_prevista),
              'texto', 'O prazo conta a partir da aprovação da arte. Pagou até 10h30 em dia útil, a produção começa no mesmo dia.'),
    'validade_ate', v_link.expira_em,
    'cliente', jsonb_build_object('nome', c.name, 'email', c.email, 'documento_final', case when length(v_doc) in (11, 14) then right(v_doc, 3) end,
              'tem_documento', length(v_doc) in (11, 14), 'whatsapp_final', right(regexp_replace(coalesce(c.wa_id, ''), '\D', '', 'g'), 4)),
    'faltando', to_jsonb(v_faltando),
    'pagamento', jsonb_build_object('pix', v_total, 'max_parcelas', least(coalesce(pr.parcelas_sem_juros_max, 2), 2),
              'parcelas', jsonb_build_array(jsonb_build_object('n', 1, 'valor', v_total), jsonb_build_object('n', 2, 'valor', round(v_total / 2, 2))),
              'metodo_pago', v_pag.metodo, 'parcelas_pagas', o.parcelas),
    'arte', jsonb_build_object('atual', v_arte_atual, 'inclusa', v_arte_inclusa, 'opcoes', jsonb_build_array(
        jsonb_build_object('codigo', 'pronta', 'titulo', 'Já tenho a arte pronta', 'texto', 'Você envia o arquivo e a gente imprime do jeito que veio.', 'valor', 0),
        jsonb_build_object('codigo', 'conferencia', 'titulo', 'Conferir e ajustar meu arquivo', 'texto', 'Revisamos medidas, sangria e resolução para a impressão sair certa.', 'valor', pr.arte_conferencia_valor),
        jsonb_build_object('codigo', 'criacao', 'titulo', 'Criar a arte pra mim', 'texto', 'Nossa equipe desenha a sua arte do zero com a sua marca. Prazo conta da aprovação.', 'valor', pr.arte_valor))),
    'sugestoes', case when v_estado in ('aberto', 'em_analise') then private.checkout_sugestoes(o.id) else '[]'::jsonb end,
    'whatsapp', '5531975618243');
end;
$$;

-- 6) Status leve para a tela esperar a confirmação (a cada poucos segundos)
create or replace function public.checkout_status(p_token text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_pag record;
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  select status, metodo, status_detalhe into v_pag from public.pagamentos where order_id = o.id and mp_payment_id is not null order by atualizado_em desc limit 1;
  return jsonb_build_object('ok', true, 'pago', o.payment_status = 'aprovado', 'pagamento_status', v_pag.status, 'metodo', v_pag.metodo, 'detalhe', v_pag.status_detalhe, 'parcelas', o.parcelas);
end;
$$;

-- 7) Salvar nome, e-mail e CPF/CNPJ no contato (o cliente confirmou os dados na tela)
create or replace function public.checkout_salvar_dados(p_token text, p_nome text, p_email text, p_documento text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_nome text := left(btrim(coalesce(p_nome, '')), 120); v_email text := lower(btrim(coalesce(p_email, ''))); v_doc text := regexp_replace(coalesce(p_documento, ''), '\D', '', 'g');
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  if o.payment_status = 'aprovado' then return jsonb_build_object('ok', false, 'erro', 'pedido_ja_pago'); end if;
  if (select count(*) from public.checkout_eventos where order_id = o.id and tipo = 'dados_salvos' and criado_em > now() - interval '10 minutes') >= 12 then
    return jsonb_build_object('ok', false, 'erro', 'muitas_tentativas');
  end if;
  if length(v_nome) < 3 then return jsonb_build_object('ok', false, 'erro', 'nome_invalido'); end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 160 then return jsonb_build_object('ok', false, 'erro', 'email_invalido'); end if;
  if length(v_doc) not in (11, 14) then return jsonb_build_object('ok', false, 'erro', 'documento_invalido'); end if;
  update public.contacts set name = v_nome, email = v_email, document = v_doc where id = o.contact_id;
  perform private.checkout_evento(o.id, 'dados_salvos', '{}'::jsonb);
  return jsonb_build_object('ok', true);
end;
$$;

-- 8) Arte: troca a opção no pedido (só soma lucro: a arte não tem custo de fornecedor)
create or replace function public.checkout_definir_arte(p_token text, p_arte text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; pr public.parametros_comerciais%rowtype; v_total numeric; v_link timestamptz;
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  if p_arte not in ('pronta', 'conferencia', 'criacao') then return jsonb_build_object('ok', false, 'erro', 'arte_invalida'); end if;
  if o.payment_status = 'aprovado' then return jsonb_build_object('ok', false, 'erro', 'pedido_ja_pago'); end if;
  select expira_em into v_link from public.pagamentos where order_id = o.id and eh_link and link_ativo order by criado_em desc limit 1;
  if v_link is null or v_link <= now() then return jsonb_build_object('ok', false, 'erro', 'link_expirado'); end if;
  -- arte incluída por condição especial: não mexe
  if o.art_mode = 'criamos' and not exists (select 1 from public.order_items where order_id = o.id and description ~* '^(cria[cç][aã]o de arte|confer[eê]ncia e ajuste)') then
    return jsonb_build_object('ok', false, 'erro', 'arte_incluida');
  end if;
  select * into pr from public.parametros_comerciais where id = 1;
  delete from public.order_items where order_id = o.id and description ~* '^(cria[cç][aã]o de arte|confer[eê]ncia e ajuste)';
  if p_arte = 'criacao' then
    insert into public.order_items (order_id, code, fora_catalogo, description, qty, unit_cost, unit_price, checkout_extra) values (o.id, null, true, 'Criação de arte', 1, 0, pr.arte_valor, true);
  elsif p_arte = 'conferencia' then
    insert into public.order_items (order_id, code, fora_catalogo, description, qty, unit_cost, unit_price, checkout_extra) values (o.id, null, true, 'Conferência e ajuste técnico do arquivo', 1, 0, pr.arte_conferencia_valor, true);
  end if;
  update public.orders set art_mode = case when p_arte = 'criacao' then 'criamos' else 'cliente' end where id = o.id;
  perform private.checkout_sincronizar_orcamento(o.id);
  insert into public.order_events (order_id, kind, message) values (o.id, 'art', 'Cliente escolheu no checkout: ' || case p_arte when 'criacao' then 'criar a arte' when 'conferencia' then 'conferir e ajustar o arquivo' else 'arte própria pronta' end || '.');
  perform private.checkout_evento(o.id, 'arte_definida', jsonb_build_object('arte', p_arte));
  select total into v_total from public.order_financials where order_id = o.id;
  return jsonb_build_object('ok', true, 'total', v_total);
end;
$$;

-- 9) Cross-sell: adiciona 1 lote de um produto sugerido, com o preço da planilha calculado pelo banco
create or replace function public.checkout_adicionar_produto(p_token text, p_ref text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_sku text; e record; r jsonb; v_custo numeric; v_total numeric; v_link timestamptz; v_desc text;
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  if o.payment_status = 'aprovado' then return jsonb_build_object('ok', false, 'erro', 'pedido_ja_pago'); end if;
  select expira_em into v_link from public.pagamentos where order_id = o.id and eh_link and link_ativo order by criado_em desc limit 1;
  if v_link is null or v_link <= now() then return jsonb_build_object('ok', false, 'erro', 'link_expirado'); end if;
  if (select count(*) from public.order_items where order_id = o.id and checkout_extra and description !~* '^(cria[cç][aã]o de arte|confer[eê]ncia e ajuste)') >= 3 then
    return jsonb_build_object('ok', false, 'erro', 'limite_de_itens');
  end if;
  select sku, titulo, variante, quantidade into e from public.ecommerce_products where ref = btrim(coalesce(p_ref, '')) and ativo;
  if not found then return jsonb_build_object('ok', false, 'erro', 'produto_nao_encontrado'); end if;
  v_sku := e.sku;
  if exists (select 1 from public.order_items where order_id = o.id and code = v_sku) then return jsonb_build_object('ok', false, 'erro', 'ja_no_pedido'); end if;
  r := public.calcular_preco(v_sku, 1, jsonb_build_object('entrega', 'retirada'));
  if r is null or not coalesce((r ->> 'ok')::boolean, false) then return jsonb_build_object('ok', false, 'erro', 'produto_indisponivel'); end if;
  select custo into v_custo from public.catalogo where sku = v_sku;
  v_desc := e.titulo || ' · ' || coalesce(e.quantidade, 1)::text || ' un.' || coalesce(' · ' || e.variante, '');
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price, checkout_extra)
  values (o.id, v_sku, v_desc, 1, coalesce(v_custo, 0), (r ->> 'preco_total')::numeric, true);
  perform private.checkout_sincronizar_orcamento(o.id);
  insert into public.order_events (order_id, kind, message) values (o.id, 'price', 'Cliente acrescentou no checkout: ' || v_desc || '.');
  perform private.checkout_evento(o.id, 'item_adicionado', jsonb_build_object('ref', p_ref));
  select total into v_total from public.order_financials where order_id = o.id;
  return jsonb_build_object('ok', true, 'total', v_total);
end;
$$;

create or replace function public.checkout_remover_item(p_token text, p_item uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_desc text; v_total numeric;
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  if o.payment_status = 'aprovado' then return jsonb_build_object('ok', false, 'erro', 'pedido_ja_pago'); end if;
  delete from public.order_items where id = p_item and order_id = o.id and checkout_extra and description !~* '^(cria[cç][aã]o de arte|confer[eê]ncia e ajuste)' returning description into v_desc;
  if v_desc is null then return jsonb_build_object('ok', false, 'erro', 'item_nao_removivel'); end if;
  perform private.checkout_sincronizar_orcamento(o.id);
  insert into public.order_events (order_id, kind, message) values (o.id, 'price', 'Cliente removeu no checkout: ' || v_desc || '.');
  perform private.checkout_evento(o.id, 'item_removido', '{}'::jsonb);
  select total into v_total from public.order_financials where order_id = o.id;
  return jsonb_build_object('ok', true, 'total', v_total);
end;
$$;

-- 10) Registro de eventos pela Edge Function (tentativas, recusas, erros)
create or replace function public.checkout_registrar_evento(p_token text, p_tipo text, p_detalhe jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype;
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false); end if;
  perform private.checkout_evento(o.id, left(coalesce(p_tipo, 'evento'), 40), p_detalhe);
  return jsonb_build_object('ok', true, 'pedido_id', o.id);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.checkout_carregar(text)', 'public.checkout_status(text)', 'public.checkout_salvar_dados(text, text, text, text)',
    'public.checkout_definir_arte(text, text)', 'public.checkout_adicionar_produto(text, text)', 'public.checkout_remover_item(text, uuid)',
    'public.checkout_registrar_evento(text, text, jsonb)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
