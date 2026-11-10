-- Filtros: {"sub":"slug","tipo":["liso"],"material":[...],"gram":[...],"acab":[...],"formato":[...],"prazo":[...],"preco":[...]}; OR dentro da faceta, E entre facetas
create or replace function private.loja_passa(a private.loja_atributos, f jsonb, skip text default null)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(f, '{}'::jsonb) = '{}'::jsonb or (
    (skip = 'sub' or f ->> 'sub' is null or a.sub = f ->> 'sub')
    and (skip = 'tipo' or f -> 'tipo' is null or f -> 'tipo' ? a.tipo)
    and (skip = 'material' or f -> 'material' is null or f -> 'material' ? a.material)
    and (skip = 'gram' or f -> 'gram' is null or f -> 'gram' ? a.gram)
    and (skip = 'formato' or f -> 'formato' is null or f -> 'formato' ? a.formato)
    and (skip = 'prazo' or f -> 'prazo' is null or f -> 'prazo' ? a.prazo)
    and (skip = 'preco' or f -> 'preco' is null or f -> 'preco' ? a.preco_faixa)
    and (skip = 'acab' or f -> 'acab' is null or exists (select 1 from jsonb_array_elements_text(f -> 'acab') z where z = any (a.acab))));
$$;

create or replace function public.loja_facetas(p_categorias text[] default null, p_termo text default null, p_filtros jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_palavras text[]; v_out jsonb; v_total integer;
begin
  v_palavras := private.loja_palavras_busca(p_termo);
  with tt_base as materialized (
    select a.* from private.loja_atributos a
     where (p_categorias is null or a.categoria_slug = any(p_categorias))
       and (cardinality(v_palavras) = 0 or a.busca like all (array(select '%' || w || '%' from unnest(v_palavras) w)))
  ), f as (
    select 'sub' faceta, a.sub valor, min(a.sub_nome) rotulo, count(distinct a.modelo) n from tt_base a where private.loja_passa(a, p_filtros, 'sub') and a.sub is not null group by a.sub
    union all select 'tipo', a.tipo, null, count(distinct a.modelo) from tt_base a where private.loja_passa(a, p_filtros, 'tipo') and a.tipo is not null group by a.tipo
    union all select 'material', a.material, null, count(distinct a.modelo) from tt_base a where private.loja_passa(a, p_filtros, 'material') and a.material is not null group by a.material
    union all select 'gram', a.gram, null, count(distinct a.modelo) from tt_base a where private.loja_passa(a, p_filtros, 'gram') and a.gram is not null group by a.gram
    union all select 'acab', z, null, count(distinct a.modelo) from tt_base a, unnest(a.acab) z where private.loja_passa(a, p_filtros, 'acab') group by z
    union all select 'formato', a.formato, null, count(distinct a.modelo) from tt_base a where private.loja_passa(a, p_filtros, 'formato') group by a.formato
    union all select 'prazo', a.prazo, null, count(distinct a.modelo) from tt_base a where private.loja_passa(a, p_filtros, 'prazo') group by a.prazo
    union all select 'preco', a.preco_faixa, null, count(distinct a.modelo) from tt_base a where private.loja_passa(a, p_filtros, 'preco') group by a.preco_faixa
  ), g as (
    select f.faceta, jsonb_agg(jsonb_build_object('valor', f.valor, 'rotulo', coalesce(f.rotulo, d.rotulo, f.valor), 'n', f.n)
             order by coalesce(d.ordem, 0), f.n desc, f.valor) itens
      from f left join public.loja_facetas_def d on d.faceta = f.faceta and d.valor = f.valor
     where f.n > 0 group by f.faceta)
  select coalesce(jsonb_object_agg(g.faceta, g.itens), '{}'::jsonb), (select count(distinct a.modelo)::integer from tt_base a where private.loja_passa(a, p_filtros)) into v_out, v_total from g;
  return jsonb_build_object('total', v_total, 'facetas', v_out);
end $$;

create or replace function public.loja_modelos_f(p_categorias text[] default null, p_termo text default null, p_filtros jsonb default '{}'::jsonb,
                                                 p_ordem text default 'relevancia', p_limite integer default 24, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_palavras text[]; v_lim integer := least(greatest(coalesce(p_limite, 24), 1), 48); v_off integer := greatest(coalesce(p_offset, 0), 0); v_out jsonb; v_total integer;
begin
  v_palavras := private.loja_palavras_busca(p_termo);
  with base as (
    select a.* from private.loja_atributos a
     where (p_categorias is null or a.categoria_slug = any(p_categorias))
       and (cardinality(v_palavras) = 0 or a.busca like all (array(select '%' || w || '%' from unnest(v_palavras) w)))
       and private.loja_passa(a, p_filtros)
  ), m as (
    select b.titulo, b.categoria_slug, min(e.categoria) categoria,
           (array_agg(b.produto_slug order by b.preco, b.quantidade))[1] produto_slug,
           (array_agg(b.fotos ->> 0 order by b.preco) filter (where jsonb_array_length(b.fotos) > 0))[1] foto,
           min(b.preco) a_partir_de, (array_agg(b.parcela_2x order by b.preco))[1] parcela_2x_a_partir_de,
           (array_agg(b.sku order by b.preco, b.quantidade))[1] sku, (array_agg(b.ref order by b.preco, b.quantidade))[1] ref,
           (array_agg(b.quantidade order by b.preco, b.quantidade))[1] quantidade, count(distinct b.produto_slug)::integer variacoes,
           min(b.sub_nome) subcategoria, min(b.prazo_dias_uteis) prazo_dias_uteis, (array_agg(b.acab order by b.preco))[1] acab
      from base b join public.ecommerce_products e on e.sku = b.sku group by b.titulo, b.categoria_slug
  ), ord as (
    select m.*, row_number() over (order by
        case when p_ordem = 'menor_preco' then m.a_partir_de end asc,
        case when p_ordem = 'maior_preco' then m.a_partir_de end desc,
        (m.foto is null), m.categoria_slug, m.titulo) rn from m
  )
  select (select count(*)::integer from m),
         coalesce(jsonb_agg(to_jsonb(o) - 'rn' order by o.rn) filter (where o.rn > v_off and o.rn <= v_off + v_lim), '[]'::jsonb)
    into v_total, v_out from ord o;
  return jsonb_build_object('total', v_total, 'modelos', v_out);
end $$;

create or replace function public.loja_arvore()
returns jsonb language sql stable security definer set search_path = '' as $$
  with c as (
    select e.categoria_slug slug, min(e.categoria) nome, count(distinct e.produto_slug)::integer produtos, count(distinct e.titulo)::integer modelos, min(e.preco) a_partir_de,
           (array_agg(e.fotos ->> 0 order by e.preco) filter (where jsonb_array_length(e.fotos) > 0))[1] foto
      from public.ecommerce_products e where e.ativo group by e.categoria_slug
  ), s as (
    select a.categoria_slug, a.sub slug, min(a.sub_nome) nome, count(distinct a.modelo)::integer modelos, min(ss.ordem) ordem
      from private.loja_atributos a join public.loja_subcategorias ss on ss.categoria_slug = a.categoria_slug and ss.slug = a.sub
     where a.sub is not null group by a.categoria_slug, a.sub
  )
  select jsonb_build_object('verticais', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'nome', v.nome, 'descricao', v.descricao,
      'modelos', (select coalesce(sum(c.modelos), 0)::integer from public.loja_taxonomia t join c on c.slug = t.categoria_slug where t.vertical_id = v.id),
      'categorias', coalesce((select jsonb_agg(jsonb_build_object('slug', c.slug, 'nome', c.nome, 'produtos', c.produtos, 'modelos', c.modelos, 'a_partir_de', c.a_partir_de, 'foto', c.foto,
          'subcategorias', coalesce((select jsonb_agg(jsonb_build_object('slug', s.slug, 'nome', s.nome, 'modelos', s.modelos) order by s.ordem) from s where s.categoria_slug = c.slug), '[]'::jsonb)) order by t.ordem)
          from public.loja_taxonomia t join c on c.slug = t.categoria_slug where t.vertical_id = v.id), '[]'::jsonb)) order by v.ordem) from public.loja_verticais v), '[]'::jsonb));
$$;

create or replace function public.loja_interpretar_busca(p_termo text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_t text := replace(private.slugify(p_termo), '-', ' '); v_f jsonb := '{}'::jsonb; r record;
begin
  for r in select * from public.loja_sinonimos order by id loop
    if v_t ~ r.padrao then
      v_t := btrim(regexp_replace(v_t, r.padrao, ' ', 'g'));
      v_f := jsonb_set(v_f, array[r.faceta], coalesce(v_f -> r.faceta, '[]'::jsonb) || to_jsonb(r.valor));
    end if;
  end loop;
  return jsonb_build_object('termo', nullif(regexp_replace(v_t, '\s+', ' ', 'g'), ''), 'filtros', v_f);
end $$;

revoke all on function public.loja_facetas(text[], text, jsonb), public.loja_modelos_f(text[], text, jsonb, text, integer, integer), public.loja_arvore(), public.loja_interpretar_busca(text) from public;
grant execute on function public.loja_facetas(text[], text, jsonb), public.loja_modelos_f(text[], text, jsonb, text, integer, integer), public.loja_arvore(), public.loja_interpretar_busca(text) to anon, authenticated, service_role;
