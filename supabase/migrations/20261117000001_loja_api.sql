-- E-commerce Fase 4: funções da API pública /api/v1 (busca, cotação, cálculo) e preparo do checkout.
-- Tudo reaproveita as funções que o CRM e a Laura já usam (calcular_preco com a planilha, calcular_prazo, verificar_frete,
-- montar_orcamento, validar_margem). O público identifica produto pelo ref da vitrine; nenhuma resposta tem SKU, custo, piso
-- nem detalhe interno de entrega.

alter table public.parametros_comerciais add column if not exists arte_conferencia_valor numeric(10,2) not null default 14.90;

-- ref público -> SKU interno (só itens ativos na vitrine)
create or replace function private.loja_sku(p_ref text)
returns text language sql stable security definer set search_path = '' as $$
  select e.sku from public.ecommerce_products e where e.ref = btrim(coalesce(p_ref, '')) and e.ativo;
$$;
revoke all on function private.loja_sku(text) from public, anon, authenticated;

-- arte do site -> valor e modo do orçamento
create or replace function private.loja_arte(p_arte text)
returns jsonb language sql stable set search_path = '' as $$
  select case coalesce(nullif(btrim(p_arte), ''), 'pronta')
    when 'pronta' then jsonb_build_object('arte', 'pronta', 'modo_orcamento', 'cliente', 'valor', 0, 'texto', 'Já tenho a arte pronta', 'dias_extra', 0)
    when 'conferencia' then jsonb_build_object('arte', 'conferencia', 'modo_orcamento', 'cliente', 'valor', pr.arte_conferencia_valor, 'texto', 'Conferência e ajuste técnico do arquivo', 'dias_extra', 0)
    when 'criacao' then jsonb_build_object('arte', 'criacao', 'modo_orcamento', 'paga', 'valor', pr.arte_valor, 'texto', 'Criação completa da arte', 'dias_extra', 1)
    end
  from public.parametros_comerciais pr where pr.id = 1;
$$;

-- CEP da Grande BH (faixas 30000-000 a 34999-999)
create or replace function private.loja_cep_grande_bh(p_cep text)
returns boolean language sql immutable set search_path = '' as $$
  select regexp_replace(coalesce(p_cep, ''), '\D', '', 'g') ~ '^3[0-4][0-9]{6}$';
$$;

-- Saída pública do frete: sem custo nosso, sem tipo de veículo
create or replace function private.loja_frete_publico(p_frete jsonb, p_cep text)
returns jsonb language plpgsql stable set search_path = '' as $$
declare v_gratis boolean := coalesce((p_frete ->> 'frete_gratis')::boolean, false); v_central boolean := coalesce((p_frete ->> 'regiao_central')::boolean, false);
        v_bh boolean := private.loja_cep_grande_bh(p_cep); v_opcoes jsonb;
begin
  if p_frete is null or not coalesce((p_frete ->> 'ok')::boolean, false) then
    return jsonb_build_object('ok', false, 'opcoes', jsonb_build_array(jsonb_build_object('tipo', 'retirada', 'texto', 'Retirada grátis no balcão da Praça Sete (agendada)', 'valor', 0)));
  end if;
  v_opcoes := jsonb_build_array(jsonb_build_object('tipo', 'retirada', 'texto', 'Retirada grátis no balcão da Praça Sete (agendada)', 'valor', 0));
  if v_gratis then
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('tipo', 'entrega_gratis', 'texto', 'Entrega grátis na região central de BH, em horário comercial', 'valor', 0));
  elsif v_bh then
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('tipo', 'entrega_app', 'texto', 'Entrega por aplicativo (moto ou carro), valor confirmado no WhatsApp', 'valor', null, 'valor_referencia', (p_frete ->> 'valor_frete_cliente')::numeric));
  else
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('tipo', 'envio_brasil', 'texto', 'Envio para todo o Brasil (Correios ou transportadora), frete calculado no checkout', 'valor', null));
  end if;
  return jsonb_build_object('ok', true, 'regiao_central', v_central, 'grande_bh', v_bh, 'frete_gratis', v_gratis,
    'pedido_minimo_frete_gratis', case when v_central then (p_frete ->> 'pedido_minimo')::numeric end,
    'falta_para_frete_gratis', case when v_central and not v_gratis then (p_frete ->> 'falta_para_frete_gratis')::numeric end,
    'opcoes', v_opcoes);
end $$;

-- Data em que fica pronto (+1 dia útil na criação de arte), com a frase do corte das 10h30
create or replace function private.loja_prazo(p_sku text, p_dias_extra integer)
returns jsonb language plpgsql stable set search_path = '' as $$
declare v_lead integer; v_pronto date; pz jsonb;
  dias text[] := array['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado'];
begin
  pz := public.calcular_prazo(p_sku, now(), false);
  if not coalesce((pz ->> 'ok')::boolean, false) then return jsonb_build_object('ok', false); end if;
  select p.lead_days into v_lead from public.products p where p.code = p_sku;
  v_pronto := private.prazo_data(coalesce(v_lead, 0) + coalesce(p_dias_extra, 0), now());
  return jsonb_build_object('ok', true, 'data_pronto', v_pronto,
    'data_pronto_texto', dias[extract(dow from v_pronto)::integer + 1] || ', dia ' || extract(day from v_pronto)::integer,
    'dias_uteis', coalesce(v_lead, 0) + coalesce(p_dias_extra, 0) + (select dias_logistica from public.parametros_comerciais where id = 1),
    'corte', '10h30', 'inicio_contagem', pz -> 'inicio_contagem',
    'frase', format('Pagando e liberando a arte até 10h30 de dia útil, a produção começa no mesmo dia. Fica pronto %s %s.',
                    case when extract(dow from v_pronto) in (0, 6) then 'no' else 'na' end,
                    dias[extract(dow from v_pronto)::integer + 1] || ', dia ' || extract(day from v_pronto)::integer));
end $$;

-- GET /api/v1/products/search
create or replace function public.loja_buscar(p_termo text default null, p_limite integer default 12, p_categoria text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_palavras text[]; v_lim integer := least(greatest(coalesce(p_limite, 12), 1), 48); v_out jsonb; v_total integer;
begin
  v_palavras := array(select left(w, greatest(4, length(w) - 2)) from unnest(string_to_array(private.slugify(left(coalesce(p_termo, ''), 80)), '-')) w where length(w) >= 2);
  with base as (
    select e.* from public.ecommerce_products e
     where e.ativo
       and (p_categoria is null or e.categoria_slug = p_categoria)
       and (cardinality(v_palavras) = 0 or (
         select bool_and(private.slugify(concat_ws(' ', e.titulo, e.categoria, e.cores_rotulo, e.formato_rotulo, e.especificacao)) like '%' || w || '%')
           from unnest(v_palavras) w))
  ), prod as (
    select b.produto_slug,
           min(b.titulo) titulo, min(b.categoria) categoria, min(b.categoria_slug) categoria_slug,
           min(b.cores_rotulo) impressao, min(b.formato_rotulo) formato,
           (array_agg(b.fotos ->> 0) filter (where jsonb_array_length(b.fotos) > 0))[1] foto,
           min(b.preco) a_partir_de, min(b.parcela_2x) parcela_2x_a_partir_de, max(b.prazo_dias_uteis) prazo_dias_uteis,
           jsonb_agg(jsonb_build_object('ref', b.ref, 'quantidade', b.quantidade, 'preco', b.preco, 'parcela_2x', b.parcela_2x) order by b.quantidade, b.preco) opcoes,
           bool_or(cardinality(v_palavras) > 0 and private.slugify(b.titulo) like '%' || v_palavras[1] || '%') no_titulo
      from base b group by b.produto_slug
  )
  select count(*)::integer, coalesce(jsonb_agg(to_jsonb(x) - 'no_titulo' - 'rn') filter (where x.rn <= v_lim), '[]'::jsonb) into v_total, v_out
    from (select p.*, row_number() over (order by p.no_titulo desc, p.a_partir_de) rn from prod p) x;
  return jsonb_build_object('total', v_total, 'produtos', v_out);
end $$;

-- GET /api/v1/products/:ref/quote
create or replace function public.loja_cotar(p_ref text, p_arte text default 'pronta', p_cep text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_sku text := private.loja_sku(p_ref); pc jsonb; a jsonb := private.loja_arte(p_arte); e record; v_total numeric; v_cep text := nullif(regexp_replace(coalesce(p_cep, ''), '\D', '', 'g'), '');
begin
  if v_sku is null then return jsonb_build_object('ok', false, 'erro', 'produto_nao_encontrado'); end if;
  if a is null then return jsonb_build_object('ok', false, 'erro', 'arte_invalida', 'opcoes', jsonb_build_array('pronta', 'conferencia', 'criacao')); end if;
  if v_cep is not null and v_cep !~ '^[0-9]{8}$' then return jsonb_build_object('ok', false, 'erro', 'cep_invalido'); end if;
  pc := public.calcular_preco(v_sku, 1, '{}'::jsonb);
  if not coalesce((pc ->> 'ok')::boolean, false) then return jsonb_build_object('ok', false, 'erro', 'produto_indisponivel'); end if;
  select titulo, quantidade, cores_rotulo, formato_rotulo into e from public.ecommerce_products where ref = p_ref;
  v_total := (pc ->> 'preco_total')::numeric + (a ->> 'valor')::numeric;
  return jsonb_build_object('ok', true, 'ref', p_ref, 'titulo', e.titulo, 'quantidade', e.quantidade, 'impressao', e.cores_rotulo, 'formato', e.formato_rotulo,
    'preco', (pc ->> 'preco_total')::numeric,
    'arte', jsonb_build_object('tipo', a ->> 'arte', 'texto', a ->> 'texto', 'valor', (a ->> 'valor')::numeric),
    'total', v_total,
    'pagamento', jsonb_build_object('pix', v_total, 'parcelas_sem_juros', 2, 'parcela_sem_juros', round(v_total / 2, 2),
      'texto', 'Pix na hora ou até 2x de ' || private.brl(round(v_total / 2, 2)) || ' sem juros no cartão. De 3x a 12x com juros do Mercado Pago.'),
    'prazo', private.loja_prazo(v_sku, (a ->> 'dias_extra')::integer),
    'frete', case when v_cep is not null then private.loja_frete_publico(
      public.verificar_frete(v_cep, jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', 1)), (pc ->> 'preco_total')::numeric, false), v_cep) end);
end $$;

-- POST /api/v1/quotes/calculate
create or replace function public.loja_calcular(p_itens jsonb, p_arte text default 'pronta', p_cep text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a jsonb := private.loja_arte(p_arte); it jsonb; v_sku text; v_lotes integer; pc jsonb; pz jsonb;
  v_sub numeric := 0; v_itens jsonb := '[]'::jsonb; v_frete_itens jsonb := '[]'::jsonb; v_pronto date; v_prazo jsonb; v_total numeric;
  v_cep text := nullif(regexp_replace(coalesce(p_cep, ''), '\D', '', 'g'), ''); e record;
begin
  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) not between 1 and 10 then return jsonb_build_object('ok', false, 'erro', 'itens_invalidos'); end if;
  if a is null then return jsonb_build_object('ok', false, 'erro', 'arte_invalida'); end if;
  if v_cep is not null and v_cep !~ '^[0-9]{8}$' then return jsonb_build_object('ok', false, 'erro', 'cep_invalido'); end if;
  for it in select * from jsonb_array_elements(p_itens) loop
    v_sku := private.loja_sku(it ->> 'ref');
    if v_sku is null then return jsonb_build_object('ok', false, 'erro', 'produto_nao_encontrado', 'ref', it ->> 'ref'); end if;
    v_lotes := least(greatest(coalesce(nullif(it ->> 'quantidade', '')::integer, 1), 1), 100);
    pc := public.calcular_preco(v_sku, v_lotes, '{}'::jsonb);
    if not coalesce((pc ->> 'ok')::boolean, false) then return jsonb_build_object('ok', false, 'erro', 'produto_indisponivel', 'ref', it ->> 'ref'); end if;
    select titulo, quantidade into e from public.ecommerce_products where ref = it ->> 'ref';
    v_sub := v_sub + (pc ->> 'preco_total')::numeric;
    v_itens := v_itens || jsonb_build_array(jsonb_build_object('ref', it ->> 'ref', 'titulo', e.titulo, 'lotes', v_lotes,
      'unidades', coalesce(e.quantidade, 1) * v_lotes, 'preco', (pc ->> 'preco_total')::numeric));
    v_frete_itens := v_frete_itens || jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', v_lotes));
    pz := private.loja_prazo(v_sku, (a ->> 'dias_extra')::integer);
    if coalesce((pz ->> 'ok')::boolean, false) and (v_pronto is null or (pz ->> 'data_pronto')::date > v_pronto) then v_pronto := (pz ->> 'data_pronto')::date; v_prazo := pz; end if;
  end loop;
  v_total := v_sub + (a ->> 'valor')::numeric;
  return jsonb_build_object('ok', true, 'itens', v_itens, 'subtotal', v_sub,
    'arte', jsonb_build_object('tipo', a ->> 'arte', 'texto', a ->> 'texto', 'valor', (a ->> 'valor')::numeric),
    'total', v_total,
    'pagamento', jsonb_build_object('pix', v_total, 'parcelas_sem_juros', 2, 'parcela_sem_juros', round(v_total / 2, 2)),
    'prazo', v_prazo,
    'frete', case when v_cep is not null then private.loja_frete_publico(public.verificar_frete(v_cep, v_frete_itens, v_sub, false), v_cep) end);
end $$;

revoke all on function public.loja_buscar(text, integer, text) from public;
revoke all on function public.loja_cotar(text, text, text) from public;
revoke all on function public.loja_calcular(jsonb, text, text) from public;
grant execute on function public.loja_buscar(text, integer, text) to anon, authenticated, service_role;
grant execute on function public.loja_cotar(text, text, text) to anon, authenticated, service_role;
grant execute on function public.loja_calcular(jsonb, text, text) to anon, authenticated, service_role;

-- POST /api/v1/checkout/create-preference (via Edge Function loja-checkout, só service role)
create or replace function public.loja_checkout_preparar(p_cliente jsonb, p_itens jsonb, p_opcoes jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_wa text := regexp_replace(coalesce(p_cliente ->> 'whatsapp', ''), '\D', '', 'g');
  v_doc text := nullif(regexp_replace(coalesce(p_cliente ->> 'documento', ''), '\D', '', 'g'), '');
  v_cep text := nullif(regexp_replace(coalesce(p_opcoes ->> 'cep', ''), '\D', '', 'g'), '');
  v_entrega text := coalesce(nullif(p_opcoes ->> 'entrega', ''), 'retirada');
  a jsonb := private.loja_arte(p_opcoes ->> 'arte');
  v_teste boolean := coalesce((p_opcoes ->> 'teste')::boolean, false);
  v_contact uuid; v_itens jsonb := '[]'::jsonb; it jsonb; v_sku text; r jsonb; v jsonb; v_orc uuid; v_order uuid; v_num bigint; v_total numeric;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  if length(v_wa) in (10, 11) then v_wa := '55' || v_wa; end if;
  if v_wa !~ '^55[1-9][0-9]9?[0-9]{8}$' then return jsonb_build_object('ok', false, 'erro', 'whatsapp_invalido'); end if;
  if length(coalesce(btrim(p_cliente ->> 'nome'), '')) < 3 then return jsonb_build_object('ok', false, 'erro', 'nome_obrigatorio'); end if;
  if a is null then return jsonb_build_object('ok', false, 'erro', 'arte_invalida'); end if;
  if v_entrega not in ('retirada', 'entrega') then return jsonb_build_object('ok', false, 'erro', 'entrega_invalida'); end if;
  if v_entrega = 'entrega' and (v_cep is null or v_cep !~ '^[0-9]{8}$') then return jsonb_build_object('ok', false, 'erro', 'cep_obrigatorio_para_entrega'); end if;

  -- limites: 3 checkouts por WhatsApp em 10 minutos e 30 por hora no site inteiro
  if (select count(*) from public.orders o join public.contacts c on c.id = o.contact_id
       where c.wa_id = v_wa and o.origin_label = 'site' and o.created_at > now() - interval '10 minutes') >= 3
     or (select count(*) from public.orders o where o.origin_label = 'site' and o.created_at > now() - interval '1 hour') >= 30 then
    return jsonb_build_object('ok', false, 'erro', 'muitas_tentativas');
  end if;

  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) not between 1 and 10 then return jsonb_build_object('ok', false, 'erro', 'itens_invalidos'); end if;
  for it in select * from jsonb_array_elements(p_itens) loop
    v_sku := private.loja_sku(it ->> 'ref');
    if v_sku is null then return jsonb_build_object('ok', false, 'erro', 'produto_nao_encontrado', 'ref', it ->> 'ref'); end if;
    v_itens := v_itens || jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', least(greatest(coalesce(nullif(it ->> 'quantidade', '')::integer, 1), 1), 100)));
  end loop;

  -- contato: cria pelo WhatsApp ou completa só o que falta (nunca sobrescreve o cadastro)
  insert into public.contacts as c (wa_id, name, email, document, cep, is_teste)
  values (v_wa, left(btrim(p_cliente ->> 'nome'), 120), nullif(lower(btrim(coalesce(p_cliente ->> 'email', ''))), ''), v_doc, v_cep, v_teste)
  on conflict (wa_id) do update set
    name = coalesce(c.name, excluded.name), email = coalesce(c.email, excluded.email),
    document = coalesce(c.document, excluded.document), cep = coalesce(c.cep, excluded.cep)
  returning id into v_contact;

  r := public.montar_orcamento(v_contact, v_itens, jsonb_build_object('arte', a ->> 'modo_orcamento', 'teste', v_teste,
         'cep', case when v_entrega = 'entrega' then v_cep end));
  if r ->> 'status' <> 'ok' then return jsonb_build_object('ok', false, 'erro', 'orcamento_bloqueado', 'motivo', r ->> 'motivo'); end if;
  v_orc := (r ->> 'orcamento_id')::uuid;
  if a ->> 'arte' = 'conferencia' then
    update public.orcamentos set arte_valor = (a ->> 'valor')::numeric where id = v_orc;
  end if;
  v := public.validar_margem(v_orc);
  if v ->> 'status' <> 'ok' then return jsonb_build_object('ok', false, 'erro', 'orcamento_bloqueado', 'motivo', v ->> 'motivo'); end if;

  v_order := private.orcamento_para_pedido(v_orc);
  update public.orders set origin_label = 'site', title = 'Site ' || private.orcamento_numero((select numero from public.orcamentos where id = v_orc)),
         notes = concat_ws(E'\n', notes, 'Pedido feito no site. Arte: ' || (a ->> 'texto') || '. Entrega: ' || case when v_entrega = 'entrega' then 'entrega no CEP ' || v_cep else 'retirada no balcão' end || '.')
   where id = v_order returning number into v_num;
  if a ->> 'arte' = 'conferencia' then
    update public.order_items set description = 'Conferência e ajuste técnico do arquivo'
     where order_id = v_order and fora_catalogo and description = 'Criação de arte';
  end if;
  select total into v_total from public.order_financials where order_id = v_order;
  return jsonb_build_object('ok', true, 'pedido_id', v_order, 'numero', v_num, 'orcamento', r ->> 'numero', 'total', v_total,
    'prazo', r ->> 'prazo', 'data_prevista', r ->> 'data_prevista');
end $$;
revoke all on function public.loja_checkout_preparar(jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.loja_checkout_preparar(jsonb, jsonb, jsonb) to service_role;
