-- Fase 11: vitrine em modelos comerciais, SKU público da planilha de venda e base dos acabamentos extras.
-- Decisão do dono (10/11/2026): o SKU da planilha de preços de venda passa a ser público. Custo, piso e margem continuam fechados.

-- 1) Lista de modelos (agrupa por papel/acabamento = título; impressão e formato viram variações)
create or replace function public.loja_modelos(p_categorias text[] default null, p_termo text default null, p_limite integer default 24, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_palavras text[]; v_lim integer := least(greatest(coalesce(p_limite, 24), 1), 48); v_off integer := greatest(coalesce(p_offset, 0), 0); v_out jsonb; v_total integer;
begin
  v_palavras := private.loja_palavras_busca(p_termo);
  with base as (
    select e.* from public.ecommerce_products e
     where e.ativo
       and (p_categorias is null or e.categoria_slug = any(p_categorias))
       and (cardinality(v_palavras) = 0 or e.busca like all (array(select '%' || w || '%' from unnest(v_palavras) w)))
  ), m as (
    select b.titulo, b.categoria_slug,
           min(b.categoria) categoria,
           (array_agg(b.produto_slug order by b.preco, b.quantidade))[1] produto_slug,
           (array_agg(b.fotos ->> 0 order by b.preco) filter (where jsonb_array_length(b.fotos) > 0))[1] foto,
           min(b.preco) a_partir_de,
           (array_agg(b.parcela_2x order by b.preco))[1] parcela_2x_a_partir_de,
           (array_agg(b.sku order by b.preco, b.quantidade))[1] sku,
           (array_agg(b.ref order by b.preco, b.quantidade))[1] ref,
           (array_agg(b.quantidade order by b.preco, b.quantidade))[1] quantidade,
           count(distinct b.produto_slug)::integer variacoes
      from base b group by b.titulo, b.categoria_slug
  ), ord as (
    select m.*, row_number() over (order by (m.foto is null), m.categoria_slug, m.titulo) rn from m
  )
  select (select count(*)::integer from m),
         coalesce(jsonb_agg(to_jsonb(o) - 'rn' order by o.rn) filter (where o.rn > v_off and o.rn <= v_off + v_lim), '[]'::jsonb)
    into v_total, v_out from ord o;
  return jsonb_build_object('total', v_total, 'modelos', v_out);
end $$;

-- 2) SKU nas opções da busca (a_partir_de continua igual)
create or replace function public.loja_buscar(p_termo text default null, p_limite integer default 12, p_categoria text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_palavras text[]; v_lim integer := least(greatest(coalesce(p_limite, 12), 1), 48); v_out jsonb; v_total integer;
begin
  v_palavras := private.loja_palavras_busca(p_termo);
  with base as (
    select e.produto_slug, e.titulo, e.categoria, e.categoria_slug, e.cores_rotulo, e.formato_rotulo, e.fotos, e.preco, e.parcela_2x,
           e.prazo_dias_uteis, e.ref, e.quantidade, e.sku
      from public.ecommerce_products e
     where e.ativo
       and (p_categoria is null or e.categoria_slug = p_categoria)
       and (cardinality(v_palavras) = 0 or e.busca like all (array(select '%' || w || '%' from unnest(v_palavras) w)))
  ), prod as (
    select b.produto_slug,
           min(b.titulo) titulo, min(b.categoria) categoria, min(b.categoria_slug) categoria_slug,
           min(b.cores_rotulo) impressao, min(b.formato_rotulo) formato,
           (array_agg(b.fotos ->> 0) filter (where jsonb_array_length(b.fotos) > 0))[1] foto,
           (array_agg(b.sku order by b.preco, b.quantidade))[1] sku,
           min(b.preco) a_partir_de, min(b.parcela_2x) parcela_2x_a_partir_de, max(b.prazo_dias_uteis) prazo_dias_uteis,
           jsonb_agg(jsonb_build_object('ref', b.ref, 'sku', b.sku, 'quantidade', b.quantidade, 'preco', b.preco, 'parcela_2x', b.parcela_2x) order by b.quantidade, b.preco) opcoes,
           bool_or(cardinality(v_palavras) > 0 and private.slugify(b.titulo) like '%' || v_palavras[1] || '%') no_titulo
      from base b group by b.produto_slug
  )
  select count(*)::integer, coalesce(jsonb_agg(to_jsonb(x) - 'no_titulo' - 'rn') filter (where x.rn <= v_lim), '[]'::jsonb) into v_total, v_out
    from (select p.*, row_number() over (order by p.no_titulo desc, p.a_partir_de) rn from prod p) x;
  return jsonb_build_object('total', v_total, 'produtos', v_out);
end $$;

-- 3) Produto: SKU por opção e "irmãos" (mesmo modelo, outra impressão ou formato)
create or replace function public.loja_produto(p_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_cat text; v_formato text; v_impressao text; v_titulo text;
begin
  select jsonb_build_object(
      'produto_slug', p_slug, 'titulo', min(e.titulo), 'categoria', min(e.categoria), 'categoria_slug', min(e.categoria_slug),
      'impressao', min(e.cores_rotulo), 'formato', min(e.formato_rotulo), 'especificacao', min(e.especificacao),
      'descricao', min(e.descricao),
      'ficha', (array_agg(e.ficha) filter (where e.ficha <> '{}'::jsonb))[1],
      'acabamentos', (array_agg(e.acabamentos) filter (where jsonb_array_length(e.acabamentos) > 0))[1],
      'fotos', coalesce((array_agg(e.fotos) filter (where jsonb_array_length(e.fotos) > 0))[1], '[]'::jsonb),
      'prazo_dias_uteis', max(e.prazo_dias_uteis), 'a_partir_de', min(e.preco), 'ate', max(e.preco),
      'sku', (array_agg(e.sku order by e.preco, e.quantidade))[1],
      'opcoes', jsonb_agg(jsonb_build_object('ref', e.ref, 'sku', e.sku, 'quantidade', e.quantidade, 'preco', e.preco, 'parcela_2x', e.parcela_2x,
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
end $$;

-- 4) Acabamentos extras: custo FECHADO ao público; venda = 3x o custo, arredondada para terminar em ,90 (nunca abaixo de 3x)
create table if not exists public.acabamentos_extras (
  id bigint generated always as identity primary key,
  categoria_slug text not null,
  nome text not null,
  custo numeric(10,2) not null check (custo >= 0),
  venda numeric(10,2) generated always as (ceil(custo * 3 + 0.10) - 0.10) stored,
  ativo boolean not null default true,
  origem text not null default 'importacao',
  criado_em timestamptz not null default now(),
  unique (categoria_slug, nome)
);
alter table public.acabamentos_extras enable row level security;
drop policy if exists acabamentos_extras_dono on public.acabamentos_extras;
create policy acabamentos_extras_dono on public.acabamentos_extras for all to authenticated using (private.is_admin()) with check (private.is_admin());
revoke all on public.acabamentos_extras from anon, authenticated;
grant select, insert, update, delete on public.acabamentos_extras to authenticated;

-- só nome e preço de venda (nunca o custo)
create or replace function public.loja_acabamentos(p_categoria_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('nome', a.nome, 'venda', a.venda) order by a.venda), '[]'::jsonb)
    from public.acabamentos_extras a where a.ativo and a.categoria_slug = p_categoria_slug;
$$;

revoke all on function public.loja_modelos(text[], text, integer, integer) from public;
revoke all on function public.loja_acabamentos(text) from public;
grant execute on function public.loja_modelos(text[], text, integer, integer) to anon, authenticated, service_role;
grant execute on function public.loja_acabamentos(text) to anon, authenticated, service_role;
