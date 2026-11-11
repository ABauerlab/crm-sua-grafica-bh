-- Fase 16: canal de E-commerce, listagem por produto/SKU e ficha técnica explícita.
-- Aditiva e idempotente. Preserva o rótulo legado 'site' para pedidos já criados.

-- orders_canal_chk não aceitava 'ecommerce': sem isto, todo checkout do site falharia na gravação do pedido.
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_canal_chk;
ALTER TABLE public.orders ADD CONSTRAINT orders_canal_chk CHECK (canal = ANY (ARRAY['whatsapp'::text, 'site'::text, 'ecommerce'::text, 'balcao'::text, 'mercado_livre'::text, 'shopee'::text, 'tiktok'::text, 'amazon'::text, 'magalu'::text, 'facebook'::text]));

CREATE OR REPLACE FUNCTION private.orders_canal_site()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.origin_label = 'ecommerce' then
    new.canal := 'ecommerce';
  elsif new.origin_label = 'site' and new.canal = 'whatsapp' then
    new.canal := 'site';
  end if;
  return new;
end $function$;


CREATE OR REPLACE FUNCTION public.loja_checkout_preparar(p_cliente jsonb, p_itens jsonb, p_opcoes jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  pr public.parametros_comerciais%rowtype;
  v_wa text := regexp_replace(coalesce(p_cliente ->> 'whatsapp', ''), '\D', '', 'g');
  v_doc text := nullif(regexp_replace(coalesce(p_cliente ->> 'documento', ''), '\D', '', 'g'), '');
  v_cep text := nullif(regexp_replace(coalesce(p_opcoes ->> 'cep', ''), '\D', '', 'g'), '');
  v_entrega text := coalesce(nullif(p_opcoes ->> 'entrega', ''), 'retirada');
  a jsonb := private.loja_arte(p_opcoes ->> 'arte');
  v_teste boolean := coalesce((p_opcoes ->> 'teste')::boolean, false);
  v_contact uuid; v_itens jsonb := '[]'::jsonb; v_calc jsonb; it jsonb; v_sku text; r jsonb; v jsonb; v_orc uuid; v_order uuid; v_num bigint; v_total numeric;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  if length(v_wa) in (10, 11) then v_wa := '55' || v_wa; end if;
  if v_wa !~ '^55[1-9][0-9]9?[0-9]{8}$' then return jsonb_build_object('ok', false, 'erro', 'whatsapp_invalido'); end if;
  if length(coalesce(btrim(p_cliente ->> 'nome'), '')) < 3 then return jsonb_build_object('ok', false, 'erro', 'nome_obrigatorio'); end if;
  if a is null then return jsonb_build_object('ok', false, 'erro', 'arte_invalida'); end if;
  if v_entrega not in ('retirada', 'entrega') then return jsonb_build_object('ok', false, 'erro', 'entrega_invalida'); end if;
  if v_entrega = 'entrega' and (v_cep is null or v_cep !~ '^[0-9]{8}$') then return jsonb_build_object('ok', false, 'erro', 'cep_obrigatorio_para_entrega'); end if;

  if (select count(*) from public.orders o join public.contacts c on c.id = o.contact_id
       where c.wa_id = v_wa and o.origin_label in ('site', 'ecommerce') and o.created_at > now() - interval '10 minutes') >= 3
     or (select count(*) from public.orders o where o.origin_label in ('site', 'ecommerce') and o.created_at > now() - interval '1 hour') >= 30 then
    return jsonb_build_object('ok', false, 'erro', 'muitas_tentativas');
  end if;

  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) not between 1 and 10 then return jsonb_build_object('ok', false, 'erro', 'itens_invalidos'); end if;
  for it in select * from jsonb_array_elements(p_itens) loop
    v_sku := private.loja_sku(it ->> 'ref');
    if v_sku is null then return jsonb_build_object('ok', false, 'erro', 'produto_nao_encontrado', 'ref', it ->> 'ref'); end if;
    v_itens := v_itens || jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', least(greatest(coalesce(nullif(it ->> 'quantidade', '')::integer, 1), 1), 100)));
  end loop;

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
  update public.orders set origin_label = 'ecommerce', canal = 'ecommerce', title = 'E-commerce ' || private.orcamento_numero((select numero from public.orcamentos where id = v_orc)),
         notes = concat_ws(E'\n', notes, 'Pedido feito no site. Arte: ' || (a ->> 'texto') || '. Entrega: ' || case when v_entrega = 'entrega' then 'entrega no CEP ' || v_cep else 'retirada no balcão' end || '.')
   where id = v_order returning number into v_num;
  if a ->> 'arte' = 'conferencia' then
    update public.order_items set description = 'Conferência e ajuste técnico do arquivo'
     where order_id = v_order and fora_catalogo and description = 'Criação de arte';
  end if;
  select total into v_total from public.order_financials where order_id = v_order;
  v_calc := public.loja_calcular(p_itens, a ->> 'arte', case when v_entrega = 'entrega' then v_cep end);
  return jsonb_build_object('ok', true, 'pedido_id', v_order, 'numero', v_num, 'orcamento', r ->> 'numero', 'total', v_total,
    'prazo', coalesce(v_calc #>> '{prazo,frase}', r ->> 'prazo'), 'data_prevista', coalesce(v_calc #>> '{prazo,data_pronto}', r ->> 'data_prevista'));
end $function$;


CREATE OR REPLACE FUNCTION public.loja_pedido_status(p_pedido uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select jsonb_build_object('ok', true, 'numero', o.number, 'pago', o.payment_status = 'aprovado')
                     from public.orders o where o.id = p_pedido and o.origin_label in ('site', 'ecommerce')),
                  jsonb_build_object('ok', false));
$function$;


CREATE OR REPLACE FUNCTION public.validar_antes_de_cobrar(p_order uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_pay text; v_total numeric; v_orc uuid; v_val jsonb;
begin
  select payment_status into v_pay from public.orders where id = p_order;
  if not found then return 'Pedido não encontrado.'; end if;
  if v_pay = 'aprovado' then return 'Este pedido já está pago.'; end if;
  select total into v_total from public.order_financials where order_id = p_order;
  if coalesce(v_total, 0) <= 0 then return 'O pedido precisa ter itens e valor maior que zero para gerar o link.'; end if;
  -- Pedido do site com arte própria (pronta ou conferência): só cobra depois que o PDF foi anexado
  if exists (select 1 from public.orders o where o.id = p_order and o.origin_label in ('site', 'ecommerce') and o.art_status = 'aguardando')
     and not exists (select 1 from public.order_files f where f.order_id = p_order and f.kind = 'arte')
     and not exists (select 1 from public.order_items i where i.order_id = p_order and i.description = 'Criação de arte') then
    return 'Anexe o PDF da arte em alta qualidade para continuar.';
  end if;
  select o.id into v_orc from public.orcamentos o where o.order_id = p_order and o.status in ('rascunho', 'enviado', 'aceito') order by o.criado_em desc limit 1;
  if v_orc is not null then
    v_val := public.validar_margem(v_orc);
    if v_val ->> 'status' <> 'ok' then return 'Orçamento recusado pela trava de lucro (' || coalesce(v_val ->> 'motivo', 'prejuízo') || ').'; end if;
  end if;
  return null;
end;
$function$;


CREATE OR REPLACE FUNCTION public.loja_modelos_f(p_categorias text[] DEFAULT NULL::text[], p_termo text DEFAULT NULL::text, p_filtros jsonb DEFAULT '{}'::jsonb, p_ordem text DEFAULT 'relevancia'::text, p_limite integer DEFAULT 24, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_palavras text[]; v_lim integer := least(greatest(coalesce(p_limite, 24), 1), 2000); v_off integer := greatest(coalesce(p_offset, 0), 0); v_out jsonb; v_total integer;
  v_sub text := nullif(p_filtros ->> 'sub', '');
  v_tipo text[] := case when p_filtros ? 'tipo' then array(select jsonb_array_elements_text(p_filtros -> 'tipo')) end;
  v_mat text[] := case when p_filtros ? 'material' then array(select jsonb_array_elements_text(p_filtros -> 'material')) end;
  v_gram text[] := case when p_filtros ? 'gram' then array(select jsonb_array_elements_text(p_filtros -> 'gram')) end;
  v_for text[] := case when p_filtros ? 'formato' then array(select jsonb_array_elements_text(p_filtros -> 'formato')) end;
  v_pra text[] := case when p_filtros ? 'prazo' then array(select jsonb_array_elements_text(p_filtros -> 'prazo')) end;
  v_pre text[] := case when p_filtros ? 'preco' then array(select jsonb_array_elements_text(p_filtros -> 'preco')) end;
  v_acab text[] := case when p_filtros ? 'acab' then array(select jsonb_array_elements_text(p_filtros -> 'acab')) end;
begin
  v_palavras := private.loja_palavras_busca(p_termo);
  with base as (
    select a.*, f.familia, f.titulo_card, f.tamanho, f.tags from private.loja_atributos a join private.loja_familias f on f.sku = a.sku
     where (p_categorias is null or a.categoria_slug = any(p_categorias))
       and (cardinality(v_palavras) = 0 or a.busca like all (array(select '%' || w || '%' from unnest(v_palavras) w)))
       and (v_sub is null or a.sub = v_sub) and (v_tipo is null or a.tipo = any(v_tipo)) and (v_mat is null or a.material = any(v_mat)) and (v_gram is null or a.gram = any(v_gram)) and (v_for is null or a.formato = any(v_for)) and (v_pra is null or a.prazo = any(v_pra)) and (v_pre is null or a.preco_faixa = any(v_pre)) and (v_acab is null or a.acab && v_acab)
  ), m as (
    select b.produto_slug, b.categoria_slug, min(b.titulo) titulo, min(e.categoria) categoria,
           (array_agg(b.fotos ->> 0 order by b.preco) filter (where jsonb_array_length(b.fotos) > 0))[1] foto,
           min(b.preco) a_partir_de, (array_agg(b.parcela_2x order by b.preco))[1] parcela_2x_a_partir_de,
           (array_agg(b.sku order by b.preco, b.quantidade))[1] sku, (array_agg(b.ref order by b.preco, b.quantidade))[1] ref,
           (array_agg(b.quantidade order by b.preco, b.quantidade))[1] quantidade,
           count(distinct b.tamanho)::integer tamanhos, count(distinct b.sku)::integer variacoes,
           min(b.sub_nome) subcategoria, min(b.sub) sub, min(b.prazo_dias_uteis) prazo_dias_uteis,
           (array_agg(to_jsonb(b.acab) order by b.preco))[1] acab, (array_agg(to_jsonb(b.tags) order by b.preco))[1] tags,
           coalesce(min(ss.ordem), 9999) sub_ordem
      from base b join public.ecommerce_products e on e.sku = b.sku
      left join public.loja_subcategorias ss on ss.categoria_slug = b.categoria_slug and ss.slug = b.sub group by b.produto_slug, b.categoria_slug
  ), ord as (
    select m.*, row_number() over (order by
        case when p_ordem = 'menor_preco' then m.a_partir_de end asc,
        case when p_ordem = 'maior_preco' then m.a_partir_de end desc,
        m.categoria_slug, m.sub_ordem, regexp_replace(m.titulo, '\d+', '', 'g'), coalesce(nullif(substring(m.titulo from '(\d+) ?g'), '')::integer, 0), m.titulo, m.a_partir_de) rn from m
  )
  select (select count(*)::integer from m),
         coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'sub_ordem' order by o.rn) filter (where o.rn > v_off and o.rn <= v_off + v_lim), '[]'::jsonb)
    into v_total, v_out from ord o;
  return jsonb_build_object('total', v_total, 'modelos', v_out);
end $function$;


CREATE OR REPLACE FUNCTION public.loja_arvore()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with c as (
    select e.categoria_slug slug, min(e.categoria) nome, count(distinct e.produto_slug)::integer produtos, count(distinct e.produto_slug)::integer modelos, min(e.preco) a_partir_de,
           (array_agg(e.fotos ->> 0 order by e.preco) filter (where jsonb_array_length(e.fotos) > 0))[1] foto
      from public.ecommerce_products e join private.loja_familias f on f.sku = e.sku where e.ativo group by e.categoria_slug
  ), s as (
    select a.categoria_slug, a.sub slug, min(a.sub_nome) nome, count(distinct a.produto_slug)::integer modelos, min(ss.ordem) ordem,
           (array_agg(a.fotos ->> 0 order by a.preco) filter (where jsonb_array_length(a.fotos) > 0))[1] foto
      from private.loja_atributos a join private.loja_familias f on f.sku = a.sku join public.loja_subcategorias ss on ss.categoria_slug = a.categoria_slug and ss.slug = a.sub
     where a.sub is not null group by a.categoria_slug, a.sub
  )
  select jsonb_build_object('verticais', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'nome', v.nome, 'descricao', v.descricao,
      'modelos', (select coalesce(sum(c.modelos), 0)::integer from public.loja_taxonomia t join c on c.slug = t.categoria_slug where t.vertical_id = v.id),
      'categorias', coalesce((select jsonb_agg(jsonb_build_object('slug', c.slug, 'nome', c.nome, 'produtos', c.produtos, 'modelos', c.modelos, 'a_partir_de', c.a_partir_de, 'foto', c.foto,
          'subcategorias', coalesce((select jsonb_agg(jsonb_build_object('slug', s.slug, 'nome', s.nome, 'modelos', s.modelos, 'foto', s.foto) order by s.ordem) from s where s.categoria_slug = c.slug), '[]'::jsonb)) order by t.ordem)
          from public.loja_taxonomia t join c on c.slug = t.categoria_slug where t.vertical_id = v.id), '[]'::jsonb)) order by v.ordem) from public.loja_verticais v), '[]'::jsonb));
$function$;


CREATE OR REPLACE FUNCTION public.loja_facetas(p_categorias text[] DEFAULT NULL::text[], p_termo text DEFAULT NULL::text, p_filtros jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_palavras text[]; v_out jsonb; v_total integer;
  v_sub text := nullif(p_filtros ->> 'sub', '');
  v_tipo text[] := case when p_filtros ? 'tipo' then array(select jsonb_array_elements_text(p_filtros -> 'tipo')) end;
  v_mat text[] := case when p_filtros ? 'material' then array(select jsonb_array_elements_text(p_filtros -> 'material')) end;
  v_gram text[] := case when p_filtros ? 'gram' then array(select jsonb_array_elements_text(p_filtros -> 'gram')) end;
  v_for text[] := case when p_filtros ? 'formato' then array(select jsonb_array_elements_text(p_filtros -> 'formato')) end;
  v_pra text[] := case when p_filtros ? 'prazo' then array(select jsonb_array_elements_text(p_filtros -> 'prazo')) end;
  v_pre text[] := case when p_filtros ? 'preco' then array(select jsonb_array_elements_text(p_filtros -> 'preco')) end;
  v_acab text[] := case when p_filtros ? 'acab' then array(select jsonb_array_elements_text(p_filtros -> 'acab')) end;
begin
  v_palavras := private.loja_palavras_busca(p_termo);
  with tb as materialized (
    select a.sub, a.sub_nome, a.tipo, a.material, a.gram, a.formato, a.prazo, a.preco_faixa pf, a.acab, a.produto_slug
      from private.loja_atributos a join private.loja_familias f on f.sku = a.sku
     where (p_categorias is null or a.categoria_slug = any(p_categorias))
       and (cardinality(v_palavras) = 0 or a.busca like all (array(select '%' || w || '%' from unnest(v_palavras) w)))
  ), f as (
    select 'sub' faceta, t.sub valor, min(t.sub_nome) rotulo, count(distinct t.produto_slug) n from tb t where t.sub is not null and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.sub
    union all select 'tipo', t.tipo, null, count(distinct t.produto_slug) from tb t where t.tipo is not null and (v_sub is null or t.sub = v_sub) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.tipo
    union all select 'material', t.material, null, count(distinct t.produto_slug) from tb t where t.material is not null and (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.material
    union all select 'gram', t.gram, null, count(distinct t.produto_slug) from tb t where t.gram is not null and (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.gram
    union all select 'acab', z, null, count(distinct t.produto_slug) from tb t, unnest(t.acab) z where (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) group by z
    union all select 'formato', t.formato, null, count(distinct t.produto_slug) from tb t where (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.formato
    union all select 'prazo', t.prazo, null, count(distinct t.produto_slug) from tb t where (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.prazo
    union all select 'preco', t.pf, null, count(distinct t.produto_slug) from tb t where (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_acab is null or t.acab && v_acab) group by t.pf
  ), g as (
    select f.faceta, jsonb_agg(jsonb_build_object('valor', f.valor, 'rotulo', coalesce(f.rotulo, d.rotulo, f.valor), 'n', f.n)
             order by coalesce(d.ordem, 0), f.n desc, f.valor) itens
      from f left join public.loja_facetas_def d on d.faceta = f.faceta and d.valor = f.valor
     where f.n > 0 group by f.faceta)
  select coalesce(jsonb_object_agg(g.faceta, g.itens), '{}'::jsonb), (select count(distinct t.produto_slug)::integer from tb t where (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab))
    into v_out, v_total from g;
  return jsonb_build_object('total', v_total, 'facetas', v_out);
end $function$;


CREATE OR REPLACE FUNCTION public.loja_produto(p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; v_cat text; v_formato text; v_impressao text; v_titulo text;
begin
  select jsonb_build_object(
      'produto_slug', p_slug, 'titulo', min(e.titulo), 'categoria', min(e.categoria), 'categoria_slug', min(e.categoria_slug),
      'impressao', min(e.cores_rotulo), 'formato', min(e.formato_rotulo), 'especificacao', min(e.especificacao),
      'descricao', min(e.descricao),
      'ficha', coalesce((array_agg(e.ficha) filter (where e.ficha <> '{}'::jsonb))[1], '{}'::jsonb)
        || jsonb_strip_nulls(jsonb_build_object(
          'material_catalogo', (select a.material from private.loja_atributos a where a.produto_slug = p_slug order by a.preco, a.quantidade limit 1),
          'gramatura_g', (select c.gramatura_g from public.ecommerce_products e2 join public.catalogo c on c.sku = e2.sku where e2.produto_slug = p_slug and e2.ativo and c.gramatura_g is not null order by e2.preco, e2.quantidade limit 1),
          'codigo_cores', (select c.cores from public.ecommerce_products e2 join public.catalogo c on c.sku = e2.sku where e2.produto_slug = p_slug and e2.ativo and c.cores is not null order by e2.preco, e2.quantidade limit 1),
          'acabamentos_catalogo', (select to_jsonb(array_agg(distinct lower(x.acab))) from public.ecommerce_products e2 join private.loja_atributos a on a.sku = e2.sku cross join lateral unnest(a.acab) as x(acab) where e2.produto_slug = p_slug)
        )),
      'acabamentos', (array_agg(e.acabamentos) filter (where jsonb_array_length(e.acabamentos) > 0))[1],
      'fotos', coalesce((array_agg(e.fotos) filter (where jsonb_array_length(e.fotos) > 0))[1], '[]'::jsonb),
      'prazo_dias_uteis', max(e.prazo_dias_uteis), 'a_partir_de', min(e.preco), 'ate', max(e.preco),
      'sku', (array_agg(e.sku order by e.preco, e.quantidade))[1],
      'opcoes', jsonb_agg(jsonb_build_object('ref', e.ref, 'sku', e.sku, 'quantidade', e.quantidade, 'preco', e.preco, 'parcela_2x', e.parcela_2x, 'prazo_dias_uteis', e.prazo_dias_uteis,
                                             'peso_kg', e.peso_kg) order by e.quantidade, e.preco),
      'atualizado_em', max(e.atualizado_em)),
    min(e.categoria_slug), min(e.formato_rotulo), min(e.cores_rotulo), min(e.titulo)
    into v, v_cat, v_formato, v_impressao, v_titulo
    from public.ecommerce_products e where e.ativo and e.produto_slug = p_slug;
  if v_cat is null then return null; end if;
  return v || jsonb_build_object(
    'irmaos', coalesce((
      select jsonb_agg(x order by x.formato, x.impressao) from (
        select e.produto_slug, min(e.cores_rotulo) impressao, min(e.formato_rotulo) formato, min(e.preco) a_partir_de
          from public.ecommerce_products e
         where e.ativo and e.categoria_slug = v_cat and e.titulo = v_titulo
         group by e.produto_slug limit 24) x), '[]'::jsonb),
    'variacoes', coalesce((
      select jsonb_agg(x order by x.ordem, x.a_partir_de) from (
        select e.produto_slug, min(e.titulo) titulo, min(e.cores_rotulo) impressao, min(e.formato_rotulo) formato, min(e.preco) a_partir_de,
               (array_agg(e.fotos ->> 0) filter (where jsonb_array_length(e.fotos) > 0))[1] foto,
               (case when min(e.formato_rotulo) = v_formato then 0 else 2 end) + (case when min(e.cores_rotulo) = v_impressao then 0 else 1 end) ordem
          from public.ecommerce_products e
         where e.ativo and e.categoria_slug = v_cat and e.titulo <> v_titulo
         group by e.produto_slug
         order by 7, 5 limit 12) x), '[]'::jsonb));
end $function$;


select private.loja_facetas_cache_atualizar();
