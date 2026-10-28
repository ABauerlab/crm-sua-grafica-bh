-- Agente de IA, Etapa 2 (1/3): catálogo do fornecedor com SKU, histórico e importação em duas fases (pré-visualização e confirmação).
-- Estende a tabela que o CRM já tinha (products, 20 mil itens): ela passa a se chamar catalogo, com os nomes de coluna do projeto.
-- products continua existindo como VISÃO de compatibilidade (as funções da Etapa 1 e telas antigas leem por ela); sai na Etapa 8.
-- Aditiva e idempotente. Nenhum dado é apagado: todas as linhas importadas continuam, agora com SKU, status de venda e flags.

-- ---------------------------------------------------------------- 1. products -> catalogo
do $$
begin
  if to_regclass('public.catalogo') is null and to_regclass('public.products') is not null then
    alter table public.products rename to catalogo;
  end if;
end $$;

do $$
declare r record;
begin
  for r in select * from (values
      ('code', 'sku'), ('description', 'descricao'), ('category', 'categoria'), ('cost', 'custo'), ('colors', 'cores'),
      ('weight', 'peso_g'), ('qty', 'quantidade'), ('size', 'tamanho_mm'), ('lead_days', 'prazo_dias_uteis'),
      ('grammage', 'gramatura_g'), ('suggested_price', 'preco_base_custo')) v (de, para) loop
    if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'catalogo' and column_name = r.de)
       and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'catalogo' and column_name = r.para) then
      execute format('alter table public.catalogo rename column %I to %I', r.de, r.para);
    end if;
  end loop;
end $$;

drop view if exists public.products_priced;
drop view if exists public.product_categories;

-- SKU pode ser nulo (linhas do PDF sem código entram como sem_sku); quando existe, é único
alter table public.catalogo alter column sku drop not null;
do $$ begin
  if exists (select 1 from pg_constraint where conname = 'products_code_key') then
    alter table public.catalogo rename constraint products_code_key to catalogo_sku_key;
  end if;
end $$;
alter index if exists products_description_trgm rename to catalogo_descricao_trgm;
alter index if exists products_category_idx rename to catalogo_categoria_idx;
alter index if exists products_qty_idx rename to catalogo_quantidade_idx;

comment on column public.catalogo.sku is 'Código do fornecedor. Identifica o item EXATO, incluindo a quantidade (CFV02 = 1.000, CFV02D = 2.000). INTERNO: nunca vai ao cliente.';
comment on column public.catalogo.custo is 'Custo bruto do fornecedor. PRIVADO: só o dono e as funções do servidor leem. Nunca vai ao agente.';
comment on column public.catalogo.peso_g is 'Peso do pacote da opção, em gramas.';
comment on column public.catalogo.tamanho_mm is 'Tamanho em milímetros, como vem na tabela (ex.: 91 x 51). 0 x 0 = desconhecido.';
comment on column public.catalogo.prazo_dias_uteis is 'Prazo BRUTO do fornecedor em dias úteis. O +1 de logística só entra em calcular_prazo.';
comment on column public.catalogo.preco_base_custo is 'Referência interna: custo x multiplicador da faixa, terminado em ,90. SEM pesquisa de mercado. NUNCA vale para orçamento, PDF ou link: o preço válido é calcular_preco.';

-- ---------------------------------------------------------------- 2. colunas novas
alter table public.catalogo add column if not exists grupo_produto text;
alter table public.catalogo add column if not exists especificacao_normalizada text;
alter table public.catalogo add column if not exists status_venda text not null default 'vender';
alter table public.catalogo add column if not exists vendavel boolean not null default true;
alter table public.catalogo add column if not exists cabe_na_bike boolean;
alter table public.catalogo add column if not exists maior_lado_mm integer;
alter table public.catalogo add column if not exists piso numeric(12, 2);
alter table public.catalogo add column if not exists piso_duro numeric(12, 2);
alter table public.catalogo add column if not exists chave_natural text;
alter table public.catalogo add column if not exists origem_importacao_id uuid;
alter table public.catalogo add column if not exists atualizado_em timestamptz not null default now();

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'catalogo_status_venda_check') then
    alter table public.catalogo add constraint catalogo_status_venda_check
      check (status_venda in ('vender_forte', 'vender', 'so_sob_demanda', 'nao_competitivo', 'nao_vender', 'sem_sku'));
  end if;
  -- sem SKU não se vende; status sem_sku nunca é vendável
  if not exists (select 1 from pg_constraint where conname = 'catalogo_sku_vendavel_check') then
    alter table public.catalogo add constraint catalogo_sku_vendavel_check
      check ((sku is not null or (status_venda = 'sem_sku' and not vendavel)) and (status_venda <> 'sem_sku' or not vendavel));
  end if;
end $$;

create unique index if not exists catalogo_chave_natural_uq on public.catalogo (chave_natural) where sku is null;
create index if not exists catalogo_status_idx on public.catalogo (status_venda) where status_venda <> 'vender';
create index if not exists catalogo_grupo_idx on public.catalogo (grupo_produto);
create index if not exists catalogo_espec_trgm on public.catalogo using gin (especificacao_normalizada extensions.gin_trgm_ops);
create index if not exists catalogo_espec_fts on public.catalogo using gin (to_tsvector('simple', coalesce(especificacao_normalizada, '')));
create index if not exists catalogo_sku_trgm on public.catalogo using gin (sku extensions.gin_trgm_ops);

-- ---------------------------------------------------------------- 3. regras por linha (trigger)
-- Maior lado em mm a partir de "91 x 51"; zero ou texto sem número = desconhecido (null)
create or replace function private.maior_lado_mm(p_tam text) returns integer
language sql immutable set search_path = ''
as $$
  select nullif(max(ceil(replace(m[1], ',', '.')::numeric))::integer, 0)
  from regexp_matches(coalesce(p_tam, ''), '\d+(?:[.,]\d+)?', 'g') as m;
$$;

-- Texto de busca: sem acento, minúsculo, só letras e números, plural simples removido ("cartões" e "cartão" viram "cartao")
create or replace function private.norm_busca(p text) returns text
language sql immutable set search_path = ''
as $$
  select coalesce(string_agg(
    case
      when length(w) > 4 and w ~ '(oes|aes)$' then regexp_replace(w, '(oes|aes)$', 'ao')
      when length(w) > 4 and w ~ 'ais$' then regexp_replace(w, 'ais$', 'al')
      when length(w) > 3 and w ~ '[^s]s$' then left(w, length(w) - 1)
      else w end, ' ' order by o), '')
  from regexp_split_to_table(regexp_replace(private.norm_txt(p), '(\d)[.,](\d{3})\M', '\1\2', 'g'), '[^a-z0-9]+') with ordinality as t (w, o)
  where w <> '';
$$;

create or replace function private.catalogo_antes() returns trigger
language plpgsql set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_extra numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  new.sku := nullif(btrim(new.sku), '');
  if new.sku is null then
    new.status_venda := 'sem_sku';
    new.vendavel := false;
  elsif new.status_venda = 'sem_sku' and tg_op = 'UPDATE' then
    -- ganhou SKU: sai de sem_sku
    new.status_venda := 'vender';
    new.vendavel := true;
  end if;
  if new.status_venda in ('sem_sku', 'nao_vender') then new.vendavel := false; end if;
  new.grupo_produto := coalesce(nullif(btrim(new.grupo_produto), ''), new.categoria);
  new.especificacao_normalizada := private.norm_busca(concat_ws(' ', new.categoria, new.descricao, new.cores, new.tamanho_mm,
    case when new.gramatura_g is not null then new.gramatura_g || 'g' end, new.quantidade));
  new.maior_lado_mm := private.maior_lado_mm(new.tamanho_mm);
  new.cabe_na_bike := case when coalesce(new.peso_g, 0) > 0 and new.maior_lado_mm is not null
    then new.peso_g <= pr.peso_max_bike_g and new.maior_lado_mm <= pr.lado_max_bike_mm end;
  if tg_op = 'INSERT' or new.custo is distinct from old.custo or new.piso is null then
    new.preco_base_custo := case when new.custo > 0 then private.arredonda_90(new.custo * private.multiplicador_faixa(new.custo)) else 0 end;
    if new.custo > 0 then
      v_extra := private.custos_operacionais(null);
      new.piso := ceil(greatest(new.custo * pr.multiplicador_piso, private.receita_para_lucro(new.custo, v_extra, pr.lucro_liquido_minimo, null)) * 100) / 100;
      new.piso_duro := private.receita_para_lucro(new.custo, v_extra, 0, null);
    else
      new.piso := null; new.piso_duro := null;
    end if;
  end if;
  new.atualizado_em := now();
  return new;
end;
$$;
revoke execute on function private.catalogo_antes() from public, anon, authenticated;
drop trigger if exists catalogo_antes on public.catalogo;
create trigger catalogo_antes before insert or update on public.catalogo
  for each row execute function private.catalogo_antes();

-- Preenche as linhas que já existiam (preço base, piso, piso duro, maior lado, cabe na bike, especificação normalizada)
update public.catalogo set piso = null where piso is null and custo > 0;
update public.catalogo set grupo_produto = grupo_produto where especificacao_normalizada is null;

-- Mudou a regra de bicicleta ou os parâmetros de preço: recalcula piso, piso duro e cabe_na_bike em lotes (a tela chama até acabar).
-- Paginação por id: devolve o último id processado; null quando terminou.
create or replace function public.catalogo_recalcular(p_depois uuid default null, p_limite integer default 2000)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ultimo uuid; v_n integer;
begin
  if not (private.is_staff() or auth.role() = 'service_role') then
    raise exception 'Só o dono recalcula o catálogo.' using errcode = '42501';
  end if;
  with lote as (
    select id from public.catalogo where p_depois is null or id > p_depois order by id limit p_limite
  ), up as (
    update public.catalogo c set piso = null from lote where c.id = lote.id returning c.id
  )
  select max(id::text)::uuid, count(*) into v_ultimo, v_n from up;
  return jsonb_build_object('processados', v_n, 'ultimo', case when v_n >= p_limite then v_ultimo end);
end;
$$;
revoke execute on function public.catalogo_recalcular(uuid, integer) from public, anon;

-- Mudança nos parâmetros da bicicleta: o dono é avisado na tela para recalcular (nada de varredura pesada dentro do UPDATE)
-- (a tela Configurações > Catálogo chama catalogo_recalcular em lotes)

-- ---------------------------------------------------------------- 4. histórico de preço e prazo
create table if not exists public.catalogo_historico (
  id uuid primary key default gen_random_uuid(),
  catalogo_id uuid not null references public.catalogo (id) on delete cascade,
  sku text,
  custo_anterior numeric(12, 2),
  custo_novo numeric(12, 2),
  prazo_anterior integer,
  prazo_novo integer,
  importacao_id uuid,
  registrado_em timestamptz not null default now()
);
create index if not exists catalogo_historico_item_idx on public.catalogo_historico (catalogo_id, registrado_em desc);

create or replace function private.catalogo_historico_grava() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.custo is distinct from old.custo or new.prazo_dias_uteis is distinct from old.prazo_dias_uteis then
    insert into public.catalogo_historico (catalogo_id, sku, custo_anterior, custo_novo, prazo_anterior, prazo_novo, importacao_id)
    values (new.id, new.sku, old.custo, new.custo, old.prazo_dias_uteis, new.prazo_dias_uteis, new.origem_importacao_id);
  end if;
  return null;
end;
$$;
revoke execute on function private.catalogo_historico_grava() from public, anon, authenticated;
drop trigger if exists catalogo_historico_grava on public.catalogo;
create trigger catalogo_historico_grava after update of custo, prazo_dias_uteis on public.catalogo
  for each row execute function private.catalogo_historico_grava();

-- ---------------------------------------------------------------- 5. importações (staging, relatório) e bucket privado
create table if not exists public.catalogo_importacoes (
  id uuid primary key default gen_random_uuid(),
  arquivo_nome text not null,
  arquivo_path text,
  arquivo_sha256 text,
  emitido_em date,
  status text not null default 'carregando' check (status in ('carregando', 'previa', 'aplicando', 'aplicada', 'cancelada')),
  linhas_candidatas integer,
  limite_alteracao_pct numeric(5, 1) not null default 20,
  relatorio jsonb not null default '{}'::jsonb,
  criado_por uuid default auth.uid(),
  criado_em timestamptz not null default now(),
  aplicado_em timestamptz
);

create table if not exists public.catalogo_import_linhas (
  importacao_id uuid not null references public.catalogo_importacoes (id) on delete cascade,
  n integer not null,
  sku text,
  categoria text,
  descricao text,
  cores text,
  peso_g numeric(12, 3),
  quantidade integer,
  tamanho_mm text,
  prazo_dias_uteis integer,
  custo numeric(12, 2),
  chave_natural text,
  resultado text not null default 'pendente' check (resultado in
    ('pendente', 'nova', 'alterada', 'igual', 'sem_sku_nova', 'sem_sku_igual', 'sem_sku_alterada', 'duplicada_igual', 'conflito', 'rejeitada', 'aplicada')),
  motivo text,
  custo_anterior numeric(12, 2),
  prazo_anterior integer,
  variacao_pct numeric(7, 1),
  acima_limite boolean not null default false,
  primary key (importacao_id, n)
);
create index if not exists catalogo_import_linhas_sku_idx on public.catalogo_import_linhas (importacao_id, sku);
create index if not exists catalogo_import_linhas_res_idx on public.catalogo_import_linhas (importacao_id, resultado);

-- Bucket PRIVADO com a tabela original do fornecedor (PDF). Só o dono lê e grava; ninguém mais, nem anon.
insert into storage.buckets (id, name, public) values ('catalogo-fornecedor', 'catalogo-fornecedor', false)
on conflict (id) do update set public = false;
drop policy if exists catalogo_storage_select on storage.objects;
create policy catalogo_storage_select on storage.objects for select to authenticated
  using (bucket_id = 'catalogo-fornecedor' and private.is_staff());
drop policy if exists catalogo_storage_insert on storage.objects;
create policy catalogo_storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'catalogo-fornecedor' and private.is_staff());
drop policy if exists catalogo_storage_delete on storage.objects;
create policy catalogo_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'catalogo-fornecedor' and private.is_staff());

-- RLS: SÓ o dono (private.is_staff = existe em profiles e é o e-mail do dono). anon e authenticated comuns não leem custo.
do $$
declare t text;
begin
  foreach t in array array['catalogo', 'catalogo_historico', 'catalogo_importacoes', 'catalogo_import_linhas'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('drop policy if exists %I on public.%I', t || '_dono', t);
    execute format('create policy %I on public.%I for all to authenticated using (private.is_staff()) with check (private.is_staff())', t || '_dono', t);
  end loop;
end $$;
-- a política antiga (por comando) da tabela renomeada já não é necessária
do $$
declare p text;
begin
  foreach p in array array['products_select', 'products_insert', 'products_update', 'products_delete'] loop
    execute format('drop policy if exists %I on public.catalogo', p);
  end loop;
end $$;

-- ---------------------------------------------------------------- 6. compatibilidade: products e products_priced (nomes antigos)
create or replace view public.products with (security_invoker = true) as
select id, sku as code, descricao as description, categoria as category, supplier, custo as cost, preco_base_custo as suggested_price,
       active, created_at, cores as colors, peso_g as weight, quantidade as qty, tamanho_mm as size, prazo_dias_uteis as lead_days,
       gramatura_g as grammage, permite_desconto
from public.catalogo;
revoke all on public.products from anon;

-- Linha do catálogo para o dono: o preço desta visão é a BASE DE CUSTO (referência, sem pesquisa). Preço de venda: calcular_preco.
create or replace view public.products_priced with (security_invoker = true) as
select id, sku as code, descricao as description, categoria as category, supplier, custo as cost, preco_base_custo as suggested_price,
       active, created_at, cores as colors, peso_g as weight, quantidade as qty, tamanho_mm as size, prazo_dias_uteis as lead_days,
       gramatura_g as grammage, permite_desconto,
       sku, descricao, categoria, custo, cores, peso_g, quantidade, tamanho_mm, prazo_dias_uteis, gramatura_g, preco_base_custo,
       grupo_produto, status_venda, vendavel, cabe_na_bike, maior_lado_mm, piso, piso_duro, atualizado_em,
       piso as floor_price,
       round(preco_base_custo * (1 - coalesce((select (value ->> 'max_discount_pct')::numeric from public.app_settings where key = 'pricing'), 10) / 100), 2) as max_discount_price,
       round(preco_base_custo * (1 - (select (pr.imposto_pct + 4.98) / 100 from public.parametros_comerciais pr where pr.id = 1)) - custo, 2) as est_net_profit
from public.catalogo;
revoke all on public.products_priced from anon;

create or replace view public.product_categories with (security_invoker = true) as
select categoria as category, count(*) as products
from public.catalogo
where active and categoria is not null
group by categoria;
revoke all on public.product_categories from anon;

-- Preço de venda das linhas de uma página (calcular_preco, uma chamada só). Devolve só o que o dono vê na tela do catálogo.
create or replace function public.catalogo_precos(p_skus text[])
returns table (sku text, preco_total numeric, regra text, confianca text, margem_liquida_pct numeric, nao_competitivo boolean)
language plpgsql stable security invoker set search_path = ''
as $$
declare s text; j jsonb;
begin
  foreach s in array coalesce(p_skus, '{}') loop
    j := public.calcular_preco(s, 1, '{}'::jsonb);
    if (j ->> 'ok')::boolean then
      sku := s; preco_total := (j ->> 'preco_total')::numeric; regra := j ->> 'regra'; confianca := j ->> 'confianca';
      margem_liquida_pct := (j ->> 'margem_liquida_pct')::numeric; nao_competitivo := (j ->> 'nao_competitivo')::boolean;
      return next;
    end if;
  end loop;
end;
$$;
revoke execute on function public.catalogo_precos(text[]) from public, anon;

-- ---------------------------------------------------------------- 7. mercado: invalidação por item
alter table public.precos_mercado add column if not exists invalidado_em timestamptz;

-- ---------------------------------------------------------------- 8. preço e frete leem o catálogo novo
-- calcular_preco: igual à Etapa 1, mais (a) recusa item não vendável e (b) ignora coletas invalidadas por mudança de custo
create or replace function public.calcular_preco(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  prod record;
  v_qtd integer := greatest(coalesce(p_quantidade, 1), 1);
  v_metodo text := p_contexto ->> 'metodo';
  v_outros_receita numeric := coalesce((p_contexto ->> 'receita_outros')::numeric, 0);
  v_outros_custo numeric := coalesce((p_contexto ->> 'custo_outros')::numeric, 0);
  v_custo_item numeric; v_custo_total numeric; v_extra numeric;
  v_base numeric; v_piso numeric; v_piso_duro numeric;
  v_mediana numeric; v_n integer; v_alvo numeric; v_preco numeric;
  v_regra text; v_conf text; v_nao_comp boolean := false;
  v_receita numeric; v_lucro numeric;
  v_avisos text[] := '{}';
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select c.custo, c.active, c.vendavel into prod from public.catalogo c where c.sku = p_sku;
  if not found or not prod.active then
    return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado');
  end if;
  if not prod.vendavel then
    return jsonb_build_object('ok', false, 'erro', 'item_nao_vendavel');
  end if;

  v_custo_item := prod.custo * v_qtd;
  v_custo_total := v_custo_item + v_outros_custo;
  v_extra := private.custos_operacionais(p_contexto ->> 'entrega');
  v_piso := ceil(greatest(v_custo_item * pr.multiplicador_piso,
                          private.receita_para_lucro(v_custo_total, v_extra, pr.lucro_liquido_minimo, v_metodo) - v_outros_receita) * 100) / 100;
  v_piso_duro := private.receita_para_lucro(v_custo_total, v_extra, 0, v_metodo) - v_outros_receita;
  v_base := private.arredonda_90(v_custo_item * private.multiplicador_faixa(v_custo_item));

  select percentile_cont(0.5) within group (order by m.preco), count(*)
    into v_mediana, v_n
  from public.precos_mercado m
  where m.sku = p_sku and not m.outlier and m.invalidado_em is null
    and m.coletado_em >= now() - make_interval(days => pr.idade_max_pesquisa_dias);

  if v_n >= 2 then
    v_alvo := private.arredonda_90(v_mediana * v_qtd * pr.fator_competitivo);
    v_regra := 'mercado';
    v_conf := case when v_n >= 3 then 'alta' else 'media' end;
  else
    v_alvo := v_base;
    v_regra := 'custo_x_multiplicador';
    v_conf := 'baixa';
  end if;

  if v_alvo >= v_piso then
    v_preco := v_alvo;
  else
    v_preco := private.teto_90(v_piso);
    v_regra := 'piso';
    v_nao_comp := v_n >= 2;
    if v_nao_comp then v_avisos := array_append(v_avisos, 'mercado_abaixo_do_piso'); end if;
  end if;

  v_receita := v_preco + v_outros_receita;
  v_lucro := private.lucro(v_receita, v_custo_total, v_extra, v_metodo);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku, 'quantidade', v_qtd,
    'preco_unitario', round(v_preco / v_qtd, 2), 'preco_total', v_preco,
    'regra', v_regra, 'confianca', v_conf,
    'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1), 'lucro_liquido', v_lucro,
    'piso', round(v_piso, 2), 'piso_duro', round(v_piso_duro, 2),
    'nao_competitivo', v_nao_comp, 'fontes_mercado', v_n, 'avisos', to_jsonb(v_avisos));
end;
$$;

-- verificar_frete: igual à Etapa 1, mas "0 x 0" e tamanho sem número contam como DESCONHECIDO (antes contavam como lado zero e davam frete grátis)
create or replace function public.verificar_frete(p_cep_ou_bairro text, p_itens jsonb default '[]'::jsonb, p_valor_pedido numeric default 0, p_pacote_arte boolean default false)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_txt text := coalesce(p_cep_ou_bairro, '');
  v_cep text := regexp_replace(coalesce(p_cep_ou_bairro, ''), '\D', '', 'g');
  v_zona boolean := false;
  v_origem text;
  it jsonb; prod record;
  v_peso numeric := 0; v_lado numeric := 0; v_desconhecido boolean := false; v_qtd integer;
  v_cabe boolean; v_elegivel_tamanho boolean; v_minimo_ok boolean; v_gratis boolean;
  v_motivo text; v_opcoes jsonb := '[]'::jsonb;
begin
  select * into pr from public.parametros_comerciais where id = 1;

  if v_txt ~ '^\s*\d{5}-?\d{3}\s*$' then
    v_origem := 'cep';
    v_zona := exists (select 1 from public.zonas_frete_gratis z where z.ativo and z.tipo = 'cep' and v_cep between z.cep_inicio and z.cep_fim);
  else
    v_origem := 'bairro';
    v_zona := exists (select 1 from public.zonas_frete_gratis z
                      where z.ativo and z.tipo = 'bairro'
                        and private.norm_txt(z.bairro) = regexp_replace(private.norm_txt(v_txt), '^bairro ', ''));
  end if;

  -- o peso do PEDIDO TODO é a soma dos pesos de todas as linhas; o maior lado é o maior entre todas
  for it in select * from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) loop
    select c.peso_g, c.maior_lado_mm into prod from public.catalogo c where c.sku = it ->> 'sku';
    if not found then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado', 'sku', it ->> 'sku'); end if;
    v_qtd := greatest(coalesce((it ->> 'quantidade')::integer, 1), 1);
    v_peso := v_peso + coalesce(prod.peso_g, 0) * v_qtd;
    if coalesce(prod.peso_g, 0) <= 0 or prod.maior_lado_mm is null then
      v_desconhecido := true;
    else
      v_lado := greatest(v_lado, prod.maior_lado_mm);
    end if;
  end loop;

  v_cabe := not v_desconhecido and v_peso <= pr.peso_max_bike_g and v_lado <= pr.lado_max_bike_mm;
  v_elegivel_tamanho := (not pr.exigir_cabe_na_bike) or v_cabe;
  v_minimo_ok := coalesce(p_pacote_arte, false) or coalesce(p_valor_pedido, 0) >= pr.pedido_minimo_frete_gratis;
  v_gratis := v_zona and v_elegivel_tamanho and v_minimo_ok;
  v_motivo := case
    when v_gratis then 'frete_gratis_regiao_central'
    when not v_zona then 'fora_da_regiao_central'
    when not v_elegivel_tamanho then case when v_desconhecido then 'dimensao_desconhecida' else 'nao_cabe_na_bike' end
    else 'abaixo_do_pedido_minimo' end;

  v_opcoes := jsonb_build_array(jsonb_build_object('tipo', 'retirada', 'valor_cliente', 0, 'obs', 'retirada grátis no centro de BH'));
  if v_gratis then
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('tipo', 'bike', 'valor_cliente', 0, 'obs', 'entrega grátis de bicicleta, em horário comercial'));
  else
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('tipo', 'uber', 'valor_cliente', pr.custo_entrega_uber, 'obs', 'Uber Entrega por conta do cliente (valor de referência)'));
  end if;

  return jsonb_build_object(
    'ok', true, 'origem_consulta', v_origem, 'regiao_central', v_zona,
    'cabe_na_bike', v_cabe, 'peso_total_g', v_peso, 'maior_lado_mm', v_lado, 'dimensao_desconhecida', v_desconhecido,
    'pedido_minimo', pr.pedido_minimo_frete_gratis, 'pedido_minimo_atingido', v_minimo_ok, 'pacote_arte', coalesce(p_pacote_arte, false),
    'falta_para_frete_gratis', case when v_minimo_ok then 0 else greatest(pr.pedido_minimo_frete_gratis - coalesce(p_valor_pedido, 0), 0) end,
    'frete_gratis', v_gratis,
    'valor_frete_cliente', case when v_gratis then 0 else pr.custo_entrega_uber end,
    'frete_estimado', not v_gratis,
    'custo_entrega_nosso', case when v_gratis then pr.custo_entrega_bike else 0 end,
    'entrega_sugerida', case when v_gratis then 'bike' else 'uber' end,
    'saidas_bike_por_dia', pr.saidas_bike_por_dia,
    'motivo', v_motivo, 'opcoes', v_opcoes);
end;
$$;

-- ---------------------------------------------------------------- 9. importação: funções (só o dono ou o servidor)
create or replace function private.dono_ou_servidor() returns boolean
language sql stable security definer set search_path = ''
as $$ select private.is_staff() or coalesce(auth.role(), '') = 'service_role'; $$;
revoke execute on function private.dono_ou_servidor() from public, anon;
grant execute on function private.dono_ou_servidor() to authenticated, service_role;

create or replace function public.catalogo_importacao_iniciar(p_nome text, p_path text, p_sha256 text, p_emitido date default null, p_candidatas integer default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono importa o catálogo.' using errcode = '42501'; end if;
  insert into public.catalogo_importacoes (arquivo_nome, arquivo_path, arquivo_sha256, emitido_em, linhas_candidatas)
  values (p_nome, p_path, p_sha256, p_emitido, p_candidatas) returning id into v_id;
  return v_id;
end;
$$;

-- Recebe um lote de linhas (jsonb). Valida linha a linha: nenhuma linha some, as inválidas ficam como rejeitadas com o motivo.
create or replace function public.catalogo_importacao_lote(p_id uuid, p_linhas jsonb)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  l jsonb; v_n integer := 0;
  v_sku text; v_desc text; v_custo numeric; v_qtd integer; v_prazo integer; v_motivo text; v_chave text;
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono importa o catálogo.' using errcode = '42501'; end if;
  if not exists (select 1 from public.catalogo_importacoes where id = p_id and status = 'carregando') then
    raise exception 'Importação inexistente ou já fechada.' using errcode = 'P0001';
  end if;
  for l in select * from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) loop
    v_sku := nullif(btrim(l ->> 'sku'), '');
    v_desc := nullif(btrim(l ->> 'descricao'), '');
    v_custo := nullif(l ->> 'custo', '')::numeric;
    v_qtd := nullif(l ->> 'quantidade', '')::numeric::integer;
    v_prazo := nullif(l ->> 'prazo', '')::numeric::integer;
    v_motivo := case
      when v_desc is null then 'sem descrição'
      when v_custo is null or v_custo <= 0 then 'custo ausente ou zerado'
      when v_qtd is null or v_qtd <= 0 then 'quantidade ausente ou inválida'
      when v_prazo is null or v_prazo < 0 then 'prazo ausente ou inválido'
      when v_sku is not null and v_sku !~ '^[A-Za-z0-9._/-]+$' then 'código com caracteres inválidos'
    end;
    v_chave := case when v_sku is null then md5(concat_ws('|', private.norm_txt(l ->> 'categoria'), private.norm_txt(l ->> 'descricao'),
                 private.norm_txt(l ->> 'cores'), coalesce(l ->> 'quantidade', ''), private.norm_txt(l ->> 'tamanho_mm'), coalesce(l ->> 'peso_g', ''))) end;
    insert into public.catalogo_import_linhas (importacao_id, n, sku, categoria, descricao, cores, peso_g, quantidade, tamanho_mm, prazo_dias_uteis, custo, chave_natural, resultado, motivo)
    values (p_id, (l ->> 'n')::integer, v_sku, nullif(btrim(l ->> 'categoria'), ''), v_desc, nullif(btrim(l ->> 'cores'), ''),
            nullif(l ->> 'peso_g', '')::numeric, v_qtd, nullif(btrim(l ->> 'tamanho_mm'), ''), v_prazo, v_custo, v_chave,
            case when v_motivo is null then 'pendente' else 'rejeitada' end, v_motivo)
    on conflict (importacao_id, n) do update set
      sku = excluded.sku, categoria = excluded.categoria, descricao = excluded.descricao, cores = excluded.cores, peso_g = excluded.peso_g,
      quantidade = excluded.quantidade, tamanho_mm = excluded.tamanho_mm, prazo_dias_uteis = excluded.prazo_dias_uteis, custo = excluded.custo,
      chave_natural = excluded.chave_natural, resultado = excluded.resultado, motivo = excluded.motivo;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- Pré-visualização: classifica TODAS as linhas (nenhuma fica sem destino) e monta o relatório de diferenças.
create or replace function public.catalogo_importacao_previa(p_id uuid, p_limite_pct numeric default 20)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_imp public.catalogo_importacoes%rowtype;
  v_lidas integer; v_rej integer; v_dup integer; v_conf integer; v_novas integer; v_alt integer; v_ig integer;
  v_semsku integer; v_semsku_novas integer; v_rem integer; v_acima integer; v_pisos integer; v_total_cat integer;
  v_cfv numeric; v_ratio numeric; v_pares integer; v_alertas text[] := '{}'; v_soma integer;
  v_rel jsonb;
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono importa o catálogo.' using errcode = '42501'; end if;
  select * into v_imp from public.catalogo_importacoes where id = p_id for update;
  if not found or v_imp.status not in ('carregando', 'previa') then raise exception 'Importação inexistente ou já aplicada.' using errcode = 'P0001'; end if;

  -- linhas recém-gravadas ainda não têm estatística; sem isto o planejador escolhe junções lentas (19 mil linhas levaram minutos)
  analyze public.catalogo_import_linhas;

  update public.catalogo_import_linhas set resultado = 'pendente', motivo = null, custo_anterior = null, prazo_anterior = null, variacao_pct = null, acima_limite = false
   where importacao_id = p_id and resultado <> 'rejeitada';

  -- SKU repetido: dados idênticos = duplicada (fica a primeira); dados diferentes = conflito (NENHUMA das linhas é aplicada, o dono decide)
  with v as (
    select sku, count(distinct (categoria, descricao, cores, peso_g, quantidade, tamanho_mm, prazo_dias_uteis, custo)) variantes
    from public.catalogo_import_linhas where importacao_id = p_id and resultado = 'pendente' and sku is not null group by sku
  ), g as (
    select l.n, row_number() over (partition by l.sku order by l.n) rn, v.variantes
    from public.catalogo_import_linhas l join v on v.sku = l.sku
    where l.importacao_id = p_id and l.resultado = 'pendente'
  )
  update public.catalogo_import_linhas l
     set resultado = case when g.variantes > 1 then 'conflito' else 'duplicada_igual' end,
         motivo = case when g.variantes > 1 then 'SKU repetido com dados diferentes' else 'SKU repetido com os mesmos dados' end
    from g
   where l.importacao_id = p_id and l.n = g.n and (g.variantes > 1 or g.rn > 1);
  -- sem SKU: mesma linha repetida
  with v as (
    select chave_natural, count(distinct (prazo_dias_uteis, custo)) variantes
    from public.catalogo_import_linhas where importacao_id = p_id and resultado = 'pendente' and sku is null group by chave_natural
  ), g as (
    select l.n, row_number() over (partition by l.chave_natural order by l.n) rn, v.variantes
    from public.catalogo_import_linhas l join v on v.chave_natural = l.chave_natural
    where l.importacao_id = p_id and l.resultado = 'pendente' and l.sku is null
  )
  update public.catalogo_import_linhas l
     set resultado = case when g.variantes > 1 then 'conflito' else 'duplicada_igual' end,
         motivo = case when g.variantes > 1 then 'Linha sem código repetida com preço ou prazo diferentes' else 'Linha sem código repetida' end
    from g
   where l.importacao_id = p_id and l.n = g.n and (g.variantes > 1 or g.rn > 1);

  -- contra o catálogo atual
  update public.catalogo_import_linhas l set
    resultado = case
      when c.id is null then 'nova'
      when c.custo = l.custo and c.prazo_dias_uteis = l.prazo_dias_uteis and c.active
           and c.descricao is not distinct from l.descricao and c.categoria is not distinct from l.categoria and c.cores is not distinct from l.cores
           and c.quantidade is not distinct from l.quantidade and c.tamanho_mm is not distinct from l.tamanho_mm and c.peso_g is not distinct from l.peso_g then 'igual'
      else 'alterada' end,
    custo_anterior = c.custo, prazo_anterior = c.prazo_dias_uteis,
    variacao_pct = case when c.custo > 0 then round((l.custo - c.custo) / c.custo * 100, 1) end,
    acima_limite = c.id is not null and (
      (c.custo > 0 and abs(l.custo - c.custo) / c.custo * 100 > p_limite_pct)
      or (c.prazo_dias_uteis > 0 and abs(l.prazo_dias_uteis - c.prazo_dias_uteis)::numeric / c.prazo_dias_uteis * 100 > p_limite_pct)),
    motivo = case when c.id is not null and not c.active then 'item estava desativado' end
  from (select l2.n, c2.* from public.catalogo_import_linhas l2 left join public.catalogo c2 on c2.sku = l2.sku
        where l2.importacao_id = p_id and l2.resultado = 'pendente' and l2.sku is not null) c
  where l.importacao_id = p_id and l.n = c.n and l.resultado = 'pendente' and l.sku is not null;

  update public.catalogo_import_linhas l set
    resultado = case
      when c.id is null then 'sem_sku_nova'
      when c.custo = l.custo and c.prazo_dias_uteis = l.prazo_dias_uteis and c.active then 'sem_sku_igual'
      else 'sem_sku_alterada' end,
    custo_anterior = c.custo, prazo_anterior = c.prazo_dias_uteis,
    variacao_pct = case when c.custo > 0 then round((l.custo - c.custo) / c.custo * 100, 1) end
  from (select l2.n, c2.* from public.catalogo_import_linhas l2 left join public.catalogo c2 on c2.chave_natural = l2.chave_natural and c2.sku is null
        where l2.importacao_id = p_id and l2.resultado = 'pendente' and l2.sku is null) c
  where l.importacao_id = p_id and l.n = c.n and l.resultado = 'pendente' and l.sku is null;

  select count(*), count(*) filter (where resultado = 'rejeitada'), count(*) filter (where resultado = 'duplicada_igual'), count(*) filter (where resultado = 'conflito'),
         count(*) filter (where resultado = 'nova'), count(*) filter (where resultado = 'alterada'), count(*) filter (where resultado = 'igual'),
         count(*) filter (where sku is null), count(*) filter (where resultado = 'sem_sku_nova'),
         count(*) filter (where acima_limite), count(*) filter (where resultado = 'alterada' and custo_anterior is distinct from custo)
    into v_lidas, v_rej, v_dup, v_conf, v_novas, v_alt, v_ig, v_semsku, v_semsku_novas, v_acima, v_pisos
    from public.catalogo_import_linhas where importacao_id = p_id;
  v_soma := (select count(*) from public.catalogo_import_linhas where importacao_id = p_id and resultado in
    ('nova', 'alterada', 'igual', 'sem_sku_nova', 'sem_sku_igual', 'sem_sku_alterada', 'duplicada_igual', 'conflito', 'rejeitada'));

  select count(*) into v_total_cat from public.catalogo where sku is not null and active;
  select count(*) into v_rem from public.catalogo c
   where c.sku is not null and c.active and not exists (select 1 from public.catalogo_import_linhas l where l.importacao_id = p_id and l.sku = c.sku);

  select max(l.custo) into v_cfv from public.catalogo_import_linhas l where l.importacao_id = p_id and l.sku = 'CFV02' and l.resultado <> 'rejeitada';
  select percentile_cont(0.5) within group (order by l.custo / c.custo), count(*) into v_ratio, v_pares
    from public.catalogo_import_linhas l join public.catalogo c on c.sku = l.sku
   where l.importacao_id = p_id and l.sku is not null and c.custo > 0 and l.resultado in ('alterada', 'igual');

  if v_cfv is null then v_alertas := array_append(v_alertas, 'cfv02_ausente');
  elsif v_cfv <> 75.99 then v_alertas := array_append(v_alertas, 'cfv02_diverge'); end if;
  if v_pares >= 100 and v_ratio between 1.7 and 1.9 then v_alertas := array_append(v_alertas, 'valores_parecem_inflados_80pct'); end if;
  if v_pares >= 100 and v_ratio < 0.6 then v_alertas := array_append(v_alertas, 'valores_parecem_reduzidos'); end if;
  if v_total_cat > 0 and v_rem::numeric / v_total_cat > 0.25 then v_alertas := array_append(v_alertas, 'muitos_itens_removidos'); end if;
  if v_imp.linhas_candidatas is not null and v_imp.linhas_candidatas <> v_lidas then v_alertas := array_append(v_alertas, 'total_nao_confere_com_o_arquivo'); end if;
  if v_conf > 0 then v_alertas := array_append(v_alertas, 'sku_repetido_com_dados_diferentes'); end if;
  if v_soma <> v_lidas then v_alertas := array_append(v_alertas, 'linhas_sem_destino'); end if;

  v_rel := jsonb_build_object(
    'lidas', v_lidas, 'linhas_candidatas_arquivo', v_imp.linhas_candidatas, 'confere', v_soma = v_lidas,
    'novas', v_novas, 'alteradas', v_alt, 'iguais', v_ig,
    'sem_sku', v_semsku, 'sem_sku_novas', v_semsku_novas,
    'duplicadas_iguais', v_dup, 'conflitos', v_conf, 'rejeitadas', v_rej,
    'removidos', v_rem, 'acima_do_limite', v_acima, 'limite_pct', p_limite_pct, 'pisos_que_mudam', v_pisos,
    'cfv02_custo', v_cfv, 'cfv02_esperado', 75.99, 'razao_mediana_custo', round(v_ratio, 3), 'itens_comparados', v_pares,
    'alertas', to_jsonb(v_alertas));
  update public.catalogo_importacoes set status = 'previa', limite_alteracao_pct = p_limite_pct, relatorio = v_rel where id = p_id;
  return v_rel;
end;
$$;

-- Aplica em lotes (a tela repete até restantes = 0). Alertas graves exigem p_aceitar_alertas = true (confirmação do dono).
create or replace function public.catalogo_importacao_aplicar(p_id uuid, p_limite integer default 1000, p_aceitar_alertas boolean default false, p_desativar_removidos boolean default true)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_imp public.catalogo_importacoes%rowtype;
  l public.catalogo_import_linhas%rowtype;
  v_feitas integer := 0; v_restantes integer; v_desativados integer := 0; v_nc integer;
  v_graves text[];
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono importa o catálogo.' using errcode = '42501'; end if;
  select * into v_imp from public.catalogo_importacoes where id = p_id for update;
  if not found or v_imp.status not in ('previa', 'aplicando') then raise exception 'Faça a pré-visualização antes de aplicar.' using errcode = 'P0001'; end if;
  v_graves := array(select a from jsonb_array_elements_text(v_imp.relatorio -> 'alertas') a
                    where a in ('cfv02_diverge', 'cfv02_ausente', 'valores_parecem_inflados_80pct', 'valores_parecem_reduzidos', 'muitos_itens_removidos', 'total_nao_confere_com_o_arquivo', 'linhas_sem_destino'));
  if cardinality(v_graves) > 0 and not p_aceitar_alertas then
    raise exception 'Há alertas na pré-visualização (%). Confira e confirme para aplicar.', array_to_string(v_graves, ', ') using errcode = 'P0001';
  end if;
  if v_imp.status = 'previa' then update public.catalogo_importacoes set status = 'aplicando' where id = p_id; end if;

  for l in select * from public.catalogo_import_linhas
            where importacao_id = p_id and resultado in ('nova', 'alterada', 'sem_sku_nova', 'sem_sku_alterada') order by n limit p_limite loop
    if l.sku is not null then
      insert into public.catalogo as c (sku, categoria, descricao, cores, peso_g, quantidade, tamanho_mm, prazo_dias_uteis, custo, gramatura_g, active, origem_importacao_id)
      values (l.sku, l.categoria, l.descricao, l.cores, l.peso_g, l.quantidade, l.tamanho_mm, l.prazo_dias_uteis, l.custo,
              (substring(l.descricao from '(?i)(\d{1,4})\s*(?:g/m|gr?\M|gramas)'))::integer, true, p_id)
      on conflict (sku) do update set
        categoria = excluded.categoria, descricao = excluded.descricao, cores = excluded.cores, peso_g = excluded.peso_g, quantidade = excluded.quantidade,
        tamanho_mm = excluded.tamanho_mm, prazo_dias_uteis = excluded.prazo_dias_uteis, custo = excluded.custo, gramatura_g = excluded.gramatura_g,
        active = true, origem_importacao_id = p_id;
      if l.resultado = 'alterada' and l.custo_anterior is distinct from l.custo then
        update public.precos_mercado set invalidado_em = now() where sku = l.sku and invalidado_em is null;
      end if;
    else
      insert into public.catalogo (sku, chave_natural, categoria, descricao, cores, peso_g, quantidade, tamanho_mm, prazo_dias_uteis, custo, gramatura_g, active, origem_importacao_id)
      values (null, l.chave_natural, l.categoria, l.descricao, l.cores, l.peso_g, l.quantidade, l.tamanho_mm, l.prazo_dias_uteis, l.custo,
              (substring(l.descricao from '(?i)(\d{1,4})\s*(?:g/m|gr?\M|gramas)'))::integer, true, p_id)
      on conflict (chave_natural) where sku is null do update set
        prazo_dias_uteis = excluded.prazo_dias_uteis, custo = excluded.custo, active = true, origem_importacao_id = p_id;
    end if;
    update public.catalogo_import_linhas set resultado = 'aplicada' where importacao_id = p_id and n = l.n;
    v_feitas := v_feitas + 1;
  end loop;

  select count(*) into v_restantes from public.catalogo_import_linhas where importacao_id = p_id and resultado in ('nova', 'alterada', 'sem_sku_nova', 'sem_sku_alterada');
  if v_restantes = 0 then
    -- item que saiu da tabela é desativado (não apagado: pedidos antigos continuam apontando para ele)
    if p_desativar_removidos then
      update public.catalogo c set active = false
       where c.sku is not null and c.active and not exists (select 1 from public.catalogo_import_linhas x where x.importacao_id = p_id and x.sku = c.sku);
      get diagnostics v_desativados = row_count;
    end if;
    v_nc := public.catalogo_atualizar_competitividade();
    update public.catalogo_importacoes set status = 'aplicada', aplicado_em = now(),
      relatorio = relatorio || jsonb_build_object('desativados', v_desativados, 'nao_competitivos_agora', v_nc,
        'inseridas', (select count(*) from public.catalogo_import_linhas where importacao_id = p_id and resultado = 'aplicada' and sku is not null and custo_anterior is null),
        'atualizadas', (select count(*) from public.catalogo_import_linhas where importacao_id = p_id and resultado = 'aplicada' and custo_anterior is not null))
     where id = p_id;
  end if;
  return jsonb_build_object('aplicadas', v_feitas, 'restantes', v_restantes, 'desativados', v_desativados);
end;
$$;

-- Itens com mercado abaixo do piso viram nao_competitivo; voltam para vender quando deixam de ser. Só mexe em vender/nao_competitivo (status manuais ficam).
create or replace function public.catalogo_atualizar_competitividade()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype; v_n integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  -- abaixo = mediana de mercado x fator competitivo (arredondada em ,90) menor que o piso do item
  with m as (
    select sku, percentile_cont(0.5) within group (order by preco) med, count(*) n from public.precos_mercado
     where not outlier and invalidado_em is null and coletado_em >= now() - make_interval(days => pr.idade_max_pesquisa_dias) group by sku
  ), comp as (
    select c.id, (private.arredonda_90((m.med * pr.fator_competitivo)::numeric) < c.piso) as abaixo
      from m join public.catalogo c on c.sku = m.sku where m.n >= 2 and c.piso is not null
  )
  update public.catalogo c set status_venda = case when comp.abaixo then 'nao_competitivo' else 'vender' end
    from comp
   where c.id = comp.id and c.status_venda in ('vender', 'nao_competitivo')
     and c.status_venda <> case when comp.abaixo then 'nao_competitivo' else 'vender' end;
  -- sem dado de mercado válido (invalidado ou vencido), volta ao normal
  update public.catalogo c set status_venda = 'vender'
   where c.status_venda = 'nao_competitivo'
     and not exists (select 1 from public.precos_mercado m where m.sku = c.sku and not m.outlier and m.invalidado_em is null
                     and m.coletado_em >= now() - make_interval(days => pr.idade_max_pesquisa_dias));
  select count(*) into v_n from public.catalogo where status_venda = 'nao_competitivo';
  return v_n;
end;
$$;

-- Itens que o dono precisa cadastrar: linhas do PDF sem código
create or replace view public.catalogo_sem_sku with (security_invoker = true) as
select id, categoria, descricao, cores, quantidade, tamanho_mm, prazo_dias_uteis, peso_g
from public.catalogo where sku is null and active;
revoke all on public.catalogo_sem_sku from anon;

-- Dono informa o código de uma linha sem SKU (a linha passa a ser vendável como os demais)
create or replace function public.catalogo_definir_sku(p_id uuid, p_sku text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono define o código.' using errcode = '42501'; end if;
  if nullif(btrim(p_sku), '') is null or btrim(p_sku) !~ '^[A-Za-z0-9._/-]+$' then raise exception 'Código inválido.' using errcode = 'P0001'; end if;
  if exists (select 1 from public.catalogo where sku = btrim(p_sku)) then raise exception 'Esse código já existe no catálogo.' using errcode = 'P0001'; end if;
  update public.catalogo set sku = btrim(p_sku), chave_natural = null where id = p_id and sku is null;
end;
$$;

revoke execute on function public.catalogo_importacao_iniciar(text, text, text, date, integer), public.catalogo_importacao_lote(uuid, jsonb),
  public.catalogo_importacao_previa(uuid, numeric), public.catalogo_importacao_aplicar(uuid, integer, boolean, boolean),
  public.catalogo_atualizar_competitividade(), public.catalogo_definir_sku(uuid, text) from public, anon;
