-- Loja: cada SKU é um produto (uma página, uma foto, uma descrição, uma URL), como no modelo de referência.
-- Aditiva e idempotente. Nenhum SKU volta a ficar oculto: variantes sem descrição própria ganham o rótulo "Opção A/B...".

alter table public.ecommerce_products add column if not exists sku_slug text;
alter table public.ecommerce_products add column if not exists variante text;

-- slug legível por SKU: título + impressão + formato + quantidade + ref (a ref estável é a âncora da URL)
create or replace function private.loja_slug_sku(p_titulo text, p_cores text, p_formato text, p_quantidade integer, p_ref text)
returns text language sql immutable set search_path = '' as $$
  select trim(both '-' from left(
           regexp_replace(
             translate(lower(coalesce(p_titulo, '') || ' ' || coalesce(p_cores, '') || ' ' || coalesce(p_formato, '') || ' ' || coalesce(p_quantidade::text, '') || ' un'),
                       'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'),
             '[^a-z0-9]+', '-', 'g'), 110)) || '-' || p_ref;
$$;

create or replace function private.loja_sku_slug_linha() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.ref is not null then
    new.sku_slug := private.loja_slug_sku(new.titulo, new.cores_rotulo, new.formato_rotulo, new.quantidade, new.ref);
  end if;
  return new;
end $$;

drop trigger if exists zz_loja_sku_slug on public.ecommerce_products;
create trigger zz_loja_sku_slug before insert or update on public.ecommerce_products
  for each row execute function private.loja_sku_slug_linha();

create index if not exists ecommerce_products_ref_idx on public.ecommerce_products (ref);
create index if not exists ecommerce_products_sku_slug_idx on public.ecommerce_products (sku_slug);

-- a deduplicação deixa de ocultar: só separa slugs de títulos diferentes e rotula as variantes
create or replace function private.loja_dedup() returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_var integer; v_reativados integer; v_rotulos integer;
begin
  insert into public.loja_slug_variantes (sku, sufixo)
  select e.sku, '-' || left(md5(e.titulo), 6)
    from public.ecommerce_products e
    join (select case when s.sufixo is not null then left(p.produto_slug, length(p.produto_slug) - length(s.sufixo)) else p.produto_slug end base
            from public.ecommerce_products p left join public.loja_slug_variantes s on s.sku = p.sku
           group by 1 having count(distinct p.titulo) > 1) g on true
    left join public.loja_slug_variantes s2 on s2.sku = e.sku
   where (case when s2.sufixo is not null then left(e.produto_slug, length(e.produto_slug) - length(s2.sufixo)) else e.produto_slug end) = g.base
  on conflict (sku) do nothing;
  update public.ecommerce_products e set produto_slug = e.produto_slug || s.sufixo, atualizado_em = now()
    from public.loja_slug_variantes s where s.sku = e.sku and e.produto_slug not like '%' || s.sufixo;
  get diagnostics v_var = row_count;

  -- reativa o que a regra antiga ocultou (decisão do dono: nada fica oculto)
  update public.ecommerce_products set oculto = false, ativo = true, oculto_motivo = null, atualizado_em = now()
   where oculto and oculto_motivo like 'Variante sem descrição própria%'
     and exists (select 1 from public.catalogo c where c.sku = ecommerce_products.sku and c.active and c.vendavel and c.preco_venda is not null);
  get diagnostics v_reativados = row_count;

  with c as (
    select e.sku, row_number() over (partition by e.produto_slug, e.quantidade order by e.preco, e.sku) rn,
           count(*) over (partition by e.produto_slug, e.quantidade) n
      from public.ecommerce_products e where e.ativo)
  update public.ecommerce_products e
     set variante = case when c.n > 1 then 'Opção ' || case when c.rn <= 26 then chr(64 + c.rn::integer) else c.rn::text end end
    from c where c.sku = e.sku and e.variante is distinct from (case when c.n > 1 then 'Opção ' || case when c.rn <= 26 then chr(64 + c.rn::integer) else c.rn::text end end);
  get diagnostics v_rotulos = row_count;
  return jsonb_build_object('slugs_separados', v_var, 'reativados', v_reativados, 'rotulos', v_rotulos);
end $$;

-- preenche o que já existe (o gatilho recalcula sku_slug)
update public.ecommerce_products set sku_slug = private.loja_slug_sku(titulo, cores_rotulo, formato_rotulo, quantidade, ref) where ref is not null and sku_slug is null;
select private.loja_dedup();

-- lista por SKU: um card por SKU, na ordem do catálogo (tamanho, impressão, quantidade)
create or replace function public.loja_sku_lista(p_categorias text[] default null, p_termo text default null, p_filtros jsonb default '{}'::jsonb,
                                                 p_ordem text default 'relevancia', p_limite integer default 48, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_palavras text[]; v_lim integer := least(greatest(coalesce(p_limite, 48), 1), 500); v_off integer := greatest(coalesce(p_offset, 0), 0); v_out jsonb; v_total integer;
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
    select a.sku, a.ref, e.sku_slug, a.produto_slug, a.categoria_slug, e.categoria, e.titulo, a.preco, a.parcela_2x, a.quantidade, a.prazo_dias_uteis,
           e.cores_rotulo impressao, e.formato_rotulo formato, e.variante, a.sub, a.sub_nome, a.acab, a.fotos ->> 0 foto,
           coalesce(ss.ordem, 9999) sub_ordem
      from private.loja_atributos a
      join public.ecommerce_products e on e.sku = a.sku and e.ativo
      left join public.loja_subcategorias ss on ss.categoria_slug = a.categoria_slug and ss.slug = a.sub
     where (p_categorias is null or a.categoria_slug = any(p_categorias))
       and (cardinality(v_palavras) = 0 or a.busca like all (array(select '%' || w || '%' from unnest(v_palavras) w)))
       and (v_sub is null or a.sub = v_sub) and (v_tipo is null or a.tipo = any(v_tipo)) and (v_mat is null or a.material = any(v_mat))
       and (v_gram is null or a.gram = any(v_gram)) and (v_for is null or a.formato = any(v_for)) and (v_pra is null or a.prazo = any(v_pra))
       and (v_pre is null or a.preco_faixa = any(v_pre)) and (v_acab is null or a.acab && v_acab)
  ), ord as (
    select b.*, count(*) over () total, row_number() over (order by
        case when p_ordem = 'menor_preco' then b.preco end asc,
        case when p_ordem = 'maior_preco' then b.preco end desc,
        b.categoria_slug, b.sub_ordem, regexp_replace(b.titulo, '\d+', '', 'g'), coalesce(nullif(substring(b.titulo from '(\d+) ?g'), '')::integer, 0),
        b.titulo, b.formato, private.loja_ordem_impressao(b.impressao), b.quantidade, b.preco, b.sku) rn
      from base b
  )
  select coalesce(max(o.total), 0)::integer,
         coalesce(jsonb_agg(jsonb_build_object(
           'ref', o.ref, 'sku', o.sku, 'sku_slug', o.sku_slug, 'produto_slug', o.produto_slug, 'titulo', o.titulo, 'categoria', o.categoria, 'categoria_slug', o.categoria_slug,
           'foto', o.foto, 'preco', o.preco, 'parcela_2x', o.parcela_2x, 'quantidade', o.quantidade, 'prazo_dias_uteis', o.prazo_dias_uteis,
           'impressao', o.impressao, 'formato', o.formato, 'variante', o.variante, 'sub', o.sub, 'subcategoria', o.sub_nome, 'acab', to_jsonb(o.acab)) order by o.rn)
           filter (where o.rn > v_off and o.rn <= v_off + v_lim), '[]'::jsonb)
    into v_total, v_out from ord o;
  return jsonb_build_object('total', v_total, 'itens', v_out);
end $$;

-- página de um SKU (ref estável): reaproveita a ficha de loja_produto e acrescenta as quantidades irmãs
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
    'quantidades', coalesce((select jsonb_agg(jsonb_build_object('ref', x.ref, 'sku_slug', x.sku_slug, 'quantidade', x.quantidade, 'preco', x.preco, 'variante', x.variante)
                                              order by x.quantidade, x.preco, x.sku)
                               from public.ecommerce_products x where x.ativo and x.produto_slug = e.produto_slug), '[]'::jsonb));
end $$;

-- link antigo (produto agrupado) -> SKU mais barato do grupo
create or replace function public.loja_sku_do_produto(p_produto_slug text) returns text language sql stable security definer set search_path = '' as $$
  select e.ref || '|' || e.sku_slug from public.ecommerce_products e where e.ativo and e.produto_slug = p_produto_slug order by e.preco, e.quantidade, e.sku limit 1;
$$;

-- sitemap paginado (19 mil SKUs)
create or replace function public.loja_sku_slugs(p_offset integer default 0, p_limite integer default 5000) returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('s', x.sku_slug, 'u', x.atualizado_em)), '[]'::jsonb)
    from (select sku_slug, atualizado_em from public.ecommerce_products where ativo and sku_slug is not null
           order by sku_slug offset greatest(coalesce(p_offset, 0), 0) limit least(greatest(coalesce(p_limite, 5000), 1), 10000)) x;
$$;

-- facetas contando SKUs (mesmo corpo de loja_facetas, sem a junção com famílias)
do $mig$
declare d text;
begin
  select pg_get_functiondef('public.loja_facetas(text[],text,jsonb)'::regprocedure) into d;
  d := replace(d, 'public.loja_facetas(', 'public.loja_facetas_sku(');
  d := replace(d, 'count(distinct t.produto_slug)', 'count(*)');
  d := replace(d, 'a.acab, a.produto_slug', 'a.acab, a.sku');
  d := replace(d, ' join private.loja_familias f on f.sku = a.sku', '');
  execute d;
end $mig$;

revoke all on function public.loja_sku_lista(text[], text, jsonb, text, integer, integer) from public;
revoke all on function public.loja_sku_produto(text) from public;
revoke all on function public.loja_sku_do_produto(text) from public;
revoke all on function public.loja_sku_slugs(integer, integer) from public;
revoke all on function public.loja_facetas_sku(text[], text, jsonb) from public;
grant execute on function public.loja_sku_lista(text[], text, jsonb, text, integer, integer) to anon, authenticated, service_role;
grant execute on function public.loja_sku_produto(text) to anon, authenticated, service_role;
grant execute on function public.loja_sku_do_produto(text) to anon, authenticated, service_role;
grant execute on function public.loja_sku_slugs(integer, integer) to anon, authenticated, service_role;
grant execute on function public.loja_facetas_sku(text[], text, jsonb) to anon, authenticated, service_role;
