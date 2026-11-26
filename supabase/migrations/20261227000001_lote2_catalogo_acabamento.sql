-- Lote 2 da Auditoria 360 (26/11/2026): sinônimos populares, acabamento por ficha e prefixo, SKUs gêmeos e anúncio determinístico.
-- Itens #3, #4 e #5. Não altera preço de tabela nem a vitrine. Aditiva e idempotente.
-- Casos: Giovanna (ROLLUP001 x COM0013), Carlos Henrique (CVL1000 / verniz localizado), cliente da raspadinha, Alex Caldeira (Hot Stamping).

-- =====================================================================================
-- 1) Nomes populares (sinônimos) e substituição canônica antes da busca
-- =====================================================================================
insert into public.sinonimos (grupo, termo, origem)
select v.grupo, v.termo, 'manual' from (values
  ('cartao premiado', 'raspadinha'), ('cartao premiado', 'cartao premiado'), ('cartao premiado', 'cartao raspadinha'),
  ('cracha', 'carteirinha'),
  ('placa', 'plaquinha'), ('placa', 'placa'),
  ('panfleto', 'santinho'),
  ('cartao de visita', 'cartao de apresentacao')
) as v(grupo, termo)
where not exists (select 1 from public.sinonimos s where s.grupo = v.grupo and s.termo = v.termo);

-- A busca só enxerga a categoria quando o nome oficial aparece no texto (ex.: "raspadinha" não casa com CARTÃO PREMIADO).
-- Estes regex trocam o nome popular pelo oficial ANTES da busca (a ordem importa; `exige` limita a troca ao contexto).
create table if not exists public.sinonimos_canonicos (
  ordem integer primary key,
  padrao text not null,
  canonico text not null,
  exige text,
  nota text
);
alter table public.sinonimos_canonicos enable row level security;
revoke all on public.sinonimos_canonicos from anon, authenticated;

insert into public.sinonimos_canonicos (ordem, padrao, canonico, exige, nota) values
  (10, '\mcart(ao|oes)\s+raspadinhas?\M', 'cartao premiado', null, 'raspadinha: cartão premiado (RASP*)'),
  (11, '\mraspadinhas?\M', 'cartao premiado', null, 'raspadinha: cartão premiado (RASP*)'),
  (20, '\mcarteirinhas?\M', 'cracha', null, 'carteirinha: crachá / cartão PVC'),
  (30, '\mplaquinhas?\M', 'placa', null, 'plaquinha: placa'),
  (40, '\msantinhos?\M', 'panfleto', null, 'santinho: panfleto'),
  (50, '\mcart(ao|oes)\s+de\s+apresentacao\M', 'cartao de visita', null, 'cartão de apresentação: cartão de visita'),
  (60, '\mroll[ -]?ups?\M', 'roll up', null, 'rollup, roll-up: roll up'),
  (61, '\m(estrutura|kit)\s+complet[ao]\M', '', '\mroll up\M', '"estrutura completa" não aparece no cadastro; o rótulo do kit diferencia na resposta')
on conflict (ordem) do update set padrao = excluded.padrao, canonico = excluded.canonico, exige = excluded.exige, nota = excluded.nota;

create or replace function private.buscar_termo_canonico(p_norm text)
 returns text language plpgsql stable set search_path to ''
as $f$
declare v text := coalesce(p_norm, ''); s record;
begin
  for s in select padrao, canonico, exige from public.sinonimos_canonicos order by ordem loop
    if s.exige is null or v ~ s.exige then v := regexp_replace(v, s.padrao, s.canonico, 'g'); end if;
  end loop;
  return btrim(regexp_replace(v, '\s+', ' ', 'g'));
end;
$f$;

-- =====================================================================================
-- 2) Acabamento por SKU: ficha técnica pública + prefixos (CVL, CHVL, GVLF, CLF, CFHF, CFV, SOFT...)
-- =====================================================================================
create table if not exists public.acabamento_tags (
  tag text primary key,
  rotulo text not null,
  regex text not null,            -- texto normalizado (sem acento, minúsculo): serve para a ficha e para o pedido do cliente
  usar_em_anuncio boolean not null default false
);
alter table public.acabamento_tags enable row level security;
revoke all on public.acabamento_tags from anon, authenticated;

insert into public.acabamento_tags (tag, rotulo, regex, usar_em_anuncio) values
  ('verniz_localizado', 'verniz localizado', 'verniz\s+local|brilho\s+especial|uv\s+localizad|verniz\s+parcial', true),
  ('verniz_total', 'verniz total (UV)', 'verniz\s+(brilhante|uv|total)|uv\s+total', false),
  ('hot_stamping', 'hot stamping', 'hot\s*stamp', true),
  ('laminacao_fosca', 'laminação fosca', 'lam(inacao|\.)?\s+fosca|pelicula\s+fosca|toque\s+aveludado|laminado\s+fosc', false),
  ('laminacao_brilho', 'laminação brilho', 'lam(inacao|\.)?\s+brilho|pelicula\s+(protetora\s+)?(com\s+)?brilho|laminado\s+brilho', false),
  ('soft_touch', 'soft touch', 'soft\s*touch', true),
  ('holografica', 'laminação holográfica', 'holograf', true),
  ('tinta_branca', 'tinta branca', '(?<!sem\s)tinta\s+branca', false),
  ('corte_especial', 'corte especial', 'corte\s+especial|bordas?\s+arredondad|cantos?\s+(redondos|arredondados)|corte\s+personalizado|faca\s+especial', false)
on conflict (tag) do update set rotulo = excluded.rotulo, regex = excluded.regex, usar_em_anuncio = excluded.usar_em_anuncio;

create table if not exists public.catalogo_acabamento (
  sku text primary key,
  tags text[] not null default '{}',
  rotulo text,
  fonte text not null default 'ficha',
  atualizado_em timestamptz not null default now()
);
create index if not exists catalogo_acabamento_tags_idx on public.catalogo_acabamento using gin (tags);
alter table public.catalogo_acabamento enable row level security;
revoke all on public.catalogo_acabamento from anon, authenticated;

-- Prefixos conhecidos (confirmados na ficha de cada grupo); valem quando a ficha não diz o acabamento.
create table if not exists public.acabamento_prefixos (
  prefixo text primary key,
  tags text[] not null,
  nota text
);
alter table public.acabamento_prefixos enable row level security;
revoke all on public.acabamento_prefixos from anon, authenticated;
insert into public.acabamento_prefixos (prefixo, tags, nota) values
  ('CVL',  array['verniz_localizado', 'verniz_localizado_fv'], 'cartão de visita com verniz localizado frente e verso (ficha: "Brilho Especial nos Detalhes Frente e Verso")'),
  ('CHVL', array['hot_stamping', 'laminacao_fosca', 'verniz_localizado', 'verniz_localizado_v'], 'hot stamping na frente, laminação fosca e verniz localizado no verso'),
  ('GVLF', array['laminacao_fosca', 'verniz_localizado', 'verniz_localizado_f'], 'laminação fosca e verniz localizado só na frente'),
  ('CFHF', array['hot_stamping', 'laminacao_fosca'], 'hot stamping na frente com laminação fosca'),
  ('CLF',  array['laminacao_fosca'], 'laminação fosca frente e verso'),
  ('CFV',  array['verniz_total'], 'verniz brilhante frente e verso'),
  ('SOFT', array['soft_touch'], 'laminação soft touch')
on conflict (prefixo) do update set tags = excluded.tags, nota = excluded.nota;

create or replace function private.acabamento_tags_de(p_texto text, p_titulo text)
 returns text[] language plpgsql stable set search_path to ''
as $f$
declare v text[] := '{}'; t record;
begin
  for t in select tag, regex from public.acabamento_tags order by tag loop
    if p_texto ~ t.regex then v := array_append(v, t.tag); end if;
  end loop;
  if 'verniz_localizado' = any (v) then
    if p_titulo ~ '(detalhes\w*|verniz\s+local\w*)\s+(na\s+)?frente\s+e\s+(no\s+)?verso' then v := array_append(v, 'verniz_localizado_fv');
    elsif p_titulo ~ '(detalhes\w*|verniz\s+local\w*)\s+(no\s+)?verso|verniz\s+local\s+vr' then v := array_append(v, 'verniz_localizado_v');
    elsif p_titulo ~ '(detalhes\w*|verniz\s+local\w*)\s+(na\s+)?frente|verniz\s+local\w*\s+(apenas|so)' then v := array_append(v, 'verniz_localizado_f');
    end if;
  end if;
  if cardinality(v) = 0 and p_texto ~ 'sem\s+(acabamento|laminacao|verniz)' then v := array['sem_acabamento']; end if;
  return v;
end;
$f$;

create or replace function private.acabamento_rotulo(p_tags text[])
 returns text language sql immutable set search_path to ''
as $f$
  select nullif(array_to_string(array_remove(array[
    case when 'verniz_localizado_fv' = any (p_tags) then 'verniz localizado frente e verso'
         when 'verniz_localizado_f' = any (p_tags) then 'verniz localizado só na frente'
         when 'verniz_localizado_v' = any (p_tags) then 'verniz localizado só no verso'
         when 'verniz_localizado' = any (p_tags) then 'verniz localizado' end,
    case when 'hot_stamping' = any (p_tags) then 'hot stamping' end,
    case when 'laminacao_fosca' = any (p_tags) then 'laminação fosca' end,
    case when 'laminacao_brilho' = any (p_tags) then 'laminação brilho' end,
    case when 'soft_touch' = any (p_tags) then 'soft touch' end,
    case when 'holografica' = any (p_tags) then 'laminação holográfica' end,
    case when 'verniz_total' = any (p_tags) then 'verniz total (UV)' end,
    case when 'tinta_branca' = any (p_tags) then 'tinta branca' end,
    case when 'corte_especial' = any (p_tags) then 'corte especial' end
  ], null), ' + '), '');
$f$;

-- SKUs gêmeos: mesmo nome, tamanho, quantidade e cores, com preço 2x ou mais diferente (ex.: lona avulsa x kit completo).
create table if not exists public.catalogo_gemeos (
  sku text primary key,
  grupo text not null,
  titulos_distintos boolean not null
);
alter table public.catalogo_gemeos enable row level security;
revoke all on public.catalogo_gemeos from anon, authenticated;

-- Rótulos manuais para os gêmeos críticos (prevalecem sobre o título da ficha).
create table if not exists public.catalogo_diferencial (
  sku text primary key,
  rotulo text not null,
  nota text
);
alter table public.catalogo_diferencial enable row level security;
revoke all on public.catalogo_diferencial from anon, authenticated;
insert into public.catalogo_diferencial (sku, rotulo, nota) values
  ('COM0013', 'SÓ A LONA / REFIL, SEM ESTRUTURA', 'Roll Up avulso: caso Giovanna (25/11), a Laura citou como estrutura completa'),
  ('ROLLUP001', 'KIT COMPLETO: ESTRUTURA + LONA', 'Roll Up kit completo'),
  ('ROLLUP002', 'KIT COMPLETO: ESTRUTURA + LONA', 'Roll Up kit completo'),
  ('ROLLUP003', 'KIT COMPLETO: ESTRUTURA + LONA', 'Roll Up kit completo'),
  ('ROLLUP004', 'KIT COMPLETO: ESTRUTURA + LONA', 'Roll Up kit completo'),
  ('ROLLUP005', 'SÓ A ESTRUTURA (SUPORTE), SEM LONA', 'Roll Up suporte individual'),
  ('ROLLUP006', 'SÓ A ESTRUTURA (SUPORTE), SEM LONA', 'Roll Up suporte individual'),
  ('ROLLUP007', 'SÓ A ESTRUTURA (SUPORTE), SEM LONA', 'Roll Up suporte individual'),
  ('ROLLUP008', 'SÓ A ESTRUTURA (SUPORTE), SEM LONA', 'Roll Up suporte individual')
on conflict (sku) do update set rotulo = excluded.rotulo, nota = excluded.nota;

-- Recalcula acabamento e gêmeos (idempotente). Roda na migration e a cada 6 h (vitrine e planilha mudam).
create or replace function private.catalogo_acabamento_atualizar()
 returns jsonb language plpgsql security definer set search_path to ''
as $f$
declare v_aca int; v_gem int;
begin
  insert into public.catalogo_acabamento (sku, tags, rotulo, fonte, atualizado_em)
  select x.sku, x.tags, private.acabamento_rotulo(x.tags), x.fonte, now()
    from (
      select c.sku,
             case when p.tags is not null and cardinality(f.tags) = 0 then p.tags
                  else (select coalesce(array_agg(distinct t), '{}') from unnest(f.tags || coalesce(p.tags, '{}')) t) end as tags,
             case when p.tags is not null and cardinality(f.tags) = 0 then 'prefixo' when p.tags is not null then 'ficha+prefixo' else 'ficha' end as fonte
        from public.catalogo c
        left join public.ecommerce_products ep on ep.sku = c.sku
        left join lateral (select ap.tags from public.acabamento_prefixos ap where c.sku ~ ('^' || ap.prefixo || '[0-9]') order by length(ap.prefixo) desc limit 1) p on true
        cross join lateral (select private.acabamento_tags_de(
            btrim(regexp_replace(lower(extensions.unaccent(coalesce(ep.titulo, '') || ' ' || coalesce(ep.ficha ->> 'material', '') || ' ' || coalesce(ep.ficha ->> 'acabamento', '') || ' ' || coalesce(ep.ficha ->> 'observacoes', ''))), '[^a-z0-9]+', ' ', 'g')),
            btrim(regexp_replace(lower(extensions.unaccent(coalesce(ep.titulo, ''))), '[^a-z0-9]+', ' ', 'g'))) as tags) f
    ) x
  on conflict (sku) do update set tags = excluded.tags, rotulo = excluded.rotulo, fonte = excluded.fonte, atualizado_em = now();
  get diagnostics v_aca = row_count;

  delete from public.catalogo_gemeos;
  insert into public.catalogo_gemeos (sku, grupo, titulos_distintos)
  select c.sku, g.grupo, g.distintos
    from public.catalogo c
    join (
      select c2.categoria, c2.descricao, c2.tamanho_mm, c2.quantidade, c2.cores,
             md5(concat_ws('|', c2.categoria, c2.descricao, c2.tamanho_mm, c2.quantidade::text, c2.cores)) as grupo,
             (count(distinct e2.titulo) = count(*)) as distintos
        from public.catalogo c2 left join public.ecommerce_products e2 on e2.sku = c2.sku
       where c2.status_venda = 'vender' and c2.preco_venda is not null
       group by c2.categoria, c2.descricao, c2.tamanho_mm, c2.quantidade, c2.cores
      having count(*) > 1 and max(c2.preco_venda) / nullif(min(c2.preco_venda), 0) >= 2
    ) g on c.categoria is not distinct from g.categoria and c.descricao is not distinct from g.descricao and c.tamanho_mm is not distinct from g.tamanho_mm
       and c.quantidade is not distinct from g.quantidade and c.cores is not distinct from g.cores
   where c.status_venda = 'vender' and c.preco_venda is not null;
  get diagnostics v_gem = row_count;
  return jsonb_build_object('acabamentos', v_aca, 'gemeos', v_gem);
end;
$f$;
revoke execute on function private.catalogo_acabamento_atualizar() from public, anon, authenticated;

-- =====================================================================================
-- 3) buscar_produto: o original vira private.buscar_produto_base (com filtro de acabamento) e o público é o embrulho
-- =====================================================================================
do $do$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'private' and p.proname = 'buscar_produto_base') then
    return; -- já migrado
  end if;
  alter function public.buscar_produto(text, integer, jsonb) set schema private;
  alter function private.buscar_produto(text, integer, jsonb) rename to buscar_produto_base;
end $do$;

do $do$
declare
  v_def text;
  v_a_old text := 'v_exact boolean := false; v_maxscore numeric := 0;';
  v_a_new text := 'v_exact boolean := false; v_maxscore numeric := 0; v_acab text[] := null; /* acabamento_filtro */';
  v_b_old text := $o$if length(v_norm) < 2 then return jsonb_build_object('ok', false, 'erro', 'termo_vazio'); end if;$o$;
  v_b_new text := $n$if length(v_norm) < 2 then return jsonb_build_object('ok', false, 'erro', 'termo_vazio'); end if;
  if jsonb_typeof(p_filtros -> 'acabamento_tags') = 'array' then v_acab := array(select jsonb_array_elements_text(p_filtros -> 'acabamento_tags')); if cardinality(v_acab) = 0 then v_acab := null; end if; end if;$n$;
  v_c_old text := $o$ and (v_gram is null or c.gramatura_g = v_gram)$o$;
  v_c_new text := $n$ and (v_gram is null or c.gramatura_g = v_gram) and (v_acab is null or exists (select 1 from public.catalogo_acabamento ca where ca.sku = c.sku and ca.tags @> v_acab))$n$;
begin
  select pg_get_functiondef('private.buscar_produto_base(text, integer, jsonb)'::regprocedure) into v_def;
  if position('acabamento_filtro' in v_def) > 0 then return; end if;
  if position(v_a_old in v_def) = 0 or position(v_b_old in v_def) = 0 or position(v_c_old in v_def) = 0 then raise exception 'buscar_produto_base: trechos esperados não encontrados'; end if;
  v_def := replace(replace(replace(v_def, v_a_old, v_a_new), v_b_old, v_b_new), v_c_old, v_c_new);
  execute v_def;
end $do$;
revoke execute on function private.buscar_produto_base(text, integer, jsonb) from public, anon, authenticated;

-- Acrescenta acabamento, título da ficha e diferencial (gêmeos) a uma opção.
create or replace function private.buscar_enriquecer_opcao(o jsonb)
 returns jsonb language plpgsql stable set search_path to ''
as $f$
declare d record; v_dif text; v_sku text := o ->> 'sku';
begin
  if v_sku is null then return o; end if;
  select ca.tags, ca.rotulo as acab, ep.titulo, ep.variante, ov.rotulo as ov, g.titulos_distintos, (g.sku is not null) as gem
    into d
    from (select 1) x
    left join public.catalogo_acabamento ca on ca.sku = v_sku
    left join public.ecommerce_products ep on ep.sku = v_sku
    left join public.catalogo_diferencial ov on ov.sku = v_sku
    left join public.catalogo_gemeos g on g.sku = v_sku;
  v_dif := coalesce(d.ov, case when coalesce(d.gem, false) then case when d.titulos_distintos then left(d.titulo, 110) else d.variante end end, d.acab);
  return o
    || jsonb_strip_nulls(jsonb_build_object('acabamento', d.acab, 'titulo_produto', left(d.titulo, 140), 'diferencial', v_dif, 'sku_gemeo', case when coalesce(d.gem, false) then true end))
    || case when v_dif is not null and coalesce(o ->> 'descricao_curta', '') not ilike '%' || v_dif || '%'
            then jsonb_build_object('descricao_curta', (o ->> 'descricao_curta') || ' [' || v_dif || ']') else '{}'::jsonb end;
end;
$f$;

create or replace function public.buscar_produto(p_termo text, p_quantidade integer default null, p_filtros jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_filtros jsonb := case when jsonb_typeof(p_filtros) = 'object' then p_filtros else '{}'::jsonb end;
  v_norm text; v_canon text; v_limpo text; t record;
  v_exp text[] := '{}'; v_ad text[] := '{}'; v_tags text[]; v_tags1 text[]; v_origem text := 'termo';
  v_fv boolean; v_ref text; v_conv uuid; r jsonb; v_nao boolean := false; v_lado boolean := false; v_rot text; v_gem boolean := false;
  v_ops jsonb;
begin
  if not private.atendente_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  -- busca por SKU exato: não mexe
  if p_termo is not null and exists (select 1 from public.catalogo c where c.sku = upper(btrim(p_termo))) then
    return private.buscar_produto_base(p_termo, p_quantidade, v_filtros);
  end if;
  v_norm := private.norm_busca(p_termo);
  v_canon := private.buscar_termo_canonico(v_norm);

  -- acabamentos pedidos no texto ou no filtro "acabamento"
  select coalesce(array_agg(a.tag order by a.tag), '{}') into v_exp from public.acabamento_tags a where v_canon ~ a.regex;
  if nullif(btrim(v_filtros ->> 'acabamento'), '') is not null then
    v_exp := array(select distinct u from unnest(v_exp || coalesce(array(select a.tag from public.acabamento_tags a where private.norm_busca(v_filtros ->> 'acabamento') ~ a.regex or a.tag = lower(btrim(v_filtros ->> 'acabamento'))), '{}')) u);
    if cardinality(v_exp) > 0 and not (v_canon ~ any (array(select a.regex from public.acabamento_tags a where a.tag = any (v_exp)))) then v_origem := 'filtro'; end if;
  end if;

  -- acabamento do ANÚNCIO de origem da conversa (determinístico: não depende do prompt)
  if cardinality(v_exp) = 0 and (v_filtros ->> 'conversation_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_conv := (v_filtros ->> 'conversation_id')::uuid;
    select private.norm_busca(coalesce(cv.last_referral::text, '') || ' ' || coalesce(ct.first_referral::text, '')) into v_ref
      from public.conversations cv join public.contacts ct on ct.id = cv.contact_id where cv.id = v_conv;
    if v_ref is not null then
      select coalesce(array_agg(a.tag order by a.tag), '{}') into v_ad from public.acabamento_tags a where a.usar_em_anuncio and v_ref ~ a.regex;
      if cardinality(v_ad) > 0 then v_exp := v_ad; v_origem := 'anuncio'; end if;
    end if;
  end if;

  if cardinality(v_exp) = 0 then
    r := private.buscar_produto_base(v_canon, p_quantidade, v_filtros - 'conversation_id');
  else
    v_tags := v_exp;
    -- termo sem as palavras do acabamento (a busca procura o produto; o acabamento filtra pelo cadastro)
    v_limpo := v_canon;
    for t in select a.regex from public.acabamento_tags a where a.tag = any (v_exp) loop
      v_limpo := regexp_replace(v_limpo, t.regex, ' ', 'g');
    end loop;
    v_limpo := btrim(regexp_replace(v_limpo, '\s+', ' ', 'g'));
    if length(v_limpo) < 2 then v_limpo := 'cartao de visita'; end if;
    v_fv := v_canon ~ '(frente e verso|frente verso|dois lados|2 lados|ambos os lados|(^| )4 ?x ?4( |$))';
    v_tags1 := case when 'verniz_localizado' = any (v_tags) and v_fv then array_replace(v_tags, 'verniz_localizado', 'verniz_localizado_fv') else v_tags end;
    r := private.buscar_produto_base(v_limpo, p_quantidade, (v_filtros - 'conversation_id') || jsonb_build_object('acabamento_tags', to_jsonb(v_tags1)));
    if jsonb_array_length(coalesce(r -> 'opcoes', '[]'::jsonb)) = 0 and v_tags1 <> v_tags then
      r := private.buscar_produto_base(v_limpo, p_quantidade, (v_filtros - 'conversation_id') || jsonb_build_object('acabamento_tags', to_jsonb(v_tags)));
      v_lado := jsonb_array_length(coalesce(r -> 'opcoes', '[]'::jsonb)) > 0;
    end if;
    if jsonb_array_length(coalesce(r -> 'opcoes', '[]'::jsonb)) = 0 then
      r := private.buscar_produto_base(v_limpo, p_quantidade, v_filtros - 'conversation_id');
      v_nao := true;
    end if;
    select string_agg(a.rotulo, ' + ' order by a.tag) into v_rot from public.acabamento_tags a where a.tag = any (v_tags);
    r := r || jsonb_build_object('acabamento_pedido', v_rot, 'acabamento_origem', v_origem, 'acabamento_aplicado', not v_nao,
      'acabamento_nao_encontrado', v_nao and v_origem <> 'anuncio');
    if v_nao and v_origem <> 'anuncio' then
      r := r || jsonb_build_object('orientacao_acabamento',
        'O cliente pediu ' || v_rot || ' e NENHUMA opção deste catálogo para esse produto tem esse acabamento. Diga isso com clareza ("não encontrei ' || v_rot || ' nesse produto"). NUNCA diga "hoje só trabalhamos com..." e NUNCA apresente as opções abaixo como se tivessem o acabamento pedido. Se oferecer alternativa, avise que ela NÃO tem ' || v_rot || ' e pergunte se o cliente aceita; se ele insistir, chame o dono (chamar_dono).');
    elsif v_nao then
      r := r || jsonb_build_object('acabamento_anuncio_ignorado', true);
    elsif v_origem = 'anuncio' then
      r := r || jsonb_build_object('orientacao_acabamento', 'O cliente veio do anúncio de ' || v_rot || ': todas as opções abaixo têm esse acabamento. Ofereça-as primeiro; só mostre uma sem o acabamento se ele achar caro, avisando que não tem.');
    else
      r := r || jsonb_build_object('orientacao_acabamento', 'Todas as opções abaixo têm ' || v_rot || (case when v_lado then '. ATENÇÃO: o lado pedido (frente e verso) não existe com esse acabamento: confira o campo acabamento de cada opção (só na frente ou só no verso) e avise o cliente' else '' end) || '.');
    end if;
  end if;

  -- enriquece cada opção (acabamento, título da ficha e diferencial dos SKUs gêmeos)
  if jsonb_typeof(r -> 'opcoes') = 'array' and jsonb_array_length(r -> 'opcoes') > 0 then
    select coalesce(jsonb_agg(private.buscar_enriquecer_opcao(x.o) order by x.ord), '[]'::jsonb) into v_ops from jsonb_array_elements(r -> 'opcoes') with ordinality x(o, ord);
    r := jsonb_set(r, '{opcoes}', v_ops);
    select bool_or(coalesce((e ->> 'sku_gemeo')::boolean, false)) into v_gem from jsonb_array_elements(v_ops) e;
    if coalesce(v_gem, false) then
      r := r || jsonb_build_object('orientacao_gemeos', 'Há produtos com o MESMO nome e preços muito diferentes (veja o campo diferencial de cada opção). Cite o preço exato do SKU que será orçado e a diferença só pelo campo diferencial; nunca troque um pelo outro nem descreva um como se fosse o outro.');
    end if;
  end if;
  if jsonb_typeof(r -> 'alternativa_lote_maior') = 'object' then
    r := jsonb_set(r, '{alternativa_lote_maior}', private.buscar_enriquecer_opcao(r -> 'alternativa_lote_maior'));
  end if;
  return r;
end;
$function$;
revoke execute on function public.buscar_produto(text, integer, jsonb) from public, anon;
grant execute on function public.buscar_produto(text, integer, jsonb) to authenticated, service_role;

-- =====================================================================================
-- 4) Carga inicial e atualização periódica
-- =====================================================================================
select private.catalogo_acabamento_atualizar();

do $do$
begin
  begin perform cron.unschedule('catalogo-acabamento'); exception when others then null; end;
  perform cron.schedule('catalogo-acabamento', '13 */6 * * *', 'select private.catalogo_acabamento_atualizar()');
end $do$;
