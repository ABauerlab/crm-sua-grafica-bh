-- Corrige o acabamento devolvido por modelo (array de arrays virava nulo)
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
           min(b.sub_nome) subcategoria, min(b.prazo_dias_uteis) prazo_dias_uteis, (array_agg(to_jsonb(b.acab) order by b.preco))[1] acab
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


grant execute on function public.loja_modelos_f(text[], text, jsonb, text, integer, integer) to anon, authenticated, service_role;
