-- E-commerce Fase 5: dados das páginas da loja (categorias, produto com opções e variações, lista para o sitemap).
-- Só campos públicos (ref, nunca SKU).

create or replace function public.loja_categorias()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(c order by c.produtos desc), '[]'::jsonb) from (
    select e.categoria_slug slug, min(e.categoria) nome, count(distinct e.produto_slug)::integer produtos, min(e.preco) a_partir_de,
           (array_agg(e.fotos ->> 0 order by e.preco) filter (where jsonb_array_length(e.fotos) > 0))[1] foto
      from public.ecommerce_products e where e.ativo group by e.categoria_slug) c;
$$;

create or replace function public.loja_produto(p_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_cat text; v_formato text; v_impressao text;
begin
  select jsonb_build_object(
      'produto_slug', p_slug, 'titulo', min(e.titulo), 'categoria', min(e.categoria), 'categoria_slug', min(e.categoria_slug),
      'impressao', min(e.cores_rotulo), 'formato', min(e.formato_rotulo), 'especificacao', min(e.especificacao),
      'descricao', min(e.descricao),
      'ficha', (array_agg(e.ficha) filter (where e.ficha <> '{}'::jsonb))[1],
      'acabamentos', (array_agg(e.acabamentos) filter (where jsonb_array_length(e.acabamentos) > 0))[1],
      'fotos', coalesce((array_agg(e.fotos) filter (where jsonb_array_length(e.fotos) > 0))[1], '[]'::jsonb),
      'prazo_dias_uteis', max(e.prazo_dias_uteis), 'a_partir_de', min(e.preco), 'ate', max(e.preco),
      'opcoes', jsonb_agg(jsonb_build_object('ref', e.ref, 'quantidade', e.quantidade, 'preco', e.preco, 'parcela_2x', e.parcela_2x,
                                             'peso_kg', e.peso_kg) order by e.quantidade, e.preco),
      'atualizado_em', max(e.atualizado_em)),
    min(e.categoria_slug), min(e.formato_rotulo), min(e.cores_rotulo)
    into v, v_cat, v_formato, v_impressao
    from public.ecommerce_products e where e.ativo and e.produto_slug = p_slug;
  if v_cat is null then return null; end if;
  -- variações: outros produtos da mesma categoria, primeiro os de mesmo formato e mesma impressão
  return v || jsonb_build_object('variacoes', coalesce((
    select jsonb_agg(x order by x.ordem, x.a_partir_de) from (
      select e.produto_slug, min(e.titulo) titulo, min(e.cores_rotulo) impressao, min(e.formato_rotulo) formato, min(e.preco) a_partir_de,
             (array_agg(e.fotos ->> 0) filter (where jsonb_array_length(e.fotos) > 0))[1] foto,
             (case when min(e.formato_rotulo) = v_formato then 0 else 2 end) + (case when min(e.cores_rotulo) = v_impressao then 0 else 1 end) ordem
        from public.ecommerce_products e
       where e.ativo and e.categoria_slug = v_cat and e.produto_slug <> p_slug
       group by e.produto_slug
       order by 7, 5 limit 12) x), '[]'::jsonb));
end $$;

create or replace function public.loja_slugs()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'produtos', (select coalesce(jsonb_agg(jsonb_build_object('s', p.produto_slug, 'u', p.u)), '[]'::jsonb)
                   from (select produto_slug, max(atualizado_em) u from public.ecommerce_products where ativo group by produto_slug) p),
    'categorias', (select coalesce(jsonb_agg(distinct categoria_slug), '[]'::jsonb) from public.ecommerce_products where ativo));
$$;

revoke all on function public.loja_categorias() from public;
revoke all on function public.loja_produto(text) from public;
revoke all on function public.loja_slugs() from public;
grant execute on function public.loja_categorias() to anon, authenticated, service_role;
grant execute on function public.loja_produto(text) to anon, authenticated, service_role;
grant execute on function public.loja_slugs() to anon, authenticated, service_role;
