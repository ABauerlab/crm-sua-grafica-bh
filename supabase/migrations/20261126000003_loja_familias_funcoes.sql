-- Listagem por família (uma opção por card, tamanhos dentro), página da família e árvore com fotos. Limite de até 2000 cards para listar tudo em uma página.
create or replace function public.loja_modelos_f(p_categorias text[] default null, p_termo text default null, p_filtros jsonb default '{}'::jsonb,
                                                 p_ordem text default 'relevancia', p_limite integer default 24, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_palavras text[]; v_lim integer := least(greatest(coalesce(p_limite, 24), 1), 2000); v_off integer := greatest(coalesce(p_offset, 0), 0); v_out jsonb; v_total integer;
begin
  v_palavras := private.loja_palavras_busca(p_termo);
  with base as (
    select a.*, f.familia, f.titulo_card, f.tamanho, f.tags from private.loja_atributos a join private.loja_familias f on f.sku = a.sku
     where (p_categorias is null or a.categoria_slug = any(p_categorias))
       and (cardinality(v_palavras) = 0 or a.busca like all (array(select '%' || w || '%' from unnest(v_palavras) w)))
       and private.loja_passa(a, p_filtros)
  ), m as (
    select b.familia, b.categoria_slug, min(b.titulo_card) titulo, min(e.categoria) categoria,
           (array_agg(b.produto_slug order by b.preco, b.quantidade))[1] produto_slug,
           (array_agg(b.fotos ->> 0 order by b.preco) filter (where jsonb_array_length(b.fotos) > 0))[1] foto,
           min(b.preco) a_partir_de, (array_agg(b.parcela_2x order by b.preco))[1] parcela_2x_a_partir_de,
           (array_agg(b.sku order by b.preco, b.quantidade))[1] sku, (array_agg(b.ref order by b.preco, b.quantidade))[1] ref,
           (array_agg(b.quantidade order by b.preco, b.quantidade))[1] quantidade,
           count(distinct b.tamanho)::integer tamanhos, count(distinct b.produto_slug)::integer variacoes,
           min(b.sub_nome) subcategoria, min(b.sub) sub, min(b.prazo_dias_uteis) prazo_dias_uteis,
           (array_agg(to_jsonb(b.acab) order by b.preco))[1] acab, (array_agg(to_jsonb(b.tags) order by b.preco))[1] tags
      from base b join public.ecommerce_products e on e.sku = b.sku group by b.familia, b.categoria_slug
  ), ord as (
    select m.*, row_number() over (order by
        case when p_ordem = 'menor_preco' then m.a_partir_de end asc,
        case when p_ordem = 'maior_preco' then m.a_partir_de end desc,
        (m.foto is null), m.categoria_slug, m.sub, m.titulo, m.a_partir_de) rn from m
  )
  select (select count(*)::integer from m),
         coalesce(jsonb_agg(to_jsonb(o) - 'rn' order by o.rn) filter (where o.rn > v_off and o.rn <= v_off + v_lim), '[]'::jsonb)
    into v_total, v_out from ord o;
  return jsonb_build_object('total', v_total, 'modelos', v_out);
end $$;

create or replace function public.loja_familia(p_familia text)
returns jsonb language sql stable security definer set search_path = '' as $$
  with base as (
    select a.*, f.titulo_card, f.tamanho, f.tags, e.categoria, e.cores_rotulo
      from private.loja_familias f join private.loja_atributos a on a.sku = f.sku join public.ecommerce_products e on e.sku = f.sku
     where f.familia = p_familia
  )
  select case when count(*) = 0 then null else jsonb_build_object(
    'familia', p_familia, 'titulo', min(titulo_card), 'categoria', min(categoria), 'categoria_slug', min(categoria_slug),
    'subcategoria', min(sub_nome), 'sub', min(sub),
    'foto', (array_agg(fotos ->> 0 order by preco) filter (where jsonb_array_length(fotos) > 0))[1],
    'tags', to_jsonb((array_agg(tags order by preco))[1]),
    'tamanhos', (select jsonb_agg(jsonb_build_object('produto_slug', s.produto_slug, 'tamanho', s.tamanho, 'impressao', s.imp, 'a_partir_de', s.preco,
                   'quantidade', s.qtd, 'prazo_dias_uteis', s.prazo, 'ref', s.ref) order by s.o1, s.o2, s.preco)
                   from (select b.produto_slug, b.tamanho, min(b.cores_rotulo) imp, min(b.preco) preco, (array_agg(b.quantidade order by b.preco))[1] qtd,
                                min(b.prazo_dias_uteis) prazo, (array_agg(b.ref order by b.preco))[1] ref,
                                coalesce(nullif(substring(b.tamanho from '\d+'), '')::integer, 0) o1,
                                coalesce(nullif(substring(b.tamanho from '\d+\D+(\d+)'), '')::integer, 0) o2
                           from base b group by b.produto_slug, b.tamanho) s)) end
    from base;
$$;

create or replace function public.loja_arvore()
returns jsonb language sql stable security definer set search_path = '' as $$
  with c as (
    select e.categoria_slug slug, min(e.categoria) nome, count(distinct e.produto_slug)::integer produtos, count(distinct f.familia)::integer modelos, min(e.preco) a_partir_de,
           (array_agg(e.fotos ->> 0 order by e.preco) filter (where jsonb_array_length(e.fotos) > 0))[1] foto
      from public.ecommerce_products e join private.loja_familias f on f.sku = e.sku where e.ativo group by e.categoria_slug
  ), s as (
    select a.categoria_slug, a.sub slug, min(a.sub_nome) nome, count(distinct f.familia)::integer modelos, min(ss.ordem) ordem,
           (array_agg(a.fotos ->> 0 order by a.preco) filter (where jsonb_array_length(a.fotos) > 0))[1] foto
      from private.loja_atributos a join private.loja_familias f on f.sku = a.sku join public.loja_subcategorias ss on ss.categoria_slug = a.categoria_slug and ss.slug = a.sub
     where a.sub is not null group by a.categoria_slug, a.sub
  )
  select jsonb_build_object('verticais', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'nome', v.nome, 'descricao', v.descricao,
      'modelos', (select coalesce(sum(c.modelos), 0)::integer from public.loja_taxonomia t join c on c.slug = t.categoria_slug where t.vertical_id = v.id),
      'categorias', coalesce((select jsonb_agg(jsonb_build_object('slug', c.slug, 'nome', c.nome, 'produtos', c.produtos, 'modelos', c.modelos, 'a_partir_de', c.a_partir_de, 'foto', c.foto,
          'subcategorias', coalesce((select jsonb_agg(jsonb_build_object('slug', s.slug, 'nome', s.nome, 'modelos', s.modelos, 'foto', s.foto) order by s.ordem) from s where s.categoria_slug = c.slug), '[]'::jsonb)) order by t.ordem)
          from public.loja_taxonomia t join c on c.slug = t.categoria_slug where t.vertical_id = v.id), '[]'::jsonb)) order by v.ordem) from public.loja_verticais v), '[]'::jsonb));
$$;

revoke all on function public.loja_familia(text) from public;
grant execute on function public.loja_familia(text) to anon, authenticated, service_role;
