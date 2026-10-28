-- Agente de IA, Etapa 3 (1/2): preço sob demanda, cache de mercado, aprendizado e autoridade do preço.
-- Aditiva e idempotente. NÃO faz pesquisa em massa: a pesquisa acontece só quando um orçamento precisa dela.
-- Nada daqui expõe custo, piso ou margem ao cliente: tudo é RLS só do dono + funções que conferem a permissão.

-- ---------------------------------------------------------------- 1. parâmetros novos (nunca no código)
alter table public.parametros_comerciais
  add column if not exists pesquisa_timeout_s smallint not null default 45 check (pesquisa_timeout_s between 10 and 120),
  add column if not exists cache_mercado_negativo_min smallint not null default 30 check (cache_mercado_negativo_min >= 0),
  add column if not exists aprendizado_min_orcamentos smallint not null default 8 check (aprendizado_min_orcamentos >= 1),
  add column if not exists aprendizado_conversao_min numeric(4, 3) not null default 0.15 check (aprendizado_conversao_min between 0 and 1),
  add column if not exists aprendizado_conversao_max numeric(4, 3) not null default 0.45 check (aprendizado_conversao_max between 0 and 1),
  add column if not exists aprendizado_passo numeric(4, 3) not null default 0.01 check (aprendizado_passo between 0.001 and 0.05),
  add column if not exists meta_margem_liquida_pct numeric(5, 1) not null default 20 check (meta_margem_liquida_pct between 0 and 90),
  add column if not exists desconto_alerta_consumo_margem_pct numeric(5, 1) not null default 40 check (desconto_alerta_consumo_margem_pct between 0 and 100),
  add column if not exists aquecer_cache_ligado boolean not null default false,
  add column if not exists aquecer_cache_grupos text[] not null default '{}';
update public.parametros_comerciais
   set campos_revisar = (select array_agg(distinct x) from unnest(campos_revisar || array['meta_margem_liquida_pct', 'aprendizado_min_orcamentos']) x)
 where id = 1 and not (campos_revisar @> array['meta_margem_liquida_pct']);

-- ---------------------------------------------------------------- 2. fator competitivo por grupo e histórico de ajustes
create table if not exists public.fatores_competitivos (
  grupo_produto text primary key,
  fator numeric(4, 3) not null default 0.930 check (fator between 0.900 and 0.980),
  atualizado_em timestamptz not null default now(),
  atualizado_por text not null default 'carga_inicial'
);
create table if not exists public.ajustes_fator_preco (
  id uuid primary key default gen_random_uuid(),
  grupo_produto text not null,
  fator_antes numeric(4, 3) not null,
  fator_depois numeric(4, 3) not null,
  conversao numeric(6, 3) not null,
  orcamentos integer not null,
  motivo text not null,
  criado_em timestamptz not null default now()
);
create index if not exists ajustes_fator_preco_grupo_idx on public.ajustes_fator_preco (grupo_produto, criado_em desc);

-- ---------------------------------------------------------------- 3. consultas de mercado, fontes permitidas e limite de taxa por domínio
create table if not exists public.consultas_preco_mercado (
  id uuid primary key default gen_random_uuid(),
  chave_especificacao text not null,
  sku text references public.catalogo (sku) on delete set null,
  especificacao jsonb not null default '{}'::jsonb,
  status text not null default 'pendente' check (status in ('pendente', 'concluida', 'sem_dado', 'erro', 'cache')),
  confianca text check (confianca in ('alta', 'media', 'baixa')),
  mediana numeric(12, 2),
  minimo numeric(12, 2),
  maximo numeric(12, 2),
  fontes_validas smallint not null default 0,
  duracao_ms integer,
  tokens_usados integer not null default 0,
  requisicoes smallint not null default 0,
  erro text,
  criado_em timestamptz not null default now(),
  concluido_em timestamptz
);
create index if not exists consultas_preco_mercado_chave_idx on public.consultas_preco_mercado (chave_especificacao, criado_em desc);
alter table public.consultas_preco_mercado add column if not exists tokens_usados integer not null default 0;
alter table public.consultas_preco_mercado add column if not exists requisicoes smallint not null default 0;

create table if not exists public.fontes_pesquisa (
  dominio text primary key,
  nome text not null,
  tipo text not null default 'concorrente_online' check (tipo in ('concorrente_online', 'grafica_bh', 'busca')),
  prioridade smallint not null default 100,
  ativo boolean not null default true,
  exige_navegador boolean not null default false,
  robots_ok boolean,
  robots_conferido_em date,
  termos_ok boolean,
  intervalo_s smallint not null default 10 check (intervalo_s >= 1),
  ultimo_acesso timestamptz,
  observacao text
);
insert into public.fontes_pesquisa (dominio, nome, tipo, prioridade, exige_navegador, robots_ok, robots_conferido_em, termos_ok, intervalo_s, observacao) values
  ('www.alfacards.com.br', 'AlfaCards', 'concorrente_online', 1, true, true, '2026-10-28', null, 15,
   'robots.txt libera tudo (User-agent: * Allow: /). Os preços aparecem na página do produto só depois do JavaScript (calculadora pública), então precisa de navegador. Nenhuma página de termos de uso foi encontrada: confirmar com o dono. Sem login, sem carrinho, sem API privada.')
on conflict (dominio) do nothing;

-- Reserva a vez de acessar um domínio: respeita ativo, robots e o intervalo mínimo entre requisições.
create or replace function public.reservar_acesso_dominio(p_dominio text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare f public.fontes_pesquisa%rowtype; v_espera numeric;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into f from public.fontes_pesquisa where dominio = lower(p_dominio) for update;
  if not found then
    insert into public.fontes_pesquisa (dominio, nome, ativo, robots_ok, observacao)
    values (lower(p_dominio), lower(p_dominio), true, null, 'Domínio novo: conferir robots.txt e termos antes de ligar.')
    on conflict do nothing;
    return jsonb_build_object('permitido', false, 'motivo', 'dominio_novo_nao_conferido');
  end if;
  if not f.ativo then return jsonb_build_object('permitido', false, 'motivo', 'dominio_desligado'); end if;
  if f.robots_ok is distinct from true then return jsonb_build_object('permitido', false, 'motivo', 'robots_nao_conferido_ou_proibido'); end if;
  if f.termos_ok is false then return jsonb_build_object('permitido', false, 'motivo', 'termos_proibem'); end if;
  v_espera := case when f.ultimo_acesso is null then 0 else greatest(0, f.intervalo_s - extract(epoch from (now() - f.ultimo_acesso))) end;
  if v_espera > 0 then return jsonb_build_object('permitido', false, 'motivo', 'limite_de_taxa', 'esperar_s', ceil(v_espera)); end if;
  update public.fontes_pesquisa set ultimo_acesso = now() where dominio = f.dominio;
  return jsonb_build_object('permitido', true, 'exige_navegador', f.exige_navegador);
end;
$$;

-- ---------------------------------------------------------------- 4. precos_mercado: fontes, normalização e expiração
alter table public.precos_mercado add column if not exists consulta_id uuid references public.consultas_preco_mercado (id) on delete set null;
alter table public.precos_mercado add column if not exists especificacao jsonb not null default '{}'::jsonb;
alter table public.precos_mercado add column if not exists normalizado boolean not null default true;
alter table public.precos_mercado add column if not exists expira_em timestamptz;
alter table public.precos_mercado add column if not exists texto_origem text;
alter table public.precos_mercado add column if not exists motivo_descarte text;
alter table public.precos_mercado add column if not exists invalidado_em timestamptz;
create index if not exists precos_mercado_cache_valido_idx on public.precos_mercado (chave_especificacao, coletado_em desc) where invalidado_em is null and not outlier;

-- O orçamento guarda de onde saiu cada preço (regra, confiança, margem e mercado).
alter table public.orcamento_itens add column if not exists preco_mercado_id uuid references public.precos_mercado (id) on delete set null;
alter table public.orcamento_itens add column if not exists consulta_mercado_id uuid references public.consultas_preco_mercado (id) on delete set null;
alter table public.orcamento_itens add column if not exists mercado_mediana numeric(12, 2);
alter table public.orcamento_itens add column if not exists fontes_mercado smallint;
alter table public.orcamento_itens add column if not exists nao_competitivo boolean not null default false;
alter table public.orcamento_itens add column if not exists piso numeric(12, 2);
alter table public.orcamento_itens add column if not exists piso_duro numeric(12, 2);
alter table public.orcamento_itens add column if not exists lucro_liquido numeric(12, 2);

-- ---------------------------------------------------------------- 5. cache de mercado (a ferramenta chama primeiro esta função)
create or replace function public.consultar_cache_preco_mercado(p_sku text, p_especificacao jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype; c record; v_chave text; v_consulta uuid; v_reg record; v_spec jsonb; v_neg record;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  select * into c from public.catalogo where sku = p_sku and active;
  if not found then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  v_chave := coalesce(nullif(c.especificacao_normalizada, ''), c.sku);
  -- especificação normalizada vem do catálogo, nunca do que o agente digitou; o que o chamador mandar só complementa
  v_spec := coalesce(p_especificacao, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
    'grupo', c.grupo_produto, 'descricao', c.descricao, 'quantidade', c.quantidade, 'gramatura_g', c.gramatura_g,
    'tamanho_mm', c.tamanho_mm, 'cores', c.cores, 'especificacao_normalizada', v_chave));

  select (percentile_cont(0.5) within group (order by m.preco))::numeric as mediana, min(m.preco) as minimo, max(m.preco) as maximo,
         count(distinct m.fonte) as fontes, max(m.coletado_em) as coletado_em
    into v_reg
    from public.precos_mercado m
   where (m.chave_especificacao = v_chave or m.sku = p_sku) and m.normalizado and not m.outlier and m.invalidado_em is null
     and m.coletado_em >= now() - make_interval(days => pr.idade_max_pesquisa_dias);
  if v_reg.fontes > 0 then
    insert into public.consultas_preco_mercado (sku, chave_especificacao, especificacao, status, confianca, mediana, minimo, maximo, fontes_validas, duracao_ms, concluido_em)
    values (p_sku, v_chave, v_spec, 'cache', case when v_reg.fontes >= 3 then 'alta' when v_reg.fontes = 2 then 'media' else 'baixa' end,
            v_reg.mediana, v_reg.minimo, v_reg.maximo, v_reg.fontes, 0, now());
    return jsonb_build_object('ok', true, 'cache', true, 'precisa_pesquisar', false, 'chave_especificacao', v_chave,
      'mediana', round(v_reg.mediana, 2), 'minimo', v_reg.minimo, 'maximo', v_reg.maximo, 'fontes', v_reg.fontes,
      'confianca', case when v_reg.fontes >= 3 then 'alta' when v_reg.fontes = 2 then 'media' else 'baixa' end,
      'coletado_em', v_reg.coletado_em);
  end if;

  -- pesquisa já em andamento (últimos 90 s): não dispara outra
  select id into v_consulta from public.consultas_preco_mercado
   where chave_especificacao = v_chave and status = 'pendente' and criado_em > now() - interval '90 seconds' order by criado_em desc limit 1;
  if found then return jsonb_build_object('ok', true, 'cache', false, 'precisa_pesquisar', false, 'em_andamento', true, 'consulta_id', v_consulta, 'chave_especificacao', v_chave); end if;

  -- pesquisa recente sem resultado: não insiste por alguns minutos (limite de taxa e economia)
  select status, concluido_em into v_neg from public.consultas_preco_mercado
   where chave_especificacao = v_chave and status in ('sem_dado', 'erro') and concluido_em > now() - make_interval(mins => pr.cache_mercado_negativo_min)
   order by concluido_em desc limit 1;
  if found then return jsonb_build_object('ok', true, 'cache', true, 'precisa_pesquisar', false, 'sem_dado', true, 'chave_especificacao', v_chave); end if;

  insert into public.consultas_preco_mercado (sku, chave_especificacao, especificacao) values (p_sku, v_chave, v_spec) returning id into v_consulta;
  return jsonb_build_object('ok', true, 'cache', false, 'precisa_pesquisar', true, 'consulta_id', v_consulta, 'chave_especificacao', v_chave,
    'especificacao', v_spec, 'timeout_s', pr.pesquisa_timeout_s);
end;
$$;

-- ---------------------------------------------------------------- 6. gravar o resultado da pesquisa (mediana, mínimo, máximo, outliers e confiança)
create or replace function public.registrar_pesquisa_mercado(
  p_consulta uuid, p_fontes jsonb, p_duracao_ms integer default null, p_erro text default null,
  p_tokens integer default 0, p_requisicoes integer default 0
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  c public.consultas_preco_mercado%rowtype; pr public.parametros_comerciais%rowtype;
  f jsonb; v_preco numeric; v_mediana numeric; v_min numeric; v_max numeric; v_n integer; v_mad numeric; v_conf text; v_outliers integer := 0;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão para registrar pesquisa.' using errcode = '42501'; end if;
  select * into c from public.consultas_preco_mercado where id = p_consulta for update;
  if not found then raise exception 'Consulta não encontrada.' using errcode = 'P0001'; end if;
  if c.status <> 'pendente' then return jsonb_build_object('ok', true, 'status', c.status); end if;
  select * into pr from public.parametros_comerciais where id = 1;

  -- uma linha por fonte (a primeira vence); só entra preço da MESMA especificação
  for f in select * from jsonb_array_elements(coalesce(p_fontes, '[]'::jsonb)) loop
    v_preco := case when coalesce(f ->> 'preco', '') ~ '^[0-9]+(\.[0-9]+)?$' then (f ->> 'preco')::numeric end;
    if v_preco is not null and v_preco > 0 and coalesce((f ->> 'mesma_especificacao')::boolean, false)
       and not exists (select 1 from public.precos_mercado x where x.consulta_id = c.id and x.fonte = coalesce(nullif(f ->> 'fonte', ''), 'fonte_sem_nome')) then
      insert into public.precos_mercado (consulta_id, sku, chave_especificacao, descricao, quantidade, fonte, url, preco, especificacao, normalizado, texto_origem, expira_em)
      values (c.id, c.sku, c.chave_especificacao, left(f ->> 'descricao', 300), nullif(f ->> 'quantidade', '')::integer,
              coalesce(nullif(f ->> 'fonte', ''), 'fonte_sem_nome'), left(nullif(f ->> 'url', ''), 500), v_preco, c.especificacao, true,
              left(coalesce(f ->> 'texto', ''), 1000), now() + make_interval(days => pr.idade_max_pesquisa_dias));
    end if;
  end loop;
  select percentile_cont(0.5) within group (order by preco), min(preco), max(preco), count(*)
    into v_mediana, v_min, v_max, v_n from public.precos_mercado where consulta_id = c.id and normalizado and not outlier;
  -- outliers: mais de 3 desvios absolutos da mediana (MAD) ou, com 3 ou 4 fontes, fora de 0,5x a 2x a mediana
  if v_n >= 3 then
    select percentile_cont(0.5) within group (order by abs(preco - v_mediana)) into v_mad from public.precos_mercado where consulta_id = c.id and normalizado and not outlier;
    update public.precos_mercado set outlier = true, motivo_descarte = 'outlier'
     where consulta_id = c.id and normalizado and not outlier
       and ((coalesce(v_mad, 0) > 0 and abs(preco - v_mediana) > 3 * 1.4826 * v_mad) or preco < v_mediana * 0.5 or preco > v_mediana * 2);
    get diagnostics v_outliers = row_count;
    select percentile_cont(0.5) within group (order by preco), min(preco), max(preco), count(*)
      into v_mediana, v_min, v_max, v_n from public.precos_mercado where consulta_id = c.id and normalizado and not outlier;
  end if;
  v_conf := case when v_n >= 3 then 'alta' when v_n = 2 then 'media' when v_n = 1 then 'baixa' end;
  update public.precos_mercado set confianca = v_conf where consulta_id = c.id and not outlier;
  update public.consultas_preco_mercado
     set status = case when v_n = 0 then case when p_erro is null then 'sem_dado' else 'erro' end else 'concluida' end,
         confianca = v_conf, mediana = round(v_mediana, 2), minimo = v_min, maximo = v_max, fontes_validas = v_n,
         duracao_ms = p_duracao_ms, erro = left(p_erro, 500), tokens_usados = greatest(coalesce(p_tokens, 0), 0),
         requisicoes = least(greatest(coalesce(p_requisicoes, 0), 0), 32000), concluido_em = now()
   where id = c.id;
  return jsonb_build_object('ok', true, 'status', case when v_n = 0 then 'sem_dado' else 'concluida' end,
    'mediana', round(v_mediana, 2), 'minimo', v_min, 'maximo', v_max, 'confianca', v_conf, 'fontes', v_n, 'outliers', v_outliers);
end;
$$;

-- ---------------------------------------------------------------- 7. calcular_preco: mercado, fator por grupo, âncora de vendas e travas
-- Ordem: custo -> piso e piso_duro -> alvo (mercado x fator, ou âncora, ou custo x multiplicador) -> nunca abaixo do piso.
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
  v_mediana numeric; v_n integer; v_fator numeric; v_alvo numeric; v_preco numeric;
  v_ancora numeric; v_n_vendas integer; v_consulta uuid;
  v_regra text; v_conf text; v_nao_comp boolean := false; v_receita numeric; v_lucro numeric;
  v_avisos text[] := '{}';
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select c.custo, c.active, c.vendavel, c.grupo_produto, c.especificacao_normalizada into prod from public.catalogo c where c.sku = p_sku;
  if not found or not prod.active then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  if not prod.vendavel then return jsonb_build_object('ok', false, 'erro', 'item_nao_vendavel'); end if;

  v_custo_item := prod.custo * v_qtd;
  v_custo_total := v_custo_item + v_outros_custo;
  v_extra := private.custos_operacionais(p_contexto ->> 'entrega');
  v_piso := ceil(greatest(v_custo_item * pr.multiplicador_piso,
                          private.receita_para_lucro(v_custo_total, v_extra, pr.lucro_liquido_minimo, v_metodo) - v_outros_receita) * 100) / 100;
  v_piso_duro := ceil((private.receita_para_lucro(v_custo_total, v_extra, 0, v_metodo) - v_outros_receita) * 100) / 100;
  v_base := private.arredonda_90(v_custo_item * private.multiplicador_faixa(v_custo_item));

  -- mercado válido: mesma especificação, normalizado, sem outlier, dentro da idade máxima
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

  -- âncora: 3 ou mais vendas do mesmo SKU nos últimos 90 dias; média ponderada pela recência (preço por unidade do SKU)
  select count(*), sum((p.preco_total / p.quantidade) * w) / nullif(sum(w), 0) into v_n_vendas, v_ancora
    from (select pp.preco_total, pp.quantidade, 1.0 / (1 + extract(epoch from (now() - pp.criado_em)) / 86400 / 30) as w
            from public.precos_praticados pp
           where pp.sku = p_sku and pp.resultado = 'ganho' and pp.criado_em >= now() - interval '90 days' and pp.preco_total > 0) p;
  if coalesce(v_n_vendas, 0) < 3 then v_ancora := null; end if;

  if v_n > 0 then
    v_alvo := v_mediana * v_qtd * v_fator;
    v_regra := 'mercado';
    if v_ancora is not null then
      v_alvo := (v_alvo + least(v_ancora, v_mediana) * v_qtd) / 2;     -- a âncora nunca passa do mercado
      v_regra := 'mercado_com_ancora_vendas';
    end if;
    v_alvo := private.arredonda_90(v_alvo);
    v_conf := case when v_n >= 3 then 'alta' when v_n = 2 then 'media' else 'baixa' end;
    if v_n = 1 then v_avisos := array_append(v_avisos, 'mercado_com_uma_fonte'); end if;
  elsif v_ancora is not null then
    v_alvo := private.arredonda_90(v_ancora * v_qtd);
    v_regra := 'historico_vendas'; v_conf := 'media';
  else
    v_alvo := v_base; v_regra := 'custo_x_multiplicador'; v_conf := 'baixa';
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
  -- trava final: jamais abaixo do piso duro, mesmo que alguém altere a fórmula acima
  if v_preco < v_piso_duro then v_preco := private.teto_90(v_piso_duro); end if;

  v_receita := v_preco + v_outros_receita;
  v_lucro := private.lucro(v_receita, v_custo_total, v_extra, v_metodo);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku, 'quantidade', v_qtd,
    'preco_unitario', round(v_preco / v_qtd, 2), 'preco_total', v_preco,
    'regra', v_regra, 'confianca', v_conf,
    'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1), 'lucro_liquido', v_lucro,
    'piso', round(v_piso, 2), 'piso_duro', round(v_piso_duro, 2),
    'nao_competitivo', v_nao_comp, 'fontes_mercado', v_n, 'mercado_mediana', round(v_mediana * v_qtd, 2),
    'consulta_mercado_id', v_consulta, 'fator_competitivo', v_fator, 'ancora_vendas', round(v_ancora * v_qtd, 2),
    'avisos', to_jsonb(v_avisos));
end;
$$;

-- O agente só enxerga o preço e uma orientação de conversa; piso, custo, margem e mediana ficam de fora.
create or replace function public.agente_preco(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare j jsonb;
begin
  if not private.atendente_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  j := public.calcular_preco(p_sku, p_quantidade, p_contexto);
  if not coalesce((j ->> 'ok')::boolean, false) then return jsonb_build_object('ok', false, 'erro', j ->> 'erro'); end if;
  return jsonb_build_object('ok', true, 'sku', p_sku, 'quantidade', j -> 'quantidade', 'preco_unitario', j -> 'preco_unitario', 'preco_total', j -> 'preco_total',
    'orientacao', case when (j ->> 'nao_competitivo')::boolean
      then 'Este preço está acima do que alguns concorrentes anunciam. Não reduza: destaque arte, agilidade e atendimento, ou sugira uma especificação mais simples.'
      else null end);
end;
$$;

-- ---------------------------------------------------------------- 8. aprendizado: cada orçamento e cada venda em precos_praticados
alter table public.precos_praticados add column if not exists condicao_tipo text;
alter table public.precos_praticados add column if not exists desconto_valor numeric(12, 2) not null default 0;
alter table public.precos_praticados add column if not exists especificacao_normalizada text;
drop index if exists public.precos_praticados_orc_sku_uniq;
create unique index if not exists precos_praticados_orc_sku_uniq on public.precos_praticados (orcamento_id, sku);

create or replace function private.precos_praticados_sincronizar() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  i record; v_resultado text; v_cond record;
begin
  if new.teste then return new; end if;
  v_resultado := case new.status when 'pago' then 'ganho' when 'perdido' then 'perdido' when 'expirado' then 'expirado' when 'cancelado' then 'perdido' else 'aberto' end;
  if new.origem_id is not null then
    -- orçamento atualizado por condição especial: o resultado vai para o orçamento original (uma conversão só)
    select c.id, c.tipo, c.valor into v_cond from public.condicoes_especiais c where c.orcamento_id = new.origem_id and c.resultado <> 'cancelada' order by c.criado_em desc limit 1;
    if tg_op = 'INSERT' then
      update public.precos_praticados set condicao_especial_id = v_cond.id, condicao_tipo = v_cond.tipo where orcamento_id = new.origem_id;
    elsif new.status is distinct from old.status and new.status = 'pago' then
      update public.precos_praticados set resultado = 'ganho', fechado_em = now(), condicao_especial_id = v_cond.id, condicao_tipo = v_cond.tipo,
             desconto_valor = new.desconto_valor, margem_liquida_pct = coalesce(new.margem_liquida_pct, margem_liquida_pct)
       where orcamento_id = new.origem_id;
    end if;
    return new;
  end if;
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    for i in select oi.*, c.grupo_produto, c.especificacao_normalizada as espec
               from public.orcamento_itens oi left join public.catalogo c on c.sku = oi.sku where oi.orcamento_id = new.id loop
      insert into public.precos_praticados (orcamento_id, contact_id, sku, grupo_produto, especificacao_normalizada, quantidade, preco_total, margem_liquida_pct, regra_preco, resultado, fechado_em)
      values (new.id, new.contact_id, i.sku, coalesce(i.grupo_produto, ''), i.espec, i.quantidade, i.preco_unitario * i.quantidade, i.margem_liquida_pct, i.regra_preco,
              v_resultado, case when v_resultado = 'aberto' then null else now() end)
      on conflict (orcamento_id, sku) do update
        set resultado = excluded.resultado, fechado_em = excluded.fechado_em, preco_total = excluded.preco_total, margem_liquida_pct = excluded.margem_liquida_pct;
    end loop;
  end if;
  return new;
end;
$$;
revoke execute on function private.precos_praticados_sincronizar() from public, anon, authenticated;
drop trigger if exists orcamentos_precos_praticados on public.orcamentos;
create trigger orcamentos_precos_praticados after insert or update of status on public.orcamentos
  for each row execute function private.precos_praticados_sincronizar();
-- os itens são gravados depois do orçamento: registra também quando o orçamento sai do rascunho (o INSERT acima já cobre os itens existentes)

-- Aprendizado semanal por grupo: só orçamentos encerrados (ganho, perdido ou expirado) dos últimos 30 dias, fora os de teste.
create or replace function public.aprender_precos_semana(p_simular boolean default false) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r record; pr public.parametros_comerciais%rowtype; v_ajustes jsonb := '[]'::jsonb; v_antes numeric; v_depois numeric; v_conv numeric; v_motivo text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  for r in
    select pp.grupo_produto, count(distinct pp.orcamento_id) as n,
           count(distinct pp.orcamento_id) filter (where pp.resultado = 'ganho') as ganhos,
           avg(pp.margem_liquida_pct) as margem
      from public.precos_praticados pp join public.orcamentos o on o.id = pp.orcamento_id
     where pp.criado_em >= now() - interval '30 days' and pp.resultado <> 'aberto' and not o.teste and coalesce(pp.grupo_produto, '') <> ''
     group by pp.grupo_produto having count(distinct pp.orcamento_id) >= pr.aprendizado_min_orcamentos
  loop
    v_conv := r.ganhos::numeric / r.n;
    select coalesce(f.fator, pr.fator_competitivo) into v_antes from (select 1) x left join public.fatores_competitivos f on f.grupo_produto = r.grupo_produto;
    v_depois := null;
    if v_conv < pr.aprendizado_conversao_min and coalesce(r.margem, 0) > pr.meta_margem_liquida_pct then
      v_depois := greatest(pr.fator_competitivo_min, v_antes - pr.aprendizado_passo);
      v_motivo := format('conversão de %s%% (abaixo de %s%%) com margem líquida de %s%% (acima da meta de %s%%): baixa o fator',
                         round(v_conv * 100, 1), round(pr.aprendizado_conversao_min * 100), round(r.margem, 1), pr.meta_margem_liquida_pct);
    elsif v_conv > pr.aprendizado_conversao_max then
      v_depois := least(pr.fator_competitivo_max, v_antes + pr.aprendizado_passo);
      v_motivo := format('conversão de %s%% (acima de %s%%): sobe o fator', round(v_conv * 100, 1), round(pr.aprendizado_conversao_max * 100));
    end if;
    if v_depois is not null and v_depois <> v_antes then
      if not p_simular then
        insert into public.fatores_competitivos (grupo_produto, fator, atualizado_por) values (r.grupo_produto, v_depois, 'aprendizado')
        on conflict (grupo_produto) do update set fator = excluded.fator, atualizado_em = now(), atualizado_por = 'aprendizado';
        insert into public.ajustes_fator_preco (grupo_produto, fator_antes, fator_depois, conversao, orcamentos, motivo)
        values (r.grupo_produto, v_antes, v_depois, round(v_conv, 3), r.n, v_motivo);
      end if;
      v_ajustes := v_ajustes || jsonb_build_object('grupo', r.grupo_produto, 'antes', v_antes, 'depois', v_depois, 'conversao', round(v_conv, 3), 'orcamentos', r.n, 'motivo', v_motivo);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'simulado', p_simular, 'ajustes', jsonb_array_length(v_ajustes), 'detalhe', v_ajustes);
end;
$$;

-- ---------------------------------------------------------------- 9. Catálogo > Saúde de preços
create or replace view public.saude_precos with (security_invoker = true) as
select coalesce(c.grupo_produto, 'Sem grupo') as grupo_produto,
  count(*) filter (where c.active) as itens_ativos,
  count(*) filter (where c.active and exists (
    select 1 from public.precos_mercado m
     where m.chave_especificacao = coalesce(nullif(c.especificacao_normalizada, ''), c.sku) and m.normalizado and not m.outlier and m.invalidado_em is null
       and m.coletado_em >= now() - interval '14 days')) as cobertura_mercado,
  count(*) filter (where c.status_venda = 'nao_competitivo') as nao_competitivos,
  count(*) filter (where c.status_venda = 'nao_vender') as nao_vender,
  (select avg(pp.margem_liquida_pct) from public.precos_praticados pp where coalesce(pp.grupo_produto, 'Sem grupo') = coalesce(c.grupo_produto, 'Sem grupo') and pp.criado_em >= now() - interval '30 days') as margem_liquida_media,
  (select count(distinct pp.orcamento_id) from public.precos_praticados pp where coalesce(pp.grupo_produto, 'Sem grupo') = coalesce(c.grupo_produto, 'Sem grupo') and pp.criado_em >= now() - interval '30 days') as orcamentos_30d,
  (select count(distinct pp.orcamento_id) from public.precos_praticados pp where coalesce(pp.grupo_produto, 'Sem grupo') = coalesce(c.grupo_produto, 'Sem grupo') and pp.criado_em >= now() - interval '30 days' and pp.resultado = 'ganho') as ganhos_30d,
  (select f.fator from public.fatores_competitivos f where f.grupo_produto = c.grupo_produto) as fator_atual
from public.catalogo c
group by coalesce(c.grupo_produto, 'Sem grupo'), c.grupo_produto;


-- ---------------------------------------------------------------- 9b. aquecer o cache de madrugada (opcional, DESLIGADO por padrão)
-- Devolve só SKUs que já foram orçados nos últimos 60 dias e cujo mercado venceu ou vai vencer; nunca varre o catálogo.
create or replace function public.skus_para_aquecer(p_limite integer default 10) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare pr public.parametros_comerciais%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  if not pr.aquecer_cache_ligado then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('sku', t.sku) order by t.n desc) from (
      select oi.sku, count(*) as n
        from public.orcamento_itens oi
        join public.orcamentos o on o.id = oi.orcamento_id
        join public.catalogo c on c.sku = oi.sku
       where o.criado_em > now() - interval '60 days' and not o.teste and c.active and c.vendavel
         and (cardinality(pr.aquecer_cache_grupos) = 0 or c.grupo_produto = any (pr.aquecer_cache_grupos))
         and not exists (select 1 from public.precos_mercado m
                          where (m.sku = oi.sku or m.chave_especificacao = coalesce(nullif(c.especificacao_normalizada, ''), c.sku))
                            and m.normalizado and not m.outlier and m.invalidado_em is null
                            and m.coletado_em > now() - make_interval(days => greatest(pr.idade_max_pesquisa_dias - 2, 1)))
       group by oi.sku order by count(*) desc limit least(greatest(p_limite, 1), 20)) t), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------- 10. acesso: só dono e service role; nada para o anon
do $$
declare t text;
begin
  foreach t in array array['fatores_competitivos', 'ajustes_fator_preco', 'consultas_preco_mercado', 'fontes_pesquisa'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('drop policy if exists %I on public.%I', t || '_dono', t);
    execute format('create policy %I on public.%I for all to authenticated using (private.is_staff()) with check (private.is_staff())', t || '_dono', t);
  end loop;
end $$;
revoke all on public.saude_precos from anon;
do $$
declare f text;
begin
  foreach f in array array[
    'public.registrar_pesquisa_mercado(uuid,jsonb,integer,text,integer,integer)', 'public.consultar_cache_preco_mercado(text,jsonb)',
    'public.aprender_precos_semana(boolean)', 'public.reservar_acesso_dominio(text)', 'public.skus_para_aquecer(integer)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
