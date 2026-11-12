-- Página de um SKU: as quantidades irmãs, as impressões irmãs e as outras opções passam a apontar para SKUs (ref e sku_slug), não para o produto agrupado.
create or replace function public.loja_sku_produto(p_ref text) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare e public.ecommerce_products%rowtype; v jsonb;
begin
  select * into e from public.ecommerce_products where ref = btrim(coalesce(p_ref, '')) and ativo;
  if not found then return null; end if;
  v := public.loja_produto(e.produto_slug);
  if v is null then return null; end if;
  return (v - 'opcoes' - 'a_partir_de' - 'ate' - 'sku' - 'produto_slug') || jsonb_build_object(
    'ref', e.ref, 'sku', e.sku, 'sku_slug', e.sku_slug, 'produto_slug', e.produto_slug, 'variante', e.variante,
    'quantidade', e.quantidade, 'preco', e.preco, 'parcela_2x', e.parcela_2x, 'prazo_dias_uteis', e.prazo_dias_uteis, 'peso_kg', e.peso_kg,
    'impressao', e.cores_rotulo, 'formato', e.formato_rotulo, 'titulo', e.titulo,
    'fotos', case when jsonb_array_length(coalesce(e.fotos, '[]'::jsonb)) > 0 then e.fotos else coalesce(v -> 'fotos', '[]'::jsonb) end,
    'quantidades', coalesce((select jsonb_agg(jsonb_build_object('ref', x.ref, 'sku', x.sku, 'sku_slug', x.sku_slug, 'quantidade', x.quantidade, 'preco', x.preco,
                                                                  'parcela_2x', x.parcela_2x, 'prazo_dias_uteis', x.prazo_dias_uteis, 'peso_kg', x.peso_kg, 'variante', x.variante)
                                              order by x.quantidade, x.preco, x.sku)
                               from public.ecommerce_products x where x.ativo and x.produto_slug = e.produto_slug), '[]'::jsonb),
    'irmaos', coalesce((select jsonb_agg(jsonb_build_object('produto_slug', i.produto_slug, 'impressao', i.impressao, 'formato', i.formato, 'a_partir_de', i.preco,
                                                            'ref', i.ref, 'sku_slug', i.sku_slug, 'quantidade', i.quantidade) order by i.formato, i.impressao)
                          from (select distinct on (x.produto_slug) x.produto_slug, x.cores_rotulo impressao, x.formato_rotulo formato, x.preco, x.ref, x.sku_slug, x.quantidade
                                  from public.ecommerce_products x
                                 where x.ativo and x.categoria_slug = e.categoria_slug and x.titulo = e.titulo
                                 order by x.produto_slug, (x.quantidade = e.quantidade) desc, x.preco, x.sku limit 24) i), '[]'::jsonb),
    'variacoes', coalesce((select jsonb_agg(t.el || jsonb_build_object('ref', s.ref, 'sku_slug', s.sku_slug) order by t.ord)
                             from jsonb_array_elements(coalesce(v -> 'variacoes', '[]'::jsonb)) with ordinality t(el, ord)
                             cross join lateral (select x.ref, x.sku_slug from public.ecommerce_products x
                                                  where x.ativo and x.produto_slug = t.el ->> 'produto_slug' order by x.preco, x.quantidade, x.sku limit 1) s), '[]'::jsonb));
end $$;

grant execute on function public.loja_sku_produto(text) to anon, authenticated, service_role;
