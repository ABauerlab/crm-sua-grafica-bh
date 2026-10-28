-- Agente de IA, Etapa 2 (3/4): busca de produto (sinônimos, texto e trigram, sem acento), perguntas de qualificação e funções seguras para o agente.
-- Nada aqui devolve custo, piso, margem ou lucro: só sku, descrição, quantidade, prazo bruto, preço final de calcular_preco e flags.

-- Quem pode usar as funções seguras (que não devolvem custo): atendentes cadastrados e o servidor (n8n, service role)
create or replace function private.atendente_ou_servidor() returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.profiles where id = (select auth.uid())) or coalesce(auth.role(), '') = 'service_role'; $$;
revoke execute on function private.atendente_ou_servidor() from public, anon;
grant execute on function private.atendente_ou_servidor() to authenticated, service_role;

-- ---------------------------------------------------------------- 1. sinônimos
create table if not exists public.sinonimos (
  id uuid primary key default gen_random_uuid(),
  grupo text not null,
  termo text not null,
  origem text not null default 'manual' check (origem in ('manual', 'categoria')),
  criado_em timestamptz not null default now(),
  unique (grupo, termo)
);
create index if not exists sinonimos_termo_idx on public.sinonimos (termo);

-- termos sempre guardados já normalizados (private.norm_busca)
create or replace function private.sinonimos_norm() returns trigger
language plpgsql set search_path = ''
as $$ begin new.termo := private.norm_busca(new.termo); new.grupo := private.norm_busca(new.grupo); return new; end; $$;
revoke execute on function private.sinonimos_norm() from public, anon, authenticated;
drop trigger if exists sinonimos_norm on public.sinonimos;
create trigger sinonimos_norm before insert or update on public.sinonimos for each row execute function private.sinonimos_norm();

insert into public.sinonimos (grupo, termo) values
  ('cartao de visita', 'cartao de visita'), ('cartao de visita', 'cartao'), ('cartao de visita', 'cartoes'), ('cartao de visita', 'cartao visita'), ('cartao de visita', 'cartao pessoal'),
  ('panfleto', 'panfleto'), ('panfleto', 'flyer'), ('panfleto', 'folheto'), ('panfleto', 'folder'), ('panfleto', 'filipeta'), ('panfleto', 'volante'),
  ('adesivo', 'adesivo'), ('adesivo', 'etiqueta'), ('adesivo', 'sticker'), ('adesivo', 'rotulo'), ('adesivo', 'etiquetas adesivas'),
  ('banner', 'banner'), ('banner', 'lona'), ('banner', 'faixa de lona'),
  ('ima', 'ima'), ('ima', 'iman'), ('ima', 'ima de geladeira'), ('ima', 'magnetico'),
  ('cracha', 'cracha'), ('cracha', 'credencial'), ('cracha', 'identificacao'),
  ('tag', 'tag'), ('tag', 'tags'), ('tag', 'etiqueta de roupa'), ('tag', 'tag de roupa'), ('tag', 'pendurar'),
  ('calendario', 'calendario'), ('calendario', 'agenda de parede'),
  ('caneca', 'caneca'), ('caneca', 'xicara'), ('caneca', 'copo'),
  ('camiseta', 'camiseta'), ('camiseta', 'camisa'), ('camiseta', 'uniforme'),
  ('sacola', 'sacola'), ('sacola', 'sacolinha'), ('sacola', 'embalagem')
on conflict do nothing;

-- Carga inicial a partir das categorias do catálogo: cada categoria vira um grupo com o próprio nome (e o nome sem plural). Idempotente.
create or replace function public.sinonimos_carregar_categorias() returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_n integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono.' using errcode = '42501'; end if;
  insert into public.sinonimos (grupo, termo, origem)
  select distinct private.norm_busca(c.categoria), private.norm_busca(c.categoria), 'categoria'
    from public.catalogo c where c.categoria is not null and private.norm_busca(c.categoria) <> ''
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.sinonimos_carregar_categorias() from public, anon;

-- ---------------------------------------------------------------- 2. perguntas de qualificação (o que falta saber)
create table if not exists public.qualificacao_perguntas (
  campo text primary key,
  ordem smallint not null,
  pergunta text not null
);
insert into public.qualificacao_perguntas (campo, ordem, pergunta) values
  ('quantidade', 1, 'Quantas unidades você precisa?'),
  ('tamanho', 2, 'Qual tamanho você tem em mente?'),
  ('papel', 3, 'Prefere um papel mais encorpado e com acabamento melhor, ou o mais simples?'),
  ('cores', 4, 'Quer impressão só na frente ou frente e verso?')
on conflict (campo) do nothing;

do $$
declare t text;
begin
  foreach t in array array['sinonimos', 'qualificacao_perguntas', 'itens_fora_catalogo'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('drop policy if exists %I on public.%I', t || '_dono', t);
    execute format('create policy %I on public.%I for all to authenticated using (private.is_staff()) with check (private.is_staff())', t || '_dono', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- 3. buscar_produto
-- Texto livre vira variantes (sinônimos), cada variante pontua pelos termos que aparecem na especificação do item e pela similaridade.
-- Cada FAMÍLIA (mesma categoria, descrição, cores e tamanho) aparece uma vez, na quantidade mais próxima da pedida. No máximo 5 opções.
create or replace function public.buscar_produto(p_termo text, p_quantidade integer default null, p_filtros jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_stop constant text[] := array['de','da','do','das','dos','para','pra','com','e','um','uma','uns','umas','quero','queria','preciso','gostaria','orcamento','fazer','tem','voce','voces','vcs','por','favor','me','quanto','custa','valor','preco','em','no','na','o','a','os','as','ai','oi','ola','bom','dia','tarde','noite','mil','unidade','unidades','un'];
  v_norm text := private.norm_busca(p_termo);
  v_variantes text[]; v_alt text; s record; v_qtd integer := nullif(p_quantidade, 0);
  v_opcoes jsonb := '[]'::jsonb; v_sem_sku integer := 0; v_existe boolean := false;
  r record; j jsonb; v_cat text := nullif(btrim(p_filtros ->> 'categoria'), ''); v_cores text := nullif(btrim(p_filtros ->> 'cores'), '');
  v_tam text := nullif(btrim(p_filtros ->> 'tamanho'), ''); v_gram integer := nullif(p_filtros ->> 'gramatura', '')::integer;
  v_faltando text[] := '{}'; v_pergunta text; v_familias integer; v_desc integer; v_tams integer; v_cores_n integer;
begin
  if not private.atendente_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if length(v_norm) < 2 then return jsonb_build_object('ok', false, 'erro', 'termo_vazio'); end if;

  -- o dono pode buscar direto pelo SKU
  if private.is_staff() and exists (select 1 from public.catalogo c where c.sku = upper(btrim(p_termo))) then
    v_norm := private.norm_busca(upper(btrim(p_termo)));
    select jsonb_agg(jsonb_build_object('sku', c.sku, 'descricao_curta', concat_ws(' ', c.categoria, c.descricao, c.cores, c.tamanho_mm), 'quantidade', c.quantidade,
             'prazo_dias_uteis', c.prazo_dias_uteis, 'preco', (public.calcular_preco(c.sku, 1) ->> 'preco_total')::numeric, 'vendavel', c.vendavel, 'quantidade_exata', true))
      into v_opcoes from public.catalogo c where c.sku = upper(btrim(p_termo));
    return jsonb_build_object('ok', true, 'busca_por_sku', true, 'opcoes', v_opcoes);
  end if;

  -- variantes por sinônimo
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

  -- digitou errado ("cartao de vizita"): cai para similaridade de trigramas
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

  for r in
    select c.sku, c.categoria, c.descricao, c.cores, c.tamanho_mm, c.quantidade, c.prazo_dias_uteis, c.vendavel, f.score
      from _bp_fam f join public.catalogo c on c.id = f.id
     order by f.score desc, c.preco_base_custo limit 5
  loop
    j := public.calcular_preco(r.sku, 1, '{}'::jsonb);
    continue when not coalesce((j ->> 'ok')::boolean, false);
    v_existe := v_existe or (v_qtd is not null and r.quantidade = v_qtd);
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object(
      'sku', r.sku, 'descricao_curta', concat_ws(' ', initcap(lower(r.categoria)), r.descricao, r.cores, r.tamanho_mm),
      'quantidade', r.quantidade, 'prazo_dias_uteis', r.prazo_dias_uteis, 'preco', (j ->> 'preco_total')::numeric, 'vendavel', r.vendavel,
      'quantidade_exata', v_qtd is not null and r.quantidade = v_qtd));
  end loop;

  -- o que falta perguntar
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
    'oferecer_mais_proxima', v_qtd is not null and not v_existe and jsonb_array_length(v_opcoes) > 0,
    'pergunta_qualificacao', case when jsonb_array_length(v_opcoes) = 0 or v_familias > 1 or v_qtd is null then v_pergunta end,
    'itens_sem_sku_encontrados', v_sem_sku,
    'orientacao', case when jsonb_array_length(v_opcoes) = 0 then case when v_sem_sku > 0 then 'sem_sku_chamar_dono_alta' else 'nao_encontrado_chamar_dono_alta' end end);
end;
$$;
revoke execute on function public.buscar_produto(text, integer, jsonb) from public, anon;
grant execute on function public.buscar_produto(text, integer, jsonb) to authenticated, service_role;

-- Preço para o agente: só o valor final. Piso, lucro e margem ficam em calcular_preco, de uso interno.
create or replace function public.agente_preco(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare j jsonb;
begin
  if not private.atendente_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  j := public.calcular_preco(p_sku, p_quantidade, p_contexto);
  if not coalesce((j ->> 'ok')::boolean, false) then return jsonb_build_object('ok', false, 'erro', j ->> 'erro'); end if;
  return jsonb_build_object('ok', true, 'sku', p_sku, 'quantidade', j -> 'quantidade', 'preco_unitario', j -> 'preco_unitario', 'preco_total', j -> 'preco_total');
end;
$$;
revoke execute on function public.agente_preco(text, integer, jsonb) from public, anon;
grant execute on function public.agente_preco(text, integer, jsonb) to authenticated, service_role;
