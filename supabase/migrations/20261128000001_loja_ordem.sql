-- Tudo em ordem: tamanhos por medida e depois impressão (4x0, 4x1, 4x4, 1x0, 1x1); opções por subcategoria do fornecedor, nome e gramatura.
create or replace function private.loja_ordem_impressao(p text) returns integer language sql immutable set search_path = '' as $$
  select case lower(coalesce(p, '')) when 'colorido apenas na frente' then 1 when 'colorido na frente e preto e branco no verso' then 2 when 'colorido frente e verso' then 3
    when 'preto e branco apenas na frente' then 4 when 'preto e branco frente e verso' then 5 else 9 end;
$$;

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
                   'quantidade', s.qtd, 'prazo_dias_uteis', s.prazo, 'ref', s.ref) order by s.o1, s.o2, s.o3, s.preco)
                   from (select b.produto_slug, b.tamanho, min(b.cores_rotulo) imp, min(b.preco) preco, (array_agg(b.quantidade order by b.preco))[1] qtd,
                                min(b.prazo_dias_uteis) prazo, (array_agg(b.ref order by b.preco))[1] ref,
                                coalesce(nullif(substring(b.tamanho from '\d+'), '')::integer, 0) o1,
                                coalesce(nullif(substring(b.tamanho from '\d+\D+(\d+)'), '')::integer, 0) o2,
                                private.loja_ordem_impressao(min(b.cores_rotulo)) o3
                           from base b group by b.produto_slug, b.tamanho) s)) end
    from base;
$$;

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
           (array_agg(to_jsonb(b.acab) order by b.preco))[1] acab, (array_agg(to_jsonb(b.tags) order by b.preco))[1] tags,
           coalesce(min(ss.ordem), 9999) sub_ordem
      from base b join public.ecommerce_products e on e.sku = b.sku
      left join public.loja_subcategorias ss on ss.categoria_slug = b.categoria_slug and ss.slug = b.sub group by b.familia, b.categoria_slug
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
end $$;
