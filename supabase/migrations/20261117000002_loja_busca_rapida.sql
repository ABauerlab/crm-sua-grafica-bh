-- Busca da loja abaixo de 3 s (limite do acesso anônimo): texto de busca pré-calculado e índice trigrama.
create extension if not exists pg_trgm with schema extensions;

alter table public.ecommerce_products add column if not exists busca text;

create or replace function private.ecommerce_busca_texto()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- usa o título da ficha quando existir (o gatilho do título roda depois deste, em ordem alfabética)
  new.busca := private.slugify(concat_ws(' ', coalesce(nullif(new.ficha ->> 'titulo', ''), new.titulo), new.categoria, new.cores_rotulo, new.formato_rotulo, new.especificacao));
  return new;
end $$;
drop trigger if exists ecommerce_busca_texto on public.ecommerce_products;
create trigger ecommerce_busca_texto before insert or update on public.ecommerce_products
  for each row execute function private.ecommerce_busca_texto();

update public.ecommerce_products set busca = private.slugify(concat_ws(' ', coalesce(nullif(ficha ->> 'titulo', ''), titulo), categoria, cores_rotulo, formato_rotulo, especificacao));

create index if not exists ecommerce_products_busca_trgm on public.ecommerce_products using gin (busca extensions.gin_trgm_ops) where ativo;

create or replace function public.loja_buscar(p_termo text default null, p_limite integer default 12, p_categoria text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_palavras text[]; v_lim integer := least(greatest(coalesce(p_limite, 12), 1), 48); v_out jsonb; v_total integer;
begin
  v_palavras := array(select left(w, greatest(4, length(w) - 2)) from unnest(string_to_array(private.slugify(left(coalesce(p_termo, ''), 80)), '-')) w where length(w) >= 2);
  with base as (
    select e.produto_slug, e.titulo, e.categoria, e.categoria_slug, e.cores_rotulo, e.formato_rotulo, e.fotos, e.preco, e.parcela_2x,
           e.prazo_dias_uteis, e.ref, e.quantidade
      from public.ecommerce_products e
     where e.ativo
       and (p_categoria is null or e.categoria_slug = p_categoria)
       and (cardinality(v_palavras) = 0 or e.busca like all (array(select '%' || w || '%' from unnest(v_palavras) w)))
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
