-- Facetas por família e rápidas (a versão anterior levava 7 s na loja inteira por passar a linha com fotos para cada filtro).
create or replace function private.loja_ok(p_sub text, p_tipo text, p_material text, p_gram text, p_formato text, p_prazo text, p_preco text, p_acab text[], f jsonb, skip text default null)
returns boolean language sql immutable set search_path = '' as $$
  select f is null or f = '{}'::jsonb or (
    (skip = 'sub' or f ->> 'sub' is null or p_sub = f ->> 'sub')
    and (skip = 'tipo' or f -> 'tipo' is null or f -> 'tipo' ? p_tipo)
    and (skip = 'material' or f -> 'material' is null or f -> 'material' ? p_material)
    and (skip = 'gram' or f -> 'gram' is null or f -> 'gram' ? p_gram)
    and (skip = 'formato' or f -> 'formato' is null or f -> 'formato' ? p_formato)
    and (skip = 'prazo' or f -> 'prazo' is null or f -> 'prazo' ? p_prazo)
    and (skip = 'preco' or f -> 'preco' is null or f -> 'preco' ? p_preco)
    and (skip = 'acab' or f -> 'acab' is null or exists (select 1 from jsonb_array_elements_text(f -> 'acab') z where z = any (p_acab))));
$$;

create or replace function public.loja_facetas(p_categorias text[] default null, p_termo text default null, p_filtros jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
    select a.sub, a.sub_nome, a.tipo, a.material, a.gram, a.formato, a.prazo, a.preco_faixa pf, a.acab, f.familia
      from private.loja_atributos a join private.loja_familias f on f.sku = a.sku
     where (p_categorias is null or a.categoria_slug = any(p_categorias))
       and (cardinality(v_palavras) = 0 or a.busca like all (array(select '%' || w || '%' from unnest(v_palavras) w)))
  ), f as (
    select 'sub' faceta, t.sub valor, min(t.sub_nome) rotulo, count(distinct t.familia) n from tb t where t.sub is not null and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.sub
    union all select 'tipo', t.tipo, null, count(distinct t.familia) from tb t where t.tipo is not null and (v_sub is null or t.sub = v_sub) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.tipo
    union all select 'material', t.material, null, count(distinct t.familia) from tb t where t.material is not null and (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.material
    union all select 'gram', t.gram, null, count(distinct t.familia) from tb t where t.gram is not null and (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.gram
    union all select 'acab', z, null, count(distinct t.familia) from tb t, unnest(t.acab) z where (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) group by z
    union all select 'formato', t.formato, null, count(distinct t.familia) from tb t where (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.formato
    union all select 'prazo', t.prazo, null, count(distinct t.familia) from tb t where (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab) group by t.prazo
    union all select 'preco', t.pf, null, count(distinct t.familia) from tb t where (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_acab is null or t.acab && v_acab) group by t.pf
  ), g as (
    select f.faceta, jsonb_agg(jsonb_build_object('valor', f.valor, 'rotulo', coalesce(f.rotulo, d.rotulo, f.valor), 'n', f.n)
             order by coalesce(d.ordem, 0), f.n desc, f.valor) itens
      from f left join public.loja_facetas_def d on d.faceta = f.faceta and d.valor = f.valor
     where f.n > 0 group by f.faceta)
  select coalesce(jsonb_object_agg(g.faceta, g.itens), '{}'::jsonb), (select count(distinct t.familia)::integer from tb t where (v_sub is null or t.sub = v_sub) and (v_tipo is null or t.tipo = any(v_tipo)) and (v_mat is null or t.material = any(v_mat)) and (v_gram is null or t.gram = any(v_gram)) and (v_for is null or t.formato = any(v_for)) and (v_pra is null or t.prazo = any(v_pra)) and (v_pre is null or t.pf = any(v_pre)) and (v_acab is null or t.acab && v_acab))
    into v_out, v_total from g;
  return jsonb_build_object('total', v_total, 'facetas', v_out);
end $$;

create or replace function public.loja_modelos_f(p_categorias text[] default null, p_termo text default null, p_filtros jsonb default '{}'::jsonb,
                                                 p_ordem text default 'relevancia', p_limite integer default 24, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
