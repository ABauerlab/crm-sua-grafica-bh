-- Etapa 3 do agente: junção das migrations 20261029000006 e 20261029000007 (preço sob demanda, aprendizado, condição especial, política com simulação e edição manual de preço), para colar no SQL Editor do Supabase.
-- Idempotente: pode rodar de novo sem problema. Rode o bloco inteiro de uma vez. Não apaga dados: só adiciona tabelas, colunas e funções e substitui calcular_preco, agente_preco, calcular_condicao_especial e validar_margem.
-- Antes de rodar: backup do projeto (Database > Backups). Depois: supabase/tests/preco_etapa3.sql (67 testes, desfaz tudo) e os advisors de segurança.
-- Pré-requisitos: Etapas 1 e 2 já aplicadas. Gerado por: cat supabase/migrations/2026102900000{6,7}*.sql (mantenha igual às migrations).

-- ================================================================ 20261029000006_etapa3_preco_inteligente.sql
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

-- ================================================================ 20261029000007_etapa3_condicao_especial.sql
-- Agente de IA, Etapa 3 (2/2): condição especial (desconto racional) como ferramenta, expiração, detector de padrões,
-- relatório semanal, política de desconto com simulação do pior caso e edição manual de preço com lucro líquido.
-- Aditiva e idempotente. A aplicar_desconto antiga deixa de existir: toda condição nasce de calcular_condicao_especial.

-- ---------------------------------------------------------------- 1. aplicar_desconto sai de cena (migra o que existir)
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as assinatura from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'aplicar_desconto' loop
    execute format('drop function %s', r.assinatura);
  end loop;
end $$;

-- ---------------------------------------------------------------- 2. colunas de apoio
alter table public.condicoes_especiais add column if not exists substitui_orcamento_id uuid references public.orcamentos (id) on delete set null;
alter table public.condicoes_especiais add column if not exists link_anterior_invalidado_em timestamptz;
alter table public.condicoes_especiais add column if not exists orcamento_novo_id uuid references public.orcamentos (id) on delete set null;
alter table public.condicoes_especiais add column if not exists pct_anterior_pedido numeric(5, 2);
alter table public.condicoes_especiais add column if not exists pct_aplicado_pedido numeric(5, 2);
alter table public.condicoes_especiais add column if not exists link_pagamento text;
alter table public.condicoes_especiais add column if not exists desconto_reais numeric(12, 2) not null default 0;
alter table public.condicoes_especiais add column if not exists lucro_liquido_depois numeric(12, 2);
alter table public.condicoes_especiais add column if not exists lucro_liquido_antes numeric(12, 2);
alter table public.condicoes_especiais add column if not exists expirada_em timestamptz;
create index if not exists condicoes_valida_idx on public.condicoes_especiais (valida_ate) where resultado = 'oferecida';
alter table public.condicoes_especiais drop constraint if exists condicoes_especiais_gatilho_check;
alter table public.condicoes_especiais add constraint condicoes_especiais_gatilho_check check (gatilho in ('G1', 'G2', 'G3'));

create table if not exists public.precos_manuais_log (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  order_item_id uuid,
  sku text,
  preco_antes numeric(12, 2) not null,
  preco_depois numeric(12, 2) not null,
  faixa text not null check (faixa in ('ok', 'entre_pisos')),
  piso numeric(12, 2),
  piso_duro numeric(12, 2),
  lucro_liquido numeric(12, 2),
  motivo text,
  usuario uuid,
  criado_em timestamptz not null default now()
);
create index if not exists precos_manuais_log_order_idx on public.precos_manuais_log (order_id, criado_em desc);
alter table public.precos_manuais_log enable row level security;
revoke all on table public.precos_manuais_log from anon;
drop policy if exists precos_manuais_log_dono on public.precos_manuais_log;
create policy precos_manuais_log_dono on public.precos_manuais_log for all to authenticated using (private.is_staff()) with check (private.is_staff());

-- validar_margem: a condição vale para o orçamento original e para o atualizado que ela gerou
create or replace function public.validar_margem(p_orcamento uuid)
returns jsonb
language plpgsql stable set search_path = ''
as $$
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

  -- sem aprovação possível
  if v_item_piso_duro then v_motivos := array_append(v_motivos, 'item_abaixo_do_piso_duro'); end if;
  if v_lucro < 0 then v_motivos := array_append(v_motivos, 'prejuizo'); end if;
  -- aprovável pelo dono (entre o piso_duro e o piso)
  if not v_aprovado then
    if v_item_piso then v_motivos := array_append(v_motivos, 'item_abaixo_do_piso'); end if;
    if (f ->> 'receita_itens_liquida')::numeric < (f ->> 'custo')::numeric * pr.multiplicador_piso then
      v_motivos := array_append(v_motivos, 'conjunto_abaixo_do_piso');
    end if;
    if v_lucro >= 0 and v_lucro < pr.lucro_liquido_minimo then v_motivos := array_append(v_motivos, 'lucro_abaixo_do_minimo'); end if;
  end if;

  -- política de desconto: só com condição especial vigente, dentro do valor concedido e do teto percentual
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
$$;

-- ---------------------------------------------------------------- 3. calcular_condicao_especial (mesma regra da Etapa 1, lendo o catálogo novo e recusando orçamento vencido)
create or replace function public.calcular_condicao_especial(p_orcamento uuid, p_gatilho text, p_registrar boolean default true)
returns jsonb
language plpgsql set search_path = ''
as $$
declare
  o public.orcamentos%rowtype;
  pr public.parametros_comerciais%rowtype;
  pol public.politica_desconto%rowtype;
  f jsonb; fr jsonb;
  v_custo numeric; v_receita_atual numeric; v_extra numeric; v_extra_bike numeric; v_piso numeric;
  v_gordura numeric; v_base_elegivel numeric; v_cap numeric; v_valor numeric;
  v_tipo text; v_texto text; v_motivo text := 'sem_vantagem_aplicavel';
  v_itens jsonb; v_valida timestamptz; v_id uuid;
  v_outros integer; v_cacador integer; v_max_cond smallint; v_intervalo smallint;
begin
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_nao_encontrado'); end if;
  if p_gatilho not in ('G1', 'G2', 'G3') then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'gatilho_invalido'); end if;
  if o.origem_id is not null then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_ja_e_condicao_especial'); end if;
  if o.validade_ate is not null and o.validade_ate < now() then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_vencido'); end if;
  if o.status = 'rascunho' then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_ainda_nao_enviado'); end if;
  if o.status not in ('enviado', 'aceito') then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_encerrado'); end if;
  select * into pr from public.parametros_comerciais where id = 1;

  select min(max_condicoes_por_orcamento), min(intervalo_dias_contato) into v_max_cond, v_intervalo from public.politica_desconto where ativo;
  if v_max_cond is null then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'politica_desligada'); end if;

  if (select count(*) from public.condicoes_especiais c where c.orcamento_id = o.id and c.resultado <> 'cancelada') >= v_max_cond then
    return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'ja_houve_condicao_neste_orcamento');
  end if;
  if exists (select 1 from public.condicoes_especiais c
             where c.contact_id = o.contact_id and c.orcamento_id <> o.id and c.resultado <> 'cancelada'
               and c.criado_em > now() - make_interval(days => v_intervalo)) then
    return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'intervalo_entre_condicoes_do_contato');
  end if;
  select count(*) into v_cacador from public.orcamentos x
    where x.contact_id = o.contact_id and x.id <> o.id and x.criado_em > now() - make_interval(days => pr.cacador_janela_dias)
      and x.status <> 'rascunho' and not x.teste;
  if v_cacador + 1 >= pr.cacador_min_orcamentos
     and not exists (select 1 from public.orcamentos x where x.contact_id = o.contact_id and x.status = 'pago') then
    return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'cacador_de_desconto', 'sinalizar_dono', true);
  end if;

  f := private.orcamento_financeiro(o.id);
  if (f ->> 'itens')::integer = 0 then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_sem_itens'); end if;
  v_custo := (f ->> 'custo')::numeric;
  v_receita_atual := (f ->> 'subtotal')::numeric + o.arte_valor + o.frete_valor;
  v_extra := (f ->> 'extra')::numeric;
  v_piso := ceil(greatest(v_custo * pr.multiplicador_piso, private.receita_para_lucro(v_custo, v_extra, pr.lucro_liquido_minimo, o.metodo_previsto)) * 100) / 100;
  v_gordura := greatest(v_receita_atual - v_piso, 0);

  -- G1 e G2: vantagem sem custo (degrau 1) e, se não houver, desconto do degrau 2. G3: degrau 3 e, se não couber, a vantagem.
  for pol in
    select * from public.politica_desconto d
    where d.ativo and (p_gatilho = any (d.gatilhos) or (p_gatilho = 'G3' and d.degrau = 1))
    order by case when p_gatilho = 'G3' then (case d.degrau when 3 then 0 else 1 end) else d.degrau end
  loop
    v_tipo := null; v_valor := 0;

    if pol.tipo = 'vantagem' then
      -- frete grátis sem pedido mínimo: região central, cabe na bike, frete hoje cobrado do cliente
      select coalesce(jsonb_agg(jsonb_build_object('sku', i.sku, 'quantidade', i.quantidade)), '[]'::jsonb) into v_itens
        from public.orcamento_itens i where i.orcamento_id = o.id;
      fr := public.verificar_frete(coalesce(o.cep, o.bairro), v_itens, (f ->> 'subtotal')::numeric, false);
      v_extra_bike := private.custos_operacionais('bike');
      if o.frete_valor > 0 and (fr ->> 'regiao_central')::boolean and ((not pr.exigir_cabe_na_bike) or (fr ->> 'cabe_na_bike')::boolean)
         and (v_receita_atual - o.frete_valor) >= ceil(greatest(v_custo * pr.multiplicador_piso, private.receita_para_lucro(v_custo, v_extra_bike, pr.lucro_liquido_minimo, o.metodo_previsto)) * 100) / 100 then
        v_tipo := 'frete_gratis'; v_valor := o.frete_valor; v_texto := 'frete grátis, sem pedido mínimo';
      elsif o.arte_modo = 'paga' and o.arte_valor > 0 and (v_receita_atual - o.arte_valor) >= v_piso then
        v_tipo := 'arte_gratis'; v_valor := o.arte_valor; v_texto := 'criação da arte grátis';
      end if;
    else
      -- desconto: só sobre itens que permitem desconto, limitado pela gordura acima do piso e pelo teto em reais
      select coalesce(sum(i.quantidade * i.preco_unitario) filter (
               where p.permite_desconto and not (coalesce(p.categoria, '') = any (pr.categorias_sem_desconto))
                 and not (coalesce(p.grupo_produto, '') = any (pr.categorias_sem_desconto))), 0)
        into v_base_elegivel
        from public.orcamento_itens i join public.catalogo p on p.sku = i.sku where i.orcamento_id = o.id;
      if v_base_elegivel <= 0 then
        v_motivo := 'itens_sem_permissao_de_desconto';
      elsif v_gordura <= 0 then
        v_motivo := 'sem_gordura_acima_do_piso';
      else
        v_cap := floor(least(v_base_elegivel * pol.percentual / 100, v_gordura * pol.fracao_gordura_max, pol.desconto_max_reais) * 100) / 100;
        if v_cap < pol.valor_minimo_reais then
          v_motivo := 'desconto_menor_que_o_minimo';
        else
          v_tipo := 'desconto'; v_valor := v_cap; v_texto := 'desconto de ' || private.brl(v_cap);
        end if;
      end if;
    end if;

    if v_tipo is not null then
      v_valida := now() + make_interval(hours => pol.validade_horas);
      if p_registrar then
        insert into public.condicoes_especiais (orcamento_id, contact_id, degrau, gatilho, tipo, valor, texto_curto, valida_ate)
        values (o.id, o.contact_id, pol.degrau, p_gatilho, v_tipo, v_valor, v_texto, v_valida) returning id into v_id;
      end if;
      return jsonb_build_object('tipo', v_tipo, 'texto_curto', v_texto, 'valor', v_valor, 'valida_ate', v_valida, 'degrau', pol.degrau, 'condicao_id', v_id);
    end if;
  end loop;

  return jsonb_build_object('tipo', 'sem_condicao', 'motivo', v_motivo);
end;
$$;


-- ---------------------------------------------------------------- 4. oferecer_condicao_especial: a ferramenta do agente (decide, registra, gera orçamento atualizado)
-- O n8n chama esta função com a service role e depois pede o link novo (mp-criar-link, validade = valida_ate).
create or replace function public.oferecer_condicao_especial(p_orcamento uuid, p_gatilho text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb; o public.orcamentos%rowtype; n uuid; cond_id uuid; v_tipo text; v_valor numeric;
  v_gross numeric; v_pct_antes numeric; v_pct numeric; v_check jsonb; v_antes numeric; v_depois numeric; v_horas numeric; v_valida timestamptz;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orcamentos where id = p_orcamento for update;
  if not found then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_nao_encontrado'); end if;

  -- tudo ou nada: se qualquer etapa falhar, a condição e o orçamento novo são desfeitos
  begin
    r := public.calcular_condicao_especial(p_orcamento, p_gatilho, true);
    if r ->> 'tipo' = 'sem_condicao' then
      if coalesce((r ->> 'sinalizar_dono')::boolean, false) and not exists (
           select 1 from public.alertas where tipo = 'cacador_de_desconto' and contact_id = o.contact_id and criado_em > now() - interval '30 days') then
        insert into public.alertas (tipo, gravidade, contact_id, conversation_id, orcamento_id, motivo)
        values ('cacador_de_desconto', 'baixa', o.contact_id, o.conversation_id, o.id,
                'Cliente com vários orçamentos recentes e nenhuma compra pede desconto de novo. Nenhuma condição foi oferecida.');
      end if;
      return r;
    end if;

    cond_id := (r ->> 'condicao_id')::uuid; v_tipo := r ->> 'tipo'; v_valor := (r ->> 'valor')::numeric; v_valida := (r ->> 'valida_ate')::timestamptz;
    v_antes := (private.orcamento_financeiro(o.id) ->> 'lucro')::numeric;

    insert into public.orcamentos (contact_id, conversation_id, order_id, origem_id, status, entrega, bairro, cep, metodo_previsto, arte_modo, arte_valor,
                                   frete_valor, desconto_valor, validade_ate, regra_preco, confianca_preco, teste)
    values (o.contact_id, o.conversation_id, o.order_id, o.id, 'rascunho', o.entrega, o.bairro, o.cep, o.metodo_previsto, o.arte_modo,
            case when v_tipo = 'arte_gratis' then 0 else o.arte_valor end,
            case when v_tipo = 'frete_gratis' then 0 else o.frete_valor end,
            case when v_tipo = 'desconto' then v_valor else o.desconto_valor end,
            v_valida, o.regra_preco, o.confianca_preco, o.teste)
    returning id into n;
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, regra_preco, confianca_preco, margem_liquida_pct,
                                        preco_mercado_id, consulta_mercado_id, mercado_mediana, fontes_mercado, nao_competitivo, piso, piso_duro, lucro_liquido)
      select n, sku, descricao, quantidade, preco_unitario, regra_preco, confianca_preco, margem_liquida_pct,
             preco_mercado_id, consulta_mercado_id, mercado_mediana, fontes_mercado, nao_competitivo, piso, piso_duro, lucro_liquido
        from public.orcamento_itens where orcamento_id = o.id;
    update public.orcamentos set status = 'enviado', validade_ate = v_valida where id = n;     -- as travas de lucro rodam aqui

    update public.condicoes_especiais set orcamento_novo_id = n, substitui_orcamento_id = o.id where id = cond_id;
    v_check := public.validar_margem(n);
    if v_check ->> 'status' <> 'ok' then raise exception 'Condição recusada pela validação de margem: %', v_check ->> 'motivo' using errcode = 'P0001'; end if;
    v_depois := (private.orcamento_financeiro(n) ->> 'lucro')::numeric;
    if v_depois < 0 then raise exception 'Condição recusada: daria prejuízo.' using errcode = 'P0001'; end if;

    -- o pedido ligado passa a cobrar o valor da condição (percentual arredondado PARA BAIXO, nunca concede mais do que a função calculou)
    if v_tipo = 'desconto' and o.order_id is not null then
      select f.gross into v_gross from public.order_financials f where f.order_id = o.order_id;
      select discount_pct into v_pct_antes from public.orders where id = o.order_id and payment_status <> 'aprovado';
      if found and coalesce(v_gross, 0) > 0 then
        v_pct := floor(v_valor / v_gross * 10000) / 100;
        update public.orders set discount_pct = v_pct where id = o.order_id;
        update public.condicoes_especiais set pct_anterior_pedido = v_pct_antes, pct_aplicado_pedido = v_pct where id = cond_id;
      end if;
    end if;
    update public.condicoes_especiais
       set orcamento_novo_id = n, substitui_orcamento_id = o.id, desconto_reais = case when v_tipo = 'desconto' then v_valor else 0 end,
           lucro_liquido_antes = v_antes, lucro_liquido_depois = v_depois
     where id = cond_id;
  exception when others then
    if sqlerrm like 'Condição recusada%' or sqlstate in ('P0001', '23514') then
      raise notice 'condição não gerada para o orçamento %: % (%)', p_orcamento, sqlerrm, sqlstate;
      return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'recusada_pela_trava_de_lucro');
    end if;
    raise;
  end;
  v_horas := round(extract(epoch from (v_valida - now())) / 3600.0, 2);
  return r || jsonb_build_object('orcamento_id', n, 'orcamento_original_id', o.id, 'order_id', o.order_id, 'expira_horas', v_horas);
end;
$$;

-- guarda o link novo da condição (o n8n chama depois de mp-criar-link)
create or replace function public.condicao_registrar_link(p_condicao uuid, p_link text) returns void
language plpgsql security definer set search_path = ''
as $$
declare c public.condicoes_especiais%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into c from public.condicoes_especiais where id = p_condicao for update;
  if not found then raise exception 'Condição não encontrada.' using errcode = 'P0001'; end if;
  update public.condicoes_especiais set link_pagamento = p_link, link_anterior_invalidado_em = now() where id = p_condicao;
  if c.orcamento_novo_id is not null then update public.orcamentos set link_pagamento = p_link where id = c.orcamento_novo_id; end if;
end;
$$;

-- ---------------------------------------------------------------- 5. expiração: o preço volta ao normal e a condição não se repete
create or replace function private.expirar_condicoes_job() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare c record; v_cond integer := 0; v_orc integer; v_links integer := 0;
begin
  for c in select * from public.condicoes_especiais where resultado = 'oferecida' and valida_ate < now() for update skip locked loop
    update public.condicoes_especiais set resultado = 'expirada', expirada_em = now() where id = c.id;
    v_cond := v_cond + 1;
    if c.orcamento_novo_id is not null then
      update public.orcamentos set status = 'expirado' where id = c.orcamento_novo_id and status in ('enviado', 'aceito');
      -- pedido volta ao preço normal (só se o desconto ainda é o da condição e o pedido não foi pago)
      if c.pct_aplicado_pedido is not null then
        update public.orders set discount_pct = coalesce(c.pct_anterior_pedido, 0)
         where id = (select order_id from public.orcamentos where id = c.orcamento_novo_id)
           and payment_status <> 'aprovado' and discount_pct = c.pct_aplicado_pedido;
      end if;
      -- link da condição deixa de valer no banco (o prazo no Mercado Pago já é o mesmo valida_ate)
      update public.pagamentos p set link_ativo = false, status = case when p.mp_payment_id is null then 'invalidado' else p.status end, atualizado_em = now()
       where p.order_id = (select order_id from public.orcamentos where id = c.orcamento_novo_id)
         and p.eh_link and p.link_ativo and p.criado_em >= c.criado_em and p.mp_payment_id is null;
      get diagnostics v_orc = row_count; v_links := v_links + v_orc;
    end if;
  end loop;
  update public.orcamentos set status = 'expirado' where status = 'enviado' and validade_ate < now() and not teste;
  get diagnostics v_orc = row_count;
  return jsonb_build_object('condicoes_expiradas', v_cond, 'orcamentos_expirados', v_orc, 'links_desativados', v_links);
end;
$$;
revoke execute on function private.expirar_condicoes_job() from public, anon, authenticated;

create or replace function public.expirar_condicoes_e_orcamentos() returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return private.expirar_condicoes_job();
end;
$$;

-- condição aceita quando o orçamento atualizado é pago
create or replace function private.condicao_marcar_aceita() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.origem_id is not null and new.status = 'pago' and old.status is distinct from 'pago' then
    update public.condicoes_especiais set resultado = 'aceita' where orcamento_novo_id = new.id and resultado in ('oferecida', 'expirada');
  end if;
  return new;
end;
$$;
revoke execute on function private.condicao_marcar_aceita() from public, anon, authenticated;
drop trigger if exists orcamentos_condicao_aceita on public.orcamentos;
create trigger orcamentos_condicao_aceita after update of status on public.orcamentos for each row execute function private.condicao_marcar_aceita();

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') or true then
    begin
      if exists (select 1 from cron.job where jobname = 'condicoes-expirar') then perform cron.unschedule('condicoes-expirar'); end if;
      perform cron.schedule('condicoes-expirar', '*/10 * * * *', 'select private.expirar_condicoes_job()');
    exception when others then
      raise notice 'pg_cron indisponível: agende private.expirar_condicoes_job() a cada 10 minutos (%).', sqlerrm;
    end;
  end if;
end $$;

-- ---------------------------------------------------------------- 6. detector de padrões incomuns (alerta ao dono)
create or replace function public.detectar_padroes_desconto() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r record; v_n integer := 0;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  -- 3 ou mais condições consumidas (aceitas ou vencidas) e nenhuma compra
  for r in
    select c.contact_id, count(*) as n from public.condicoes_especiais c
     where c.resultado in ('aceita', 'expirada', 'oferecida') and c.criado_em > now() - interval '120 days'
     group by c.contact_id having count(*) >= 3
       and not exists (select 1 from public.orcamentos o where o.contact_id = c.contact_id and o.status = 'pago')
  loop
    if not exists (select 1 from public.alertas a where a.tipo = 'padrao_desconto' and a.contact_id = r.contact_id and a.criado_em > now() - interval '30 days') then
      insert into public.alertas (tipo, gravidade, contact_id, motivo)
      values ('padrao_desconto', 'baixa', r.contact_id, format('%s condições especiais usadas e nenhuma compra. Não ofereça outra sem falar com o dono.', r.n));
      v_n := v_n + 1;
    end if;
  end loop;
  -- cliente que aceitou a condição mais de uma vez em 90 dias (padrão de esperar o desconto)
  for r in
    select c.contact_id, count(*) as n from public.condicoes_especiais c
     where c.resultado = 'aceita' and c.criado_em > now() - interval '90 days' group by c.contact_id having count(*) >= 2
  loop
    if not exists (select 1 from public.alertas a where a.tipo = 'padrao_desconto_recorrente' and a.contact_id = r.contact_id and a.criado_em > now() - interval '30 days') then
      insert into public.alertas (tipo, gravidade, contact_id, motivo)
      values ('padrao_desconto_recorrente', 'baixa', r.contact_id, format('%s compras seguidas só com condição especial em 90 dias.', r.n));
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'alertas_criados', v_n);
end;
$$;

-- ---------------------------------------------------------------- 7. relatório semanal das condições e resumo de preços
create or replace function public.relatorio_condicoes_semana(p_dias integer default 7, p_alertar boolean default false) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype; v_graus jsonb := '[]'::jsonb; g record; v_conv_base numeric; v_tick numeric; v_inc numeric := 0;
  v_consumo numeric; v_desc numeric; v_lucro_antes numeric; v_sugestoes text[] := '{}'; v_prev_conv numeric; v_prev_deg integer; v_receita numeric; v_alerta_consumo boolean := false;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  -- conversão base: orçamentos encerrados no período, sem condição
  select coalesce(count(*) filter (where o.status = 'pago')::numeric / nullif(count(*), 0), 0) into v_conv_base
    from public.orcamentos o
   where o.origem_id is null and o.criado_em > now() - make_interval(days => p_dias) and o.status in ('pago', 'expirado', 'perdido')
     and not o.teste and not exists (select 1 from public.condicoes_especiais c where c.orcamento_id = o.id);
  for g in
    select c.degrau, count(*) as ofertas, count(*) filter (where c.resultado = 'aceita') as aceitas,
           coalesce(avg(n.margem_liquida_pct) filter (where c.resultado = 'aceita'), 0) as margem_media,
           coalesce(sum(n.total) filter (where c.resultado = 'aceita'), 0) as receita,
           coalesce(sum(c.desconto_reais) filter (where c.resultado = 'aceita'), 0) as descontos,
           coalesce(sum(c.lucro_liquido_depois) filter (where c.resultado = 'aceita'), 0) as lucro_depois
      from public.condicoes_especiais c left join public.orcamentos n on n.id = c.orcamento_novo_id
     where c.criado_em > now() - make_interval(days => p_dias) group by c.degrau order by c.degrau
  loop
    v_graus := v_graus || jsonb_build_object('degrau', g.degrau, 'ofertas', g.ofertas, 'aceitas', g.aceitas,
      'conversao_pct', round(g.aceitas::numeric / nullif(g.ofertas, 0) * 100, 1), 'margem_media_pct', round(g.margem_media, 1),
      'receita', round(g.receita, 2), 'desconto_total', round(g.descontos, 2));
    v_receita := coalesce(v_receita, 0) + g.receita;
    v_desc := coalesce(v_desc, 0) + g.descontos;
    v_lucro_antes := coalesce(v_lucro_antes, 0) + g.lucro_depois + g.descontos * (1 - pr.imposto_pct / 100 - (private.taxa_pagamento(null) ->> 'pct')::numeric / 100);
    v_inc := v_inc + greatest(0, g.aceitas - g.ofertas * v_conv_base) * (g.receita / nullif(g.aceitas, 0));
    if g.degrau >= 2 and g.ofertas >= 5 and v_prev_conv is not null and (g.aceitas::numeric / g.ofertas - v_prev_conv) < 0.05 then
      v_sugestoes := array_append(v_sugestoes, format('O degrau %s não aumentou a conversão de forma mensurável (menos de 5 pontos sobre o degrau %s). Sugestão: reduzir o percentual ou desligar o degrau.', g.degrau, v_prev_deg));
    end if;
    if g.ofertas >= 5 then v_prev_conv := g.aceitas::numeric / g.ofertas; v_prev_deg := g.degrau; end if;
  end loop;
  v_consumo := case when coalesce(v_lucro_antes, 0) > 0 then round(coalesce(v_desc, 0) / v_lucro_antes * 100, 1) else 0 end;
  v_alerta_consumo := v_consumo > pr.desconto_alerta_consumo_margem_pct;
  if v_alerta_consumo then
    v_sugestoes := array_append(v_sugestoes, format('Os descontos consumiram %s%% da margem (limite de %s%%). Sugestão: reduzir a fração da gordura ou os percentuais.', v_consumo, pr.desconto_alerta_consumo_margem_pct));
  end if;
  if p_alertar and (v_alerta_consumo or cardinality(v_sugestoes) > 0) then
    insert into public.alertas (tipo, gravidade, motivo) values ('relatorio_condicoes', 'baixa', array_to_string(v_sugestoes, ' '));
  end if;
  return jsonb_build_object('ok', true, 'dias', p_dias, 'conversao_base_pct', round(v_conv_base * 100, 1), 'degraus', v_graus,
    'receita_com_condicao', round(coalesce(v_receita, 0), 2), 'desconto_total', round(coalesce(v_desc, 0), 2), 'consumo_da_margem_pct', v_consumo,
    'receita_incremental_estimada', round(v_inc, 2), 'alerta_consumo_margem', v_alerta_consumo, 'sugestoes', to_jsonb(v_sugestoes));
end;
$$;

-- resumo semanal ao dono (Catálogo > Saúde de preços e alerta de baixa gravidade)
create or replace function public.resumo_semanal_precos(p_alertar boolean default false) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_pesq jsonb; v_aj jsonb; v_nc integer; v_nv integer; v_grupos jsonb; v_cond jsonb; v_texto text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select jsonb_build_object('consultas', count(*), 'cache', count(*) filter (where status = 'cache'),
           'sem_dado', count(*) filter (where status in ('sem_dado', 'erro')), 'pesquisadas', count(*) filter (where status = 'concluida'),
           'tempo_medio_ms', round(avg(duracao_ms) filter (where status = 'concluida')), 'tokens', coalesce(sum(tokens_usados), 0), 'requisicoes', coalesce(sum(requisicoes), 0))
    into v_pesq from public.consultas_preco_mercado where criado_em > now() - interval '7 days';
  select coalesce(jsonb_agg(jsonb_build_object('grupo', grupo_produto, 'antes', fator_antes, 'depois', fator_depois, 'motivo', motivo) order by criado_em), '[]'::jsonb)
    into v_aj from public.ajustes_fator_preco where criado_em > now() - interval '7 days';
  select count(*) filter (where status_venda = 'nao_competitivo'), count(*) filter (where status_venda = 'nao_vender') into v_nc, v_nv from public.catalogo where active;
  select coalesce(jsonb_agg(jsonb_build_object('grupo', grupo_produto, 'orcamentos', orcamentos_30d, 'ganhos', ganhos_30d,
           'conversao_pct', round(ganhos_30d::numeric / nullif(orcamentos_30d, 0) * 100, 1)) order by orcamentos_30d desc), '[]'::jsonb)
    into v_grupos from public.saude_precos where orcamentos_30d > 0;
  v_cond := public.relatorio_condicoes_semana(7, false);
  v_texto := format('Resumo de preços da semana: %s consultas de mercado (%s do cache, %s sem dado). %s ajuste(s) de fator. %s itens não competitivos, %s fora de venda. Descontos consumiram %s%% da margem.',
    v_pesq ->> 'consultas', v_pesq ->> 'cache', v_pesq ->> 'sem_dado', jsonb_array_length(v_aj), v_nc, v_nv, v_cond ->> 'consumo_da_margem_pct');
  if p_alertar then insert into public.alertas (tipo, gravidade, motivo) values ('resumo_semanal_precos', 'baixa', v_texto); end if;
  return jsonb_build_object('ok', true, 'texto', v_texto, 'pesquisas', v_pesq, 'ajustes_fator', v_aj, 'nao_competitivos', v_nc, 'nao_vender', v_nv,
    'conversao_por_grupo', v_grupos, 'condicoes', v_cond);
end;
$$;

-- ---------------------------------------------------------------- 8. política de desconto: simulação do pior caso e recusa de prejuízo
-- Pior lucro líquido possível de UMA regra de desconto em dinheiro: percorre uma amostra do catálogo, três tipos de entrega e quatro níveis de preço
-- (do piso, onde não há gordura, até o dobro), aplicando exatamente a fórmula de calcular_condicao_especial.
create or replace function private.pior_lucro_regra(p_pct numeric, p_fracao numeric, p_teto numeric, p_amostra integer default 200) returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype; r record; v_pior numeric := null; v_sku text; v_maior numeric := 0;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  for r in
    with amostra as (select sku, custo from public.catalogo where active and vendavel and custo > 0 order by md5(sku) limit greatest(p_amostra, 1)),
    entregas as (select unnest(array[null, 'bike', 'uber']::text[]) as entrega),
    niveis as (select unnest(array[1.0, 1.05, 1.5, 2.0]::numeric[]) as k)
    select a.sku, a.custo, e.entrega, n.k from amostra a cross join entregas e cross join niveis n
  loop
    declare
      v_extra numeric := private.custos_operacionais(r.entrega);
      v_piso numeric := ceil(greatest(r.custo * pr.multiplicador_piso, private.receita_para_lucro(r.custo, v_extra, pr.lucro_liquido_minimo, null)) * 100) / 100;
      v_preco numeric := private.teto_90(v_piso * r.k);
      v_desc numeric; v_lucro numeric;
    begin
      v_desc := floor(least(v_preco * p_pct / 100, greatest(v_preco - v_piso, 0) * p_fracao, p_teto) * 100) / 100;
      v_lucro := private.lucro(v_preco - v_desc, r.custo, v_extra, null);
      if v_pior is null or v_lucro < v_pior then v_pior := v_lucro; v_sku := r.sku; end if;
      if v_desc > v_maior then v_maior := v_desc; end if;
    end;
  end loop;
  return jsonb_build_object('pior_lucro_liquido', coalesce(v_pior, 0), 'item_pior_caso', v_sku, 'maior_desconto_reais', v_maior);
end;
$$;
revoke execute on function private.pior_lucro_regra(numeric, numeric, numeric, integer) from public, anon, authenticated;

create or replace function public.simular_politica_desconto(p_regras jsonb default null, p_amostra integer default 200) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  d record; v_res jsonb := '[]'::jsonb; v_pct numeric; v_fr numeric; v_teto numeric; v_sim jsonb; v_regra jsonb; v_seguro boolean := true;
begin
  if not private.is_staff() and coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  for d in select * from public.politica_desconto order by degrau loop
    v_regra := (select x from jsonb_array_elements(coalesce(p_regras, '[]'::jsonb)) x where (x ->> 'degrau')::int = d.degrau limit 1);
    v_pct := coalesce((v_regra ->> 'percentual')::numeric, d.percentual);
    v_fr := coalesce((v_regra ->> 'fracao_gordura_max')::numeric, d.fracao_gordura_max);
    v_teto := coalesce((v_regra ->> 'desconto_max_reais')::numeric, d.desconto_max_reais);
    if d.tipo = 'desconto' then
      v_sim := private.pior_lucro_regra(v_pct, v_fr, v_teto, p_amostra);
      v_res := v_res || jsonb_build_object('degrau', d.degrau, 'tipo', d.tipo, 'percentual', v_pct, 'fracao_gordura_max', v_fr, 'desconto_max_reais', v_teto,
                 'pior_lucro_liquido', (v_sim ->> 'pior_lucro_liquido')::numeric, 'maior_desconto_reais', (v_sim ->> 'maior_desconto_reais')::numeric,
                 'seguro', (v_sim ->> 'pior_lucro_liquido')::numeric >= 0 and v_pct <= 10 and v_fr <= 1);
      v_seguro := v_seguro and (v_sim ->> 'pior_lucro_liquido')::numeric >= 0 and v_pct <= 10 and v_fr <= 1;
    else
      v_res := v_res || jsonb_build_object('degrau', d.degrau, 'tipo', d.tipo, 'nota', 'Vantagem sem custo em dinheiro: só vale se o preço sem frete ou arte continuar acima do piso.', 'seguro', true);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'seguro', v_seguro, 'degraus', v_res, 'amostra', p_amostra);
end;
$$;

-- salva a política inteira somente se a simulação do pior caso não der prejuízo
create or replace function public.salvar_politica_desconto(p_regras jsonb) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare x jsonb; v_sim jsonb;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  v_sim := public.simular_politica_desconto(p_regras, 200);
  if not (v_sim ->> 'seguro')::boolean then
    raise exception 'Política recusada: no pior caso o pedido teria prejuízo. Reduza o percentual, a fração da gordura ou o teto.' using errcode = 'P0001';
  end if;
  for x in select * from jsonb_array_elements(p_regras) loop
    update public.politica_desconto set
      percentual = coalesce((x ->> 'percentual')::numeric, percentual),
      fracao_gordura_max = coalesce((x ->> 'fracao_gordura_max')::numeric, fracao_gordura_max),
      desconto_max_reais = coalesce((x ->> 'desconto_max_reais')::numeric, desconto_max_reais),
      valor_minimo_reais = coalesce((x ->> 'valor_minimo_reais')::numeric, valor_minimo_reais),
      validade_horas = coalesce((x ->> 'validade_horas')::smallint, validade_horas),
      intervalo_dias_contato = coalesce((x ->> 'intervalo_dias_contato')::smallint, intervalo_dias_contato),
      ativo = coalesce((x ->> 'ativo')::boolean, ativo)
    where degrau = (x ->> 'degrau')::smallint;
  end loop;
  return v_sim;
end;
$$;

-- defesa em profundidade: mesmo uma alteração direta na tabela é recusada se o pior caso der prejuízo
create or replace function private.politica_desconto_validar() returns trigger
language plpgsql set search_path = ''
as $$
declare v jsonb;
begin
  if new.tipo = 'desconto' and new.ativo then
    v := private.pior_lucro_regra(new.percentual, new.fracao_gordura_max, new.desconto_max_reais, 60);
    if (v ->> 'pior_lucro_liquido')::numeric < 0 then
      raise exception 'Política recusada: no pior caso o pedido teria prejuízo.' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function private.politica_desconto_validar() from public, anon, authenticated;
drop trigger if exists politica_desconto_validar on public.politica_desconto;
create trigger politica_desconto_validar before insert or update on public.politica_desconto for each row execute function private.politica_desconto_validar();

-- grupos que não aceitam desconto (parametros_comerciais.categorias_sem_desconto) editados pela mesma tela
create or replace function public.definir_grupos_sem_desconto(p_grupos text[]) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.parametros_comerciais set categorias_sem_desconto = coalesce(p_grupos, '{}') where id = 1;
end;
$$;

-- ---------------------------------------------------------------- 9. edição manual de preço no pedido: lucro líquido, bloqueio e confirmação
-- Faixas: abaixo do piso duro = bloqueado para todos; entre o piso duro e o piso = só com confirmação do dono (fica no log); acima = livre.
create or replace function public.definir_preco_item_pedido(p_item uuid, p_preco numeric, p_confirmar boolean default false, p_motivo text default null, p_apenas_simular boolean default false)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  it public.order_items%rowtype; o public.orders%rowtype; calc jsonb; v_piso numeric; v_duro numeric; v_lucro numeric; v_faixa text; v_total numeric; v_custo numeric;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into it from public.order_items where id = p_item for update;
  if not found then raise exception 'Item não encontrado.' using errcode = 'P0001'; end if;
  select * into o from public.orders where id = it.order_id;
  if p_preco is null or p_preco < 0 then raise exception 'Preço inválido.' using errcode = 'P0001'; end if;
  v_total := p_preco * it.qty; v_custo := it.unit_cost * it.qty;
  calc := case when it.code is not null then public.calcular_preco(it.code, it.qty, '{}'::jsonb) else null end;
  if calc is not null and coalesce((calc ->> 'ok')::boolean, false) then
    v_piso := (calc ->> 'piso')::numeric; v_duro := (calc ->> 'piso_duro')::numeric;
  else  -- item digitado à mão ou fora do catálogo: pisos pelo custo informado
    v_duro := ceil(private.receita_para_lucro(v_custo, 0, 0, null) * 100) / 100;
    v_piso := ceil(greatest(v_custo * (select multiplicador_piso from public.parametros_comerciais where id = 1),
                            private.receita_para_lucro(v_custo, 0, (select lucro_liquido_minimo from public.parametros_comerciais where id = 1), null)) * 100) / 100;
  end if;
  v_lucro := private.lucro(v_total, v_custo, 0, null);
  v_faixa := case when v_custo > 0 and v_total < v_duro then 'abaixo_piso_duro' when v_custo > 0 and v_total < v_piso then 'entre_pisos' else 'ok' end;
  if p_apenas_simular then
    return jsonb_build_object('ok', v_faixa <> 'abaixo_piso_duro', 'faixa', v_faixa, 'lucro_liquido', v_lucro, 'piso', v_piso / it.qty, 'piso_duro', v_duro / it.qty,
                              'total_linha', v_total, 'requer_confirmacao', v_faixa = 'entre_pisos');
  end if;
  if v_faixa = 'abaixo_piso_duro' then
    raise exception 'Preço bloqueado: abaixo do piso duro o item daria prejuízo (mínimo R$ %).', to_char(ceil(v_duro / it.qty * 100) / 100, 'FM999G990D00') using errcode = 'P0001';
  end if;
  if v_faixa = 'entre_pisos' and not p_confirmar then
    return jsonb_build_object('ok', false, 'requer_confirmacao', true, 'faixa', v_faixa, 'lucro_liquido', v_lucro, 'piso', v_piso / it.qty, 'piso_duro', v_duro / it.qty);
  end if;
  perform set_config('gbh.preco_aprovado', 'on', true);
  update public.order_items set unit_price = p_preco where id = p_item;
  insert into public.precos_manuais_log (order_id, order_item_id, sku, preco_antes, preco_depois, faixa, piso, piso_duro, lucro_liquido, motivo, usuario)
  values (it.order_id, it.id, it.code, it.unit_price, p_preco, case when v_faixa = 'entre_pisos' then 'entre_pisos' else 'ok' end, v_piso / it.qty, v_duro / it.qty, v_lucro, left(p_motivo, 300), auth.uid());
  if v_faixa = 'entre_pisos' then
    update public.orders set price_override_reason = coalesce(nullif(left(p_motivo, 300), ''), 'Preço entre o piso duro e o piso aprovado pelo dono') where id = it.order_id;
  end if;
  return jsonb_build_object('ok', true, 'faixa', v_faixa, 'lucro_liquido', v_lucro, 'piso', v_piso / it.qty, 'piso_duro', v_duro / it.qty);
end;
$$;

-- trava de banco para quem edita pelo CRM: preço abaixo do piso só passa pela função acima
create or replace function private.order_items_piso_manual() returns trigger
language plpgsql set search_path = ''
as $$
declare calc jsonb; v_piso numeric;
begin
  if tg_op = 'UPDATE' and new.unit_price is distinct from old.unit_price and new.unit_price < old.unit_price
     and coalesce(auth.role(), '') = 'authenticated' and coalesce(current_setting('gbh.preco_aprovado', true), '') <> 'on' and new.code is not null then
    calc := public.calcular_preco(new.code, new.qty, '{}'::jsonb);
    if coalesce((calc ->> 'ok')::boolean, false) and new.unit_price * new.qty < (calc ->> 'piso')::numeric then
      raise exception 'Preço abaixo do piso: use a confirmação do dono no pedido (fica registrado).' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function private.order_items_piso_manual() from public, anon, authenticated;
drop trigger if exists order_items_piso_manual on public.order_items;
create trigger order_items_piso_manual before update on public.order_items for each row execute function private.order_items_piso_manual();

-- ---------------------------------------------------------------- 10. acesso
do $$
declare f text;
begin
  foreach f in array array[
    'public.oferecer_condicao_especial(uuid,text)', 'public.condicao_registrar_link(uuid,text)', 'public.expirar_condicoes_e_orcamentos()',
    'public.detectar_padroes_desconto()', 'public.relatorio_condicoes_semana(integer,boolean)', 'public.resumo_semanal_precos(boolean)',
    'public.simular_politica_desconto(jsonb,integer)', 'public.salvar_politica_desconto(jsonb)', 'public.definir_grupos_sem_desconto(text[])',
    'public.definir_preco_item_pedido(uuid,numeric,boolean,text,boolean)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

