-- E-commerce Fase 3: a planilha oficial de preços de venda passa a ser a fonte do preço.
-- Decisão do dono (09/11/2026): o preço de venda vem direto da planilha; a pesquisa de mercado
-- deixa de ser usada. Aditiva e idempotente: a fórmula antiga fica em private.calcular_preco_mercado
-- e só é usada para SKU sem preço de planilha (ou se o dono voltar parametros_comerciais.fonte_preco = 'mercado').
-- Travas que continuam soberanas: custo x 1,5, lucro mínimo por pedido e nunca prejuízo (piso duro).

-- 1) Colunas novas -----------------------------------------------------------------------------------
alter table public.catalogo
  add column if not exists preco_venda numeric(12,2),
  add column if not exists preco_mercado_ref numeric(12,2),
  add column if not exists prazo_cliente_dias integer,
  add column if not exists peso_frete_kg numeric(10,3),
  add column if not exists embalagem_cm text,
  add column if not exists tipo_embalagem text,
  add column if not exists estrategia_preco text,
  add column if not exists preco_planilha_em timestamptz;

alter table public.parametros_comerciais
  add column if not exists fonte_preco text not null default 'planilha',
  add column if not exists lucro_bruto_minimo numeric(10,2) not null default 65;

do $$ begin
  alter table public.parametros_comerciais add constraint parametros_fonte_preco_chk check (fonte_preco in ('planilha', 'mercado'));
exception when duplicate_object then null; end $$;

-- Lucro mínimo por pedido informado pelo dono: R$ 65. Horário do balcão: 08:00.
update public.parametros_comerciais
   set lucro_liquido_minimo = greatest(lucro_liquido_minimo, 65),
       horario_atendimento = jsonb_build_object(
         'seg', jsonb_build_object('abre', '08:00', 'fecha', '17:00'),
         'ter', jsonb_build_object('abre', '08:00', 'fecha', '17:00'),
         'qua', jsonb_build_object('abre', '08:00', 'fecha', '17:00'),
         'qui', jsonb_build_object('abre', '08:00', 'fecha', '17:00'),
         'sex', jsonb_build_object('abre', '08:00', 'fecha', '18:30'),
         'sab', null, 'dom', null)
 where id = 1;

-- 2) Staging privada da planilha ----------------------------------------------------------------------
create table if not exists public.planilha_precos_import (
  sku text primary key,
  categoria text,
  descricao text,
  cores text,
  formato text,
  quantidade integer,
  prazo_fabrica_dias integer,
  prazo_cliente_dias integer,
  peso_g numeric,
  tipo_embalagem text,
  embalagem_cm text,
  custo numeric(12,2) not null,
  preco_mercado numeric(12,2),
  preco_venda numeric(12,2) not null,
  estrategia text,
  importado_em timestamptz not null default now()
);
alter table public.planilha_precos_import enable row level security;
revoke all on public.planilha_precos_import from anon, authenticated;
grant select on public.planilha_precos_import to authenticated;
drop policy if exists planilha_precos_import_dono on public.planilha_precos_import;
create policy planilha_precos_import_dono on public.planilha_precos_import for select to authenticated using (private.is_staff());

-- Token temporário para a carga inicial feita fora do CRM (fica em app_segredos, chave 'importar_precos_token',
-- vale 2 horas). Sem token, só o dono logado ou o service role importam.
create or replace function private.pode_importar_precos(p_token text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.dono_ou_servidor()
      or (p_token is not null and length(p_token) >= 32 and exists (
            select 1 from public.app_segredos s
             where s.chave = 'importar_precos_token' and s.valor = p_token and s.criado_em > now() - interval '2 hours'));
$$;
revoke all on function private.pode_importar_precos(text) from public, anon, authenticated;

-- Recebe um lote (até 2.000 linhas) da planilha. Idempotente por SKU.
create or replace function public.importar_precos_planilha(p_linhas jsonb, p_token text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  if not private.pode_importar_precos(p_token) then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) > 2000 then
    raise exception 'Envie de 1 a 2.000 linhas por lote.' using errcode = '22023';
  end if;
  insert into public.planilha_precos_import as t (sku, categoria, descricao, cores, formato, quantidade, prazo_fabrica_dias, prazo_cliente_dias,
                                                  peso_g, tipo_embalagem, embalagem_cm, custo, preco_mercado, preco_venda, estrategia, importado_em)
  select upper(btrim(l ->> 'sku')), l ->> 'categoria', l ->> 'descricao', upper(nullif(btrim(l ->> 'cores'), '')), l ->> 'formato',
         nullif(l ->> 'quantidade', '')::numeric::integer, nullif(l ->> 'prazo_fabrica_dias', '')::numeric::integer,
         nullif(l ->> 'prazo_cliente_dias', '')::numeric::integer, nullif(l ->> 'peso_g', '')::numeric,
         l ->> 'tipo_embalagem', l ->> 'embalagem_cm', (l ->> 'custo')::numeric, nullif(l ->> 'preco_mercado', '')::numeric,
         (l ->> 'preco_venda')::numeric, l ->> 'estrategia', now()
    from jsonb_array_elements(p_linhas) l
   where nullif(btrim(l ->> 'sku'), '') is not null and (l ->> 'preco_venda') is not null and (l ->> 'custo') is not null
  on conflict (sku) do update set
    categoria = excluded.categoria, descricao = excluded.descricao, cores = excluded.cores, formato = excluded.formato,
    quantidade = excluded.quantidade, prazo_fabrica_dias = excluded.prazo_fabrica_dias, prazo_cliente_dias = excluded.prazo_cliente_dias,
    peso_g = excluded.peso_g, tipo_embalagem = excluded.tipo_embalagem, embalagem_cm = excluded.embalagem_cm, custo = excluded.custo,
    preco_mercado = excluded.preco_mercado, preco_venda = excluded.preco_venda, estrategia = excluded.estrategia, importado_em = now();
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'gravadas', v_n, 'na_staging', (select count(*) from public.planilha_precos_import));
end $$;
revoke all on function public.importar_precos_planilha(jsonb, text) from public;
grant execute on function public.importar_precos_planilha(jsonb, text) to authenticated, service_role, anon;

-- 3) Vitrine pública do e-commerce (sem custo, margem, piso, fornecedor nem SKU) -------------------
create table if not exists public.ecommerce_products (
  sku text primary key references public.catalogo (sku) on update cascade on delete cascade,
  ref text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  produto_slug text not null,
  categoria text not null,
  categoria_slug text not null,
  titulo text not null,
  descricao text,
  especificacao text,
  cores_rotulo text,
  formato_rotulo text,
  quantidade integer,
  preco numeric(12,2) not null,
  parcela_2x numeric(12,2) not null,
  prazo_dias_uteis integer,
  peso_kg numeric(10,3),
  embalagem_cm text,
  tipo_embalagem text,
  fotos jsonb not null default '[]'::jsonb,
  ficha jsonb not null default '{}'::jsonb,
  acabamentos jsonb not null default '[]'::jsonb,
  gabaritos jsonb not null default '[]'::jsonb,
  ativo boolean not null default true,
  atualizado_em timestamptz not null default now()
);
create index if not exists ecommerce_products_produto_idx on public.ecommerce_products (produto_slug);
create index if not exists ecommerce_products_categoria_idx on public.ecommerce_products (categoria_slug) where ativo;
alter table public.ecommerce_products enable row level security;
revoke all on public.ecommerce_products from anon, authenticated;
-- coluna sku fica de fora para o público (o SKU é interno)
grant select (ref, produto_slug, categoria, categoria_slug, titulo, descricao, especificacao, cores_rotulo, formato_rotulo, quantidade, preco,
              parcela_2x, prazo_dias_uteis, peso_kg, embalagem_cm, tipo_embalagem, fotos, ficha, acabamentos, gabaritos, ativo, atualizado_em)
  on public.ecommerce_products to anon, authenticated;
drop policy if exists ecommerce_products_publico on public.ecommerce_products;
create policy ecommerce_products_publico on public.ecommerce_products for select to anon, authenticated using (ativo);

-- Tradução de balcão (sem jargão) ------------------------------------------------------------------------
create or replace function private.cores_rotulo(p_cores text)
returns text language sql immutable set search_path = '' as $$
  select case upper(replace(coalesce(p_cores, ''), ' ', ''))
    when '4X0' then 'Colorido Apenas na Frente'
    when '4X4' then 'Colorido Frente e Verso'
    when '1X0' then 'Preto e Branco Apenas na Frente'
    when '1X1' then 'Preto e Branco Frente e Verso'
    when '4X1' then 'Colorido na Frente e Preto e Branco no Verso'
    when '2X0' then 'Duas Cores Apenas na Frente'
    when '0X0' then 'Sem Impressão / Acabamento Bruto / Gravação Laser'
    when '' then null
    else p_cores end;
$$;

create or replace function private.formato_rotulo(p_tamanho text)
returns text language plpgsql immutable set search_path = '' as $$
declare m text[];
begin
  if p_tamanho is null or btrim(p_tamanho) = '' or p_tamanho ~ '^\s*0\s*[xX]\s*0\s*$' then return 'Formato Padrão de Mesa'; end if;
  m := regexp_match(p_tamanho, '^\s*(\d+(?:[.,]\d+)?)\s*[xX]\s*(\d+(?:[.,]\d+)?)\s*$');
  if m is null then return btrim(p_tamanho); end if;
  if p_tamanho ~ '^\s*1000\s*[xX]\s*1000\s*$' then return 'Por metro quadrado (m²)'; end if;
  return format('%s x %s mm (%s x %s cm)', m[1], m[2],
    replace(trim(trailing '.' from trim(trailing '0' from to_char(replace(m[1], ',', '.')::numeric / 10, 'FM99990.0'))), '.', ','),
    replace(trim(trailing '.' from trim(trailing '0' from to_char(replace(m[2], ',', '.')::numeric / 10, 'FM99990.0'))), '.', ','));
end $$;

create or replace function private.slugify(p text)
returns text language sql immutable set search_path = '' as $$
  select trim(both '-' from regexp_replace(lower(translate(coalesce(p, ''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ²',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn2')), '[^a-z0-9]+', '-', 'g'));
$$;

create or replace function private.titulo_vitrine(p_categoria text, p_descricao text)
returns text language sql immutable set search_path = '' as $$
  select btrim(initcap(lower(coalesce(nullif(btrim(
    case when p_categoria is not null and upper(btrim(p_descricao)) like upper(btrim(p_categoria)) || ' -%'
         then substr(btrim(p_descricao), length(btrim(p_categoria)) + 3)
         else p_descricao end), ''), p_categoria))));
$$;

-- Recria a vitrine a partir do catálogo (só itens ativos, vendáveis e com preço da planilha).
create or replace function public.ecommerce_sincronizar()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_up integer; v_off integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  insert into public.ecommerce_products as e (sku, produto_slug, categoria, categoria_slug, titulo, descricao, especificacao, cores_rotulo,
                                              formato_rotulo, quantidade, preco, parcela_2x, prazo_dias_uteis, peso_kg, embalagem_cm, tipo_embalagem, ativo, atualizado_em)
  select c.sku,
         private.slugify(concat_ws(' ', private.titulo_vitrine(c.categoria, c.descricao), c.categoria, private.cores_rotulo(c.cores), c.tamanho_mm)),
         initcap(lower(c.categoria)), private.slugify(c.categoria),
         private.titulo_vitrine(c.categoria, c.descricao),
         initcap(lower(c.descricao)),
         private.traduzir_especificacao(c.cores, c.gramatura_g, c.tamanho_mm, c.descricao),
         private.cores_rotulo(c.cores), private.formato_rotulo(c.tamanho_mm), c.quantidade,
         c.preco_venda, round(c.preco_venda / 2, 2),
         coalesce(c.prazo_cliente_dias, c.prazo_dias_uteis + 1),
         coalesce(c.peso_frete_kg, round(c.peso_g / 1000.0, 3)), c.embalagem_cm, c.tipo_embalagem, true, now()
    from public.catalogo c
   where c.active and c.vendavel and c.preco_venda is not null and c.sku is not null
  on conflict (sku) do update set
    produto_slug = excluded.produto_slug, categoria = excluded.categoria, categoria_slug = excluded.categoria_slug, titulo = excluded.titulo,
    descricao = excluded.descricao, especificacao = excluded.especificacao, cores_rotulo = excluded.cores_rotulo, formato_rotulo = excluded.formato_rotulo,
    quantidade = excluded.quantidade, preco = excluded.preco, parcela_2x = excluded.parcela_2x, prazo_dias_uteis = excluded.prazo_dias_uteis,
    peso_kg = excluded.peso_kg, embalagem_cm = excluded.embalagem_cm, tipo_embalagem = excluded.tipo_embalagem, ativo = true, atualizado_em = now();
  get diagnostics v_up = row_count;
  update public.ecommerce_products e set ativo = false, atualizado_em = now()
   where e.ativo and not exists (select 1 from public.catalogo c where c.sku = e.sku and c.active and c.vendavel and c.preco_venda is not null);
  get diagnostics v_off = row_count;
  return jsonb_build_object('ok', true, 'na_vitrine', v_up, 'retirados', v_off);
end $$;
revoke all on function public.ecommerce_sincronizar() from public, anon;
grant execute on function public.ecommerce_sincronizar() to authenticated, service_role;

-- 4) Aplicar a staging no catálogo ------------------------------------------------------------------
create or replace function public.aplicar_planilha_precos(p_token text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_atualizados integer; v_custos integer; v_travas integer; v_sem_catalogo integer; v_sem_preco integer; v_vitrine jsonb;
  v_exemplos_trava jsonb; v_exemplos_sem jsonb;
begin
  if not private.pode_importar_precos(p_token) then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;

  -- linhas que furariam a trava (custo x 1,5 ou lucro bruto mínimo) não entram: o SKU fica com a fórmula antiga e vai ao relatório
  select count(*), coalesce(jsonb_agg(s.sku) filter (where s.rn <= 20), '[]'::jsonb) into v_travas, v_exemplos_trava
    from (select p.sku, row_number() over (order by p.sku) rn from public.planilha_precos_import p
           where p.preco_venda < p.custo * pr.multiplicador_piso - 0.005 or p.preco_venda - p.custo < pr.lucro_bruto_minimo - 0.005) s;

  select count(*), coalesce(jsonb_agg(s.sku) filter (where s.rn <= 20), '[]'::jsonb) into v_sem_catalogo, v_exemplos_sem
    from (select p.sku, row_number() over (order by p.sku) rn from public.planilha_precos_import p
           where not exists (select 1 from public.catalogo c where c.sku = p.sku)) s;

  select count(*) into v_custos from public.catalogo c join public.planilha_precos_import p on p.sku = c.sku
   where abs(coalesce(c.custo, 0) - p.custo) > 0.005;

  update public.catalogo c set
    custo = p.custo,
    preco_venda = p.preco_venda,
    preco_mercado_ref = p.preco_mercado,
    prazo_cliente_dias = p.prazo_cliente_dias,
    peso_frete_kg = round(p.peso_g / 1000.0, 3),
    embalagem_cm = p.embalagem_cm,
    tipo_embalagem = p.tipo_embalagem,
    estrategia_preco = p.estrategia,
    preco_planilha_em = now()
  from public.planilha_precos_import p
  where p.sku = c.sku
    and p.preco_venda >= p.custo * pr.multiplicador_piso - 0.005
    and p.preco_venda - p.custo >= pr.lucro_bruto_minimo - 0.005;
  get diagnostics v_atualizados = row_count;

  select count(*) into v_sem_preco from public.catalogo c where c.active and c.preco_venda is null;
  v_vitrine := public.ecommerce_sincronizar();

  return jsonb_build_object('ok', true, 'atualizados', v_atualizados, 'custos_alterados', v_custos,
    'barrados_pela_trava', v_travas, 'exemplos_barrados', v_exemplos_trava,
    'planilha_sem_catalogo', v_sem_catalogo, 'exemplos_sem_catalogo', v_exemplos_sem,
    'catalogo_sem_preco_de_planilha', v_sem_preco, 'vitrine', v_vitrine);
end $$;
revoke all on function public.aplicar_planilha_precos(text) from public;
grant execute on function public.aplicar_planilha_precos(text) to authenticated, service_role, anon;

-- 5) Fórmula antiga preservada como plano B -------------------------------------------------------------
create or replace function private.calcular_preco_mercado(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable set search_path = '' as $function$
declare
  pr public.parametros_comerciais%rowtype;
  prod record;
  v_qtd integer := greatest(coalesce(p_quantidade, 1), 1);
  v_metodo text := case when p_contexto ->> 'simular_metodo' = 'true' then p_contexto ->> 'metodo' end;
  v_outros_receita numeric := coalesce((p_contexto ->> 'receita_outros')::numeric, 0);
  v_outros_custo numeric := coalesce((p_contexto ->> 'custo_outros')::numeric, 0);
  v_largura_mm integer := nullif((p_contexto ->> 'largura_mm')::integer, 0);
  v_altura_mm integer := nullif((p_contexto ->> 'altura_mm')::integer, 0);
  v_area_m2 numeric := 1.000;
  v_e_m2 boolean := false;
  v_custo_item numeric; v_custo_total numeric; v_extra numeric;
  v_base numeric; v_piso numeric; v_piso_duro numeric;
  v_mediana numeric; v_n integer; v_fator numeric; v_alvo numeric; v_preco numeric;
  v_ancora numeric; v_n_vendas integer; v_consulta uuid;
  v_regra text; v_conf text; v_nao_comp boolean := false; v_receita numeric; v_lucro numeric;
  v_avisos text[] := '{}';
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select c.sku, c.custo, c.active, c.vendavel, c.grupo_produto, c.especificacao_normalizada, c.tamanho_mm, c.categoria, c.descricao
    into prod from public.catalogo c where c.sku = p_sku;
  if not found or not prod.active then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  if not prod.vendavel then return jsonb_build_object('ok', false, 'erro', 'item_nao_vendavel'); end if;

  if (prod.tamanho_mm ilike '%metro%' or prod.descricao ilike '%metro quadrado%' or prod.descricao ilike '%(m²)%' or p_sku ilike '%M2%'
      or prod.tamanho_mm = '1000 x 1000' or prod.categoria ilike '%BANNER%' or prod.categoria ilike '%LONA%' or prod.categoria ilike '%BACKDROP%'
      or (prod.categoria ilike '%ADESIVO%' and (prod.descricao ilike '%METRO%' or prod.tamanho_mm ilike '%1000 x 1000%'))) then
    v_e_m2 := true;
    if v_largura_mm is not null and v_altura_mm is not null then
      v_area_m2 := round((v_largura_mm::numeric * v_altura_mm::numeric) / 1000000.0, 3);
      -- faturamento mínimo de 1 m² por peça (regra da produção)
      if v_area_m2 < 1.000 then v_area_m2 := 1.000; v_avisos := array_append(v_avisos, 'faturamento_minimo_1m2'); end if;
    else
      v_area_m2 := 1.000;
    end if;
    v_custo_item := prod.custo * v_area_m2 * v_qtd;
  else
    v_custo_item := prod.custo * v_qtd;
  end if;

  v_custo_total := v_custo_item + v_outros_custo;
  v_extra := private.custos_operacionais(p_contexto ->> 'entrega');
  v_piso := ceil(greatest(v_custo_item * pr.multiplicador_piso,
                          private.receita_para_lucro(v_custo_total, v_extra, pr.lucro_liquido_minimo, v_metodo) - v_outros_receita) * 100) / 100;
  v_piso_duro := ceil((private.receita_para_lucro(v_custo_total, v_extra, 0, v_metodo) - v_outros_receita) * 100) / 100;
  v_base := private.arredonda_90(v_custo_item * private.multiplicador_faixa(v_custo_item));

  select percentile_cont(0.5) within group (order by m.preco), count(distinct m.fonte) into v_mediana, v_n
    from public.precos_mercado m
   where (m.chave_especificacao = coalesce(nullif(prod.especificacao_normalizada, ''), p_sku) or m.sku = p_sku)
     and m.normalizado and not m.outlier and m.invalidado_em is null
     and m.coletado_em >= now() - make_interval(days => pr.idade_max_pesquisa_dias);
  if v_n > 0 then
    select m.consulta_id into v_consulta from public.precos_mercado m
     where (m.chave_especificacao = coalesce(nullif(prod.especificacao_normalizada, ''), p_sku) or m.sku = p_sku)
       and m.normalizado and not m.outlier and m.invalidado_em is null and m.consulta_id is not null
     order by m.coletado_em desc limit 1;
  end if;

  select coalesce(f.fator, pr.fator_competitivo) into v_fator from (select 1) x left join public.fatores_competitivos f on f.grupo_produto = prod.grupo_produto;
  v_fator := least(greatest(coalesce(v_fator, pr.fator_competitivo), pr.fator_competitivo_min), pr.fator_competitivo_max);

  select count(*), sum((p.preco_total / p.quantidade) * w) / nullif(sum(w), 0) into v_n_vendas, v_ancora
    from (select pp.preco_total, pp.quantidade, 1.0 / (1 + extract(epoch from (now() - pp.criado_em)) / 86400 / 30) as w
            from public.precos_praticados pp
           where pp.sku = p_sku and pp.resultado = 'ganho' and pp.criado_em >= now() - interval '90 days' and pp.preco_total > 0) p;
  if coalesce(v_n_vendas, 0) < 3 then v_ancora := null; end if;

  if v_n > 0 then
    v_alvo := v_mediana * v_qtd * (case when v_e_m2 then v_area_m2 else 1 end) * v_fator;
    v_regra := 'mercado';
    if v_ancora is not null then
      v_alvo := (v_alvo + least(v_ancora, v_mediana) * v_qtd) / 2;
      v_regra := 'mercado_com_ancora_vendas';
    end if;
    v_alvo := private.arredonda_90(v_alvo);
    v_conf := case when v_n >= 3 then 'alta' when v_n = 2 then 'media' else 'baixa' end;
    if v_n = 1 then v_avisos := array_append(v_avisos, 'mercado_com_uma_fonte'); end if;
  elsif v_ancora is not null then
    v_alvo := private.arredonda_90(v_ancora * v_qtd);
    v_regra := 'historico_vendas'; v_conf := 'media';
  else
    v_alvo := greatest(v_base, private.arredonda_90(v_custo_item + pr.markup_minimo_bloco * v_qtd));
    v_regra := 'custo_x_multiplicador'; v_conf := 'baixa';
    v_avisos := array_append(v_avisos, 'sem_dado_de_mercado');
  end if;

  if v_alvo >= v_piso then
    v_preco := v_alvo;
  else
    v_preco := private.teto_90(v_piso);
    v_regra := 'piso';
    v_nao_comp := v_n > 0;
    if v_nao_comp then v_avisos := array_append(v_avisos, 'mercado_abaixo_do_piso'); end if;
  end if;
  if v_preco < v_piso_duro then v_preco := private.teto_90(v_piso_duro); end if;

  v_receita := v_preco + v_outros_receita;
  v_lucro := private.lucro(v_receita, v_custo_total, v_extra, v_metodo);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku, 'quantidade', v_qtd,
    'preco_unitario', round(v_preco / v_qtd, 2), 'preco_total', v_preco,
    'calculado_por_m2', v_e_m2, 'area_m2_por_unidade', v_area_m2,
    'largura_mm', v_largura_mm, 'altura_mm', v_altura_mm,
    'regra', v_regra, 'confianca', v_conf,
    'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1), 'lucro_liquido', v_lucro,
    'lucro_ok', v_lucro >= pr.lucro_liquido_minimo - 0.05,
    'piso', round(v_piso, 2), 'piso_duro', round(v_piso_duro, 2),
    'nao_competitivo', v_nao_comp, 'fontes_mercado', v_n, 'mercado_mediana', round(v_mediana * v_qtd, 2),
    'consulta_mercado_id', v_consulta, 'fator_competitivo', v_fator, 'ancora_vendas', round(v_ancora * v_qtd, 2),
    'avisos', to_jsonb(v_avisos));
end;
$function$;
revoke all on function private.calcular_preco_mercado(text, integer, jsonb) from public, anon, authenticated;

-- 6) calcular_preco: mesma assinatura e mesmo formato de retorno; o preço vem da planilha ----------
create or replace function public.calcular_preco(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable set search_path = '' as $function$
declare
  pr public.parametros_comerciais%rowtype;
  prod record;
  j jsonb;
  v_qtd integer := greatest(coalesce(p_quantidade, 1), 1);
  v_metodo text := case when p_contexto ->> 'simular_metodo' = 'true' then p_contexto ->> 'metodo' end;
  v_outros_receita numeric := coalesce((p_contexto ->> 'receita_outros')::numeric, 0);
  v_outros_custo numeric := coalesce((p_contexto ->> 'custo_outros')::numeric, 0);
  v_largura_mm integer := nullif((p_contexto ->> 'largura_mm')::integer, 0);
  v_altura_mm integer := nullif((p_contexto ->> 'altura_mm')::integer, 0);
  v_area_m2 numeric := 1.000; v_e_m2 boolean := false;
  v_custo_item numeric; v_custo_total numeric; v_extra numeric;
  v_piso numeric; v_piso_duro numeric; v_preco numeric; v_receita numeric; v_lucro numeric;
  v_regra text := 'planilha';
  v_avisos text[] := '{}';
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select c.sku, c.custo, c.active, c.vendavel, c.tamanho_mm, c.categoria, c.descricao, c.preco_venda, c.preco_mercado_ref
    into prod from public.catalogo c where c.sku = p_sku;
  if not found or not prod.active then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  if not prod.vendavel then return jsonb_build_object('ok', false, 'erro', 'item_nao_vendavel'); end if;

  -- sem preço de planilha (ou dono voltou ao modo mercado): fórmula antiga, com aviso
  if pr.fonte_preco <> 'planilha' or prod.preco_venda is null then
    j := private.calcular_preco_mercado(p_sku, p_quantidade, p_contexto);
    if pr.fonte_preco = 'planilha' and coalesce((j ->> 'ok')::boolean, false) then
      j := jsonb_set(j, '{avisos}', coalesce(j -> 'avisos', '[]'::jsonb) || '["sem_preco_de_planilha"]'::jsonb);
    end if;
    return j;
  end if;

  -- produtos por m²: o preço da planilha é por 1 m², com faturamento mínimo de 1 m² por peça
  if prod.tamanho_mm = '1000 x 1000' or prod.tamanho_mm ilike '%metro%' or prod.descricao ilike '%metro quadrado%' or prod.descricao ilike '%(m²)%' then
    v_e_m2 := true;
    if v_largura_mm is not null and v_altura_mm is not null then
      v_area_m2 := round((v_largura_mm::numeric * v_altura_mm::numeric) / 1000000.0, 3);
      if v_area_m2 < 1.000 then v_area_m2 := 1.000; v_avisos := array_append(v_avisos, 'faturamento_minimo_1m2'); end if;
    end if;
  end if;

  v_custo_item := prod.custo * v_area_m2 * v_qtd;
  v_custo_total := v_custo_item + v_outros_custo;
  v_extra := private.custos_operacionais(p_contexto ->> 'entrega');
  v_preco := prod.preco_venda * v_area_m2 * v_qtd;
  if v_area_m2 <> 1 or v_qtd > 1 then v_preco := private.teto_90(v_preco); end if;

  -- piso da planilha: custo x 1,5 e lucro bruto mínimo por pedido; piso duro: lucro líquido zero (nunca prejuízo)
  v_piso := ceil(greatest(v_custo_item * pr.multiplicador_piso, v_custo_item + pr.lucro_bruto_minimo) * 100) / 100;
  v_piso_duro := ceil((private.receita_para_lucro(v_custo_total, v_extra, 0, v_metodo) - v_outros_receita) * 100) / 100;
  if v_preco < v_piso then
    v_preco := private.teto_90(v_piso); v_regra := 'piso'; v_avisos := array_append(v_avisos, 'planilha_abaixo_do_piso');
  end if;
  if v_preco < v_piso_duro then
    v_preco := private.teto_90(v_piso_duro); v_regra := 'piso'; v_avisos := array_append(v_avisos, 'planilha_abaixo_do_piso_duro');
  end if;

  v_receita := v_preco + v_outros_receita;
  v_lucro := private.lucro(v_receita, v_custo_total, v_extra, v_metodo);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku, 'quantidade', v_qtd,
    'preco_unitario', round(v_preco / v_qtd, 2), 'preco_total', v_preco,
    'calculado_por_m2', v_e_m2, 'area_m2_por_unidade', v_area_m2,
    'largura_mm', v_largura_mm, 'altura_mm', v_altura_mm,
    'regra', v_regra, 'confianca', 'alta',
    'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1), 'lucro_liquido', v_lucro,
    'lucro_bruto', round(v_preco - v_custo_item, 2),
    'lucro_ok', v_lucro >= 0 and v_preco - v_custo_item >= pr.lucro_bruto_minimo - 0.05,
    'piso', round(v_piso, 2), 'piso_duro', round(v_piso_duro, 2),
    'nao_competitivo', false, 'fontes_mercado', 0,
    'mercado_mediana', round(prod.preco_mercado_ref * v_area_m2 * v_qtd, 2),
    'consulta_mercado_id', null, 'fator_competitivo', null, 'ancora_vendas', null,
    'avisos', to_jsonb(v_avisos));
end;
$function$;

-- 7) montar_opcoes: usa o "lucro_ok" de calcular_preco (planilha: lucro bruto mínimo; mercado: lucro líquido mínimo)
create or replace function public.montar_opcoes(p_contact uuid, p_sku text, p_quantidade integer default null::integer)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  base record; r record; v_pr jsonb; v_min numeric; v_grupo uuid := gen_random_uuid(); v_ops jsonb := '[]'::jsonb; v_lista jsonb := '[]'::jsonb;
  v_idx integer; v_n integer; v_rot text; v_dif text; v_prazo jsonb; v_pos integer; v_base_preco numeric;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into base from public.catalogo where sku = p_sku and active and vendavel;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'sku_invalido'); end if;
  select lucro_liquido_minimo into v_min from public.parametros_comerciais where id = 1;
  for r in
    select c.sku, c.descricao, c.quantidade, c.gramatura_g, c.tamanho_mm, c.cores
      from public.catalogo c
     where c.active and c.vendavel and c.grupo_produto = base.grupo_produto and c.tamanho_mm is not distinct from base.tamanho_mm and c.cores is not distinct from base.cores
  loop
    v_pr := public.calcular_preco(r.sku, 1, '{}'::jsonb);
    continue when not coalesce((v_pr ->> 'ok')::boolean, false);
    continue when not coalesce((v_pr ->> 'lucro_ok')::boolean, (v_pr ->> 'lucro_liquido')::numeric >= v_min - 0.05)
               or (v_pr ->> 'preco_total')::numeric < (v_pr ->> 'piso')::numeric;
    v_lista := v_lista || jsonb_build_array(jsonb_build_object('sku', r.sku, 'quantidade', r.quantidade, 'gram', r.gramatura_g, 'preco', (v_pr ->> 'preco_total')::numeric,
      'lucro', (v_pr ->> 'lucro_liquido')::numeric, 'descricao', r.descricao));
  end loop;
  select jsonb_agg(e order by (e ->> 'preco')::numeric) into v_lista from jsonb_array_elements(v_lista) e;
  v_n := coalesce(jsonb_array_length(v_lista), 0);
  select ord - 1 into v_pos from jsonb_array_elements(coalesce(v_lista, '[]'::jsonb)) with ordinality t(e, ord) where e ->> 'sku' = p_sku;
  if v_pos is null then return jsonb_build_object('ok', false, 'motivo', 'item_pedido_nao_passou_na_margem'); end if;
  v_base_preco := (v_lista -> v_pos ->> 'preco')::numeric;
  for v_idx in greatest(v_pos - 1, 0) .. least(v_pos + 1, v_n - 1) loop
    v_rot := case when v_idx < v_pos then 'economica' when v_idx > v_pos then 'premium' else 'intermediaria' end;
    r := null;
    select (v_lista -> v_idx ->> 'sku') as sku, (v_lista -> v_idx ->> 'quantidade')::int as quantidade, (v_lista -> v_idx ->> 'gram')::int as gram,
           (v_lista -> v_idx ->> 'preco')::numeric as preco, (v_lista -> v_idx ->> 'lucro')::numeric as lucro into r;
    v_dif := case when v_rot = 'intermediaria' then 'a que você pediu'
                  when r.quantidade is distinct from base.quantidade and r.gram is distinct from base.gramatura_g then format('%s un. e papel de %s g', r.quantidade, r.gram)
                  when r.quantidade is distinct from base.quantidade then format('%s un. em vez de %s', r.quantidade, base.quantidade)
                  when r.gram is distinct from base.gramatura_g then format('papel de %s g em vez de %s g', r.gram, base.gramatura_g)
                  else 'outra configuração' end;
    if v_rot <> 'intermediaria' and r.quantidade is not distinct from base.quantidade and r.gram is not distinct from base.gramatura_g then continue; end if;
    v_prazo := public.calcular_prazo(r.sku, now(), false);
    insert into public.orcamento_opcoes (grupo_id, contact_id, rotulo, sku, quantidade, preco_total, lucro_pior_caso, diferenca, recomendada)
    values (v_grupo, p_contact, v_rot, r.sku, r.quantidade, r.preco, r.lucro, v_dif, v_rot = 'intermediaria');
    v_ops := v_ops || jsonb_build_array(jsonb_build_object('rotulo', v_rot, 'recomendada', v_rot = 'intermediaria', 'quantidade', r.quantidade, 'preco_total', r.preco,
      'diferenca', v_dif, 'pronto', v_prazo ->> 'data_pronto_texto', 'sku', r.sku));
  end loop;
  return jsonb_build_object('ok', true, 'grupo_id', v_grupo, 'opcoes', v_ops,
    'orientacao', 'Apresente de forma curta, a recomendada primeiro e em destaque, sem inventar diferenças além das listadas. Se só houver uma opção, apresente só ela.');
end;
$function$;

-- 8) validar_margem: no modo planilha o lucro mínimo é o bruto (preço dos itens menos custo), como na planilha;
--    prejuízo e piso duro continuam bloqueando sempre.
create or replace function public.validar_margem(p_orcamento uuid)
returns jsonb language plpgsql stable set search_path = '' as $function$
declare
  o public.orcamentos%rowtype;
  pr public.parametros_comerciais%rowtype;
  f jsonb;
  v_maxpct numeric;
  v_motivos text[] := '{}';
  v_alt text := null;
  v_lucro numeric; v_receita numeric;
  v_item_piso_duro boolean; v_item_piso boolean;
  v_cond record;
  v_aprovado boolean;
  v_lucro_curto boolean;
begin
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return jsonb_build_object('status', 'bloqueado', 'motivo', 'orcamento_nao_encontrado'); end if;
  select * into pr from public.parametros_comerciais where id = 1;
  f := private.orcamento_financeiro(p_orcamento);
  v_aprovado := o.aprovado_dono_em is not null;
  v_lucro := (f ->> 'lucro')::numeric;
  v_receita := (f ->> 'receita')::numeric;

  if (f ->> 'itens')::integer = 0 then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'orcamento_sem_itens', 'motivos', jsonb_build_array('orcamento_sem_itens'),
                              'alternativa', 'Adicione ao menos um item com SKU ao orçamento.');
  end if;
  if (f ->> 'itens_sem_produto')::integer > 0 then
    v_motivos := array_append(v_motivos, 'item_sem_sku_valido');
  end if;

  select coalesce(bool_or(i.quantidade * i.preco_unitario * (1 - pr.imposto_pct / 100 - (private.taxa_pagamento(o.metodo_previsto) ->> 'pct')::numeric / 100) < p.cost * i.quantidade), false),
         coalesce(bool_or(i.quantidade * i.preco_unitario < p.cost * i.quantidade * pr.multiplicador_piso), false)
    into v_item_piso_duro, v_item_piso
  from public.orcamento_itens i join public.products p on p.code = i.sku
  where i.orcamento_id = p_orcamento;

  if v_item_piso_duro then v_motivos := array_append(v_motivos, 'item_abaixo_do_piso_duro'); end if;
  if v_lucro < 0 then v_motivos := array_append(v_motivos, 'prejuizo'); end if;
  if not v_aprovado then
    if v_item_piso then v_motivos := array_append(v_motivos, 'item_abaixo_do_piso'); end if;
    if (f ->> 'receita_itens_liquida')::numeric < (f ->> 'custo')::numeric * pr.multiplicador_piso then
      v_motivos := array_append(v_motivos, 'conjunto_abaixo_do_piso');
    end if;
    v_lucro_curto := case when pr.fonte_preco = 'planilha'
      then (f ->> 'receita_itens_liquida')::numeric - (f ->> 'custo')::numeric < pr.lucro_bruto_minimo - 0.005
      else v_lucro < pr.lucro_liquido_minimo end;
    if v_lucro >= 0 and v_lucro_curto then v_motivos := array_append(v_motivos, 'lucro_abaixo_do_minimo'); end if;
  end if;

  if o.desconto_valor > 0 then
    select max(percentual) into v_maxpct from public.politica_desconto where tipo = 'desconto' and ativo;
    select c.valor into v_cond from public.condicoes_especiais c
      where (c.orcamento_id = o.id or c.orcamento_novo_id = o.id) and c.tipo = 'desconto' and c.resultado in ('oferecida', 'aceita') and c.valida_ate > now()
      order by c.criado_em desc limit 1;
    if not found then
      v_motivos := array_append(v_motivos, 'desconto_sem_condicao_especial');
    elsif o.desconto_valor > v_cond.valor + 0.005 then
      v_motivos := array_append(v_motivos, 'desconto_acima_do_teto');
    end if;
    if (f ->> 'subtotal')::numeric > 0 and o.desconto_valor / (f ->> 'subtotal')::numeric * 100 > coalesce(v_maxpct, 10) + 0.005 then
      v_motivos := array_append(v_motivos, 'desconto_acima_do_percentual_maximo');
    end if;
  end if;

  if cardinality(v_motivos) > 0 then
    v_alt := case
      when v_motivos && array['desconto_sem_condicao_especial', 'desconto_acima_do_teto', 'desconto_acima_do_percentual_maximo']
        then 'Remover o desconto ou usar a condição especial calculada pela função.'
      when v_motivos && array['item_sem_sku_valido'] then 'Trocar o item por um SKU existente no catálogo.'
      else format('Subir o total para pelo menos %s ou simplificar a especificação.', private.brl((f ->> 'receita_piso')::numeric))
      end;
    return jsonb_build_object('status', 'bloqueado', 'motivo', v_motivos[1], 'motivos', to_jsonb(v_motivos), 'alternativa', v_alt,
                              'lucro_liquido', v_lucro, 'receita', v_receita, 'receita_minima', (f ->> 'receita_piso')::numeric,
                              'receita_piso_duro', (f ->> 'receita_piso_duro')::numeric);
  end if;
  return jsonb_build_object('status', 'ok', 'lucro_liquido', v_lucro, 'receita', v_receita,
                            'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1),
                            'aprovado_pelo_dono', v_aprovado);
end;
$function$;
