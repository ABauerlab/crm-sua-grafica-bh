-- Etapa 8: buscar_produto escondia opções reais. Priorizava famílias "parecidas" e usava a quantidade mais próxima por família, então
-- "cartão de visita" com 1.000 unidades devolvia 480 e 250 (o agente dizia que só havia o modelo de 500, com 56 SKUs de 1.000 un. no catálogo).
-- Agora, se a quantidade pedida existe, mostra até 4 opções dela do mais barato ao mais premium, preferindo categorias que contêm todos os termos
-- do pedido (singular ou plural), e devolve as quantidades disponíveis. Preço sempre de calcular_preco. Sem quantidade exata: comportamento anterior.
create or replace function private.categoria_bate(p_categoria text, p_toks text[]) returns boolean
language sql immutable set search_path = ''
as $$
  select not exists (
    select 1 from unnest(p_toks) t
    where position(t in private.norm_busca(p_categoria)) = 0
      and position((case when t ~ 'ao$' then regexp_replace(t, 'ao$', 'oes')
                         when t ~ 'oes$' then regexp_replace(t, 'oes$', 'ao')
                         when t ~ 's$' then regexp_replace(t, 's$', '')
                         else t || 's' end) in private.norm_busca(p_categoria)) = 0);
$$;

create or replace function public.buscar_produto(p_termo text, p_quantidade integer default null, p_filtros jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare
  v_stop constant text[] := array['de','da','do','das','dos','para','pra','com','e','um','uma','uns','umas','quero','queria','preciso','gostaria','orcamento','fazer','tem','voce','voces','vcs','por','favor','me','quanto','custa','valor','preco','em','no','na','o','a','os','as','ai','oi','ola','bom','dia','tarde','noite','mil','unidade','unidades','un'];
  v_norm text := private.norm_busca(p_termo);
  v_variantes text[]; v_alt text; s record; v_qtd integer := nullif(p_quantidade, 0);
  v_opcoes jsonb := '[]'::jsonb; v_sem_sku integer := 0; v_existe boolean := false;
  r record; j jsonb; v_cat text := nullif(btrim(p_filtros ->> 'categoria'), ''); v_cores text := nullif(btrim(p_filtros ->> 'cores'), '');
  v_tam text := nullif(btrim(p_filtros ->> 'tamanho'), ''); v_gram integer := nullif(p_filtros ->> 'gramatura', '')::integer;
  v_faltando text[] := '{}'; v_pergunta text; v_familias integer; v_desc integer; v_tams integer; v_cores_n integer;
  v_exact boolean := false; v_maxscore numeric := 0; v_qtds jsonb; v_toks text[]; v_cat_ok boolean := false;
begin
  if not private.atendente_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if length(v_norm) < 2 then return jsonb_build_object('ok', false, 'erro', 'termo_vazio'); end if;

  if private.is_staff() and exists (select 1 from public.catalogo c where c.sku = upper(btrim(p_termo))) then
    v_norm := private.norm_busca(upper(btrim(p_termo)));
    select jsonb_agg(jsonb_build_object('sku', c.sku, 'descricao_curta', concat_ws(' ', c.categoria, c.descricao, c.cores, c.tamanho_mm), 'quantidade', c.quantidade,
             'prazo_dias_uteis', c.prazo_dias_uteis, 'preco', (public.calcular_preco(c.sku, 1) ->> 'preco_total')::numeric, 'vendavel', c.vendavel, 'quantidade_exata', true))
      into v_opcoes from public.catalogo c where c.sku = upper(btrim(p_termo));
    return jsonb_build_object('ok', true, 'busca_por_sku', true, 'opcoes', v_opcoes);
  end if;

  v_toks := array(select tok from regexp_split_to_table(v_norm, ' ') tok where tok <> '' and not (tok = any (v_stop)) and tok !~ '^[0-9]+$');

  v_variantes := array[v_norm];
  for s in select distinct si.grupo, si.termo from public.sinonimos si where (' ' || v_norm || ' ') like ('% ' || si.termo || ' %') loop
    for v_alt in select si2.termo from public.sinonimos si2 where si2.grupo = s.grupo and si2.termo <> s.termo loop
      v_variantes := array_append(v_variantes, btrim(replace(' ' || v_norm || ' ', ' ' || s.termo || ' ', ' ' || v_alt || ' ')));
    end loop;
  end loop;
  v_variantes := array(select distinct x from unnest(v_variantes) x);

  create temp table if not exists _bp (id uuid, score numeric) on commit drop;
  truncate _bp;
  insert into _bp
  select id, max(score) from (
    select c.id,
           (count(*) filter (where position(t.tok in c.especificacao_normalizada) > 0))::numeric / nullif(count(*), 0)
             + extensions.similarity(c.especificacao_normalizada, v.variante) * 0.5 as score,
           count(*) filter (where position(t.tok in c.especificacao_normalizada) > 0 and t.tok !~ '^[0-9]+$') as casadas_texto,
           count(*) filter (where position(t.tok in c.especificacao_normalizada) > 0)::numeric / nullif(count(*), 0) as fracao
    from unnest(v_variantes) as v (variante)
    cross join lateral (select tok from regexp_split_to_table(v.variante, ' ') tok where tok <> '' and not (tok = any (v_stop))) t
    join public.catalogo c on c.especificacao_normalizada like '%' || t.tok || '%'
    where c.active and (v_cat is null or c.categoria ilike '%' || v_cat || '%') and (v_cores is null or c.cores ilike v_cores)
      and (v_tam is null or c.tamanho_mm ilike '%' || v_tam || '%') and (v_gram is null or c.gramatura_g = v_gram)
    group by c.id, v.variante, c.especificacao_normalizada
  ) q where casadas_texto >= 1 and fracao >= 0.6
  group by id;

  if not exists (select 1 from _bp) then
    insert into _bp
    select c.id, extensions.similarity(c.especificacao_normalizada, v_norm)
      from public.catalogo c
     where c.active and c.especificacao_normalizada operator(extensions.%) v_norm
       and (v_cat is null or c.categoria ilike '%' || v_cat || '%') and (v_cores is null or c.cores ilike v_cores)
       and (v_tam is null or c.tamanho_mm ilike '%' || v_tam || '%') and (v_gram is null or c.gramatura_g = v_gram)
     order by 2 desc limit 300;
  end if;

  select count(*) into v_sem_sku from _bp b join public.catalogo c on c.id = b.id where c.sku is null;

  create temp table if not exists _bp_fam (id uuid, score numeric, ordem numeric) on commit drop;
  truncate _bp_fam;
  insert into _bp_fam
  select distinct on (c.categoria, c.descricao, c.cores, c.tamanho_mm) c.id, b.score,
         row_number() over (order by b.score desc, c.preco_base_custo)
    from _bp b join public.catalogo c on c.id = b.id
   where c.sku is not null and c.vendavel
   order by c.categoria, c.descricao, c.cores, c.tamanho_mm,
            case when v_qtd is null then c.quantidade else abs(c.quantidade - v_qtd) end, c.quantidade desc;

  select coalesce(max(score), 0) into v_maxscore from _bp_fam;
  v_exact := v_qtd is not null and exists (select 1 from _bp_fam f join public.catalogo c on c.id = f.id where c.quantidade = v_qtd);
  v_cat_ok := v_exact and cardinality(v_toks) > 0 and exists (
    select 1 from _bp_fam f join public.catalogo c on c.id = f.id where c.quantidade = v_qtd and private.categoria_bate(c.categoria, v_toks));

  for r in
    with cand as (
      select c.sku, c.categoria, c.descricao, c.cores, c.tamanho_mm, c.quantidade, c.prazo_dias_uteis, c.vendavel, f.score, c.preco_base_custo,
             row_number() over (order by c.preco_base_custo, f.score desc) rn, count(*) over () n
        from _bp_fam f join public.catalogo c on c.id = f.id
       where (not v_exact)
          or (c.quantidade = v_qtd and ((v_cat_ok and private.categoria_bate(c.categoria, v_toks)) or (not v_cat_ok and f.score >= v_maxscore * 0.85)))
    )
    select * from cand
     where (not v_exact) or rn in (1, greatest(1, ceil(n / 3.0)::int), greatest(1, ceil(2 * n / 3.0)::int), n)
     order by case when v_exact then preco_base_custo else 0 end, score desc, preco_base_custo
     limit (case when v_exact then 4 else 5 end)
  loop
    j := public.calcular_preco(r.sku, 1, '{}'::jsonb);
    continue when not coalesce((j ->> 'ok')::boolean, false);
    v_existe := v_existe or (v_qtd is not null and r.quantidade = v_qtd);
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object(
      'sku', r.sku, 'descricao_curta', concat_ws(' ', initcap(lower(r.categoria)), r.descricao, r.cores, r.tamanho_mm),
      'quantidade', r.quantidade, 'prazo_dias_uteis', r.prazo_dias_uteis, 'preco', (j ->> 'preco_total')::numeric, 'vendavel', r.vendavel,
      'quantidade_exata', v_qtd is not null and r.quantidade = v_qtd));
  end loop;

  select coalesce(jsonb_agg(q order by q), '[]'::jsonb) into v_qtds
    from (select distinct c.quantidade q from _bp b join public.catalogo c on c.id = b.id
           where c.sku is not null and c.vendavel and (not v_cat_ok or private.categoria_bate(c.categoria, v_toks))) z;

  select count(*), count(distinct descricao), count(distinct tamanho_mm), count(distinct cores)
    into v_familias, v_desc, v_tams, v_cores_n
    from _bp_fam f join public.catalogo c on c.id = f.id;
  if v_qtd is null then v_faltando := array_append(v_faltando, 'quantidade'); end if;
  if v_tams > 1 and v_tam is null then v_faltando := array_append(v_faltando, 'tamanho'); end if;
  if v_desc > 1 and v_familias > 3 then v_faltando := array_append(v_faltando, 'papel'); end if;
  if v_cores_n > 1 and v_cores is null then v_faltando := array_append(v_faltando, 'cores'); end if;
  select q.pergunta into v_pergunta from public.qualificacao_perguntas q where q.campo = any (v_faltando) order by q.ordem limit 1;

  return jsonb_build_object('ok', true, 'opcoes', v_opcoes,
    'quantidade_pedida', v_qtd, 'quantidade_pedida_existe', v_existe,
    'quantidades_disponiveis', v_qtds,
    'total_opcoes_na_quantidade', case when v_exact then (select count(*) from _bp_fam f join public.catalogo c on c.id = f.id where c.quantidade = v_qtd and (not v_cat_ok or private.categoria_bate(c.categoria, v_toks))) end,
    'oferecer_mais_proxima', v_qtd is not null and not v_existe and jsonb_array_length(v_opcoes) > 0,
    'pergunta_qualificacao', case when jsonb_array_length(v_opcoes) = 0 or v_familias > 1 or v_qtd is null then v_pergunta end,
    'itens_sem_sku_encontrados', v_sem_sku,
    'orientacao', case when jsonb_array_length(v_opcoes) = 0 then case when v_sem_sku > 0 then 'sem_sku_chamar_dono_alta' else 'nao_encontrado_chamar_dono_alta' end end);
end;
$function$;
