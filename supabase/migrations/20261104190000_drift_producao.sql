-- Drift de produção: objetos criados direto em produção, sem migration no repositório (levantamento de 09/11/2026,
-- comparando information_schema, pg_constraint, pg_indexes, pg_policies e grants de produção com o banco montado
-- só pelas migrations). Traz a definição atual de produção para o banco poder ser recriado do zero.
-- Aditiva e idempotente (if not exists / checagem no catálogo antes de criar): em produção não muda nada.
-- Prefixo antes de 20261104193000_ajustes_comerciais_producao.sql, a primeira que usa estes objetos.
-- Fora daqui, de propósito (regra de sigilo): a tabela de cache de scraping do fornecedor e 2 colunas jsonb de
-- produto_fotos_mapa, porque o nome delas contém o nome do fornecedor. Nenhuma migration depende delas.

-- 1. Catálogo: preço da planilha, estratégia e dados de frete
alter table public.catalogo
  add column if not exists preco_venda numeric(12, 2),
  add column if not exists preco_mercado_ref numeric(12, 2),
  add column if not exists estrategia_preco text,
  add column if not exists preco_planilha_em timestamptz,
  add column if not exists prazo_cliente_dias integer,
  add column if not exists peso_frete_kg numeric(10, 3),
  add column if not exists tipo_embalagem text,
  add column if not exists embalagem_cm text;

-- 2. Itens do orçamento: custo, acabamento e medidas (m²)
alter table public.orcamento_itens
  add column if not exists valor_total numeric(12, 2),
  add column if not exists sku_fornecedor text,
  add column if not exists custo_unitario numeric(12, 2),
  add column if not exists custo_total numeric(12, 2),
  add column if not exists acabamento text,
  add column if not exists acabamento_custo numeric(10, 2) default 0.00,
  add column if not exists acabamento_dias_adicionais integer default 0,
  add column if not exists largura_mm integer,
  add column if not exists altura_mm integer,
  add column if not exists area_m2 numeric(10, 3);
create index if not exists idx_orcamento_itens_orcamento on public.orcamento_itens (orcamento_id);

-- 3. Orçamentos: validade em horas, versão do PDF, pagamento, piso, bloqueio e data do evento
alter table public.orcamentos
  add column if not exists validade_horas integer not null default 48,
  add column if not exists pdf_versao integer not null default 1,
  add column if not exists pagamento_gerado_em timestamptz,
  add column if not exists pagamento_expira_em timestamptz,
  add column if not exists piso_aplicado numeric(12, 2),
  add column if not exists bloqueio_motivo text,
  add column if not exists fornecedor_ref text,
  add column if not exists data_evento date;
create index if not exists idx_orcamentos_validade_ate on public.orcamentos (validade_ate);

create or replace function public.atualizar_orcamento_atualizado_em()
returns trigger
language plpgsql
set search_path = ''
as $function$ begin new.atualizado_em = now(); return new; end; $function$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_orcamentos_atualizado_em' and tgrelid = 'public.orcamentos'::regclass) then
    create trigger trg_orcamentos_atualizado_em
      before update on public.orcamentos
      for each row execute function public.atualizar_orcamento_atualizado_em();
  end if;
end $$;

-- 4. Parâmetros comerciais: fonte do preço e lucro bruto mínimo
alter table public.parametros_comerciais
  add column if not exists fonte_preco text not null default 'planilha',
  add column if not exists lucro_bruto_minimo numeric(10, 2) not null default 65;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'parametros_fonte_preco_chk' and conrelid = 'public.parametros_comerciais'::regclass) then
    alter table public.parametros_comerciais
      add constraint parametros_fonte_preco_chk check (fonte_preco = any (array['planilha', 'mercado']));
  end if;
end $$;

-- 5. Mapa de fotos: data da última coleta (as 2 colunas de origem ficam fora, ver cabeçalho)
alter table public.produto_fotos_mapa
  add column if not exists scrap_atualizado_em timestamptz;

-- 6. Acabamentos por categoria ou grupo de produto
create table if not exists public.produto_acabamentos (
  id uuid primary key default gen_random_uuid(),
  categoria text not null,
  grupo_produto text,
  nome text not null,
  descricao text,
  tipo text not null default 'padrao',
  custo_adicional numeric(10, 2) not null default 0.00,
  dias_uteis_adicionais integer not null default 0,
  obrigatorio_escolher boolean not null default false,
  pergunta_qualificacao text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists idx_produto_acabamentos_cat on public.produto_acabamentos (categoria);
create index if not exists idx_produto_acabamentos_grupo on public.produto_acabamentos (grupo_produto);
alter table public.produto_acabamentos enable row level security;
revoke all on public.produto_acabamentos from anon;
grant all on public.produto_acabamentos to authenticated, service_role;

-- 7. Planilha de preços importada (só o dono lê; escrita pela service role)
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
  custo numeric(12, 2) not null,
  preco_mercado numeric(12, 2),
  preco_venda numeric(12, 2) not null,
  estrategia text,
  importado_em timestamptz not null default now()
);
alter table public.planilha_precos_import enable row level security;
revoke all on public.planilha_precos_import from anon, authenticated;
grant select on public.planilha_precos_import to authenticated;
grant all on public.planilha_precos_import to service_role;

-- 8. Vitrine do e-commerce (um registro por SKU do catálogo)
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
  preco numeric(12, 2) not null,
  parcela_2x numeric(12, 2) not null,
  prazo_dias_uteis integer,
  peso_kg numeric(10, 3),
  embalagem_cm text,
  tipo_embalagem text,
  fotos jsonb not null default '[]'::jsonb,
  ficha jsonb not null default '{}'::jsonb,
  acabamentos jsonb not null default '[]'::jsonb,
  gabaritos jsonb not null default '[]'::jsonb,
  ativo boolean not null default true,
  atualizado_em timestamptz not null default now()
);
create index if not exists ecommerce_products_categoria_idx on public.ecommerce_products (categoria_slug) where ativo;
create index if not exists ecommerce_products_produto_idx on public.ecommerce_products (produto_slug);
alter table public.ecommerce_products enable row level security;
revoke all on public.ecommerce_products from anon, authenticated;
grant all on public.ecommerce_products to service_role;

-- 9. Policies iguais às de produção (criadas só se ainda não existirem)
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'produto_acabamentos'
                 and policyname = 'Leitura de acabamentos permitida para todos autenticados e serv') then
    create policy "Leitura de acabamentos permitida para todos autenticados e serv" on public.produto_acabamentos
      for select to authenticated, service_role using (true);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'produto_acabamentos'
                 and policyname = 'Modificacao de acabamentos permitida para staff e service_role') then
    create policy "Modificacao de acabamentos permitida para staff e service_role" on public.produto_acabamentos
      for all to authenticated, service_role using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'planilha_precos_import'
                 and policyname = 'planilha_precos_import_dono') then
    create policy planilha_precos_import_dono on public.planilha_precos_import
      for select to authenticated using (private.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ecommerce_products'
                 and policyname = 'ecommerce_products_publico') then
    create policy ecommerce_products_publico on public.ecommerce_products
      for select to anon, authenticated using (ativo);
  end if;
end $$;
