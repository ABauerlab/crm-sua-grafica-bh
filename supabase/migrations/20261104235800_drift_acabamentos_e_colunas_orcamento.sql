-- Drift de produção: objetos criados em produção (04/11/2026) sem migration no repositório.
-- Traz o estado atual de produção para o banco poder ser recriado do zero. Sem mudar comportamento.
-- Aditiva e idempotente (if not exists / drop policy if exists): em produção não altera nada.
-- Fora daqui, de propósito: o cache e as funções da integração de fotos com o fornecedor, cujo nome
-- não pode entrar no repositório. Nenhuma migration do repositório depende deles.

-- Acabamentos por categoria ou grupo de produto
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
drop policy if exists "Leitura de acabamentos permitida para todos autenticados e serv" on public.produto_acabamentos;
create policy "Leitura de acabamentos permitida para todos autenticados e serv" on public.produto_acabamentos
  for select to authenticated, service_role using (true);
drop policy if exists "Modificacao de acabamentos permitida para staff e service_role" on public.produto_acabamentos;
create policy "Modificacao de acabamentos permitida para staff e service_role" on public.produto_acabamentos
  for all to authenticated, service_role using (true) with check (true);

-- Itens do orçamento: custo, acabamento e medidas (m²)
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

-- Orçamentos: validade em horas, versão do PDF, pagamento, piso e data do evento
alter table public.orcamentos
  add column if not exists validade_horas integer not null default 48,
  add column if not exists pdf_versao integer not null default 1,
  add column if not exists pagamento_gerado_em timestamptz,
  add column if not exists pagamento_expira_em timestamptz,
  add column if not exists piso_aplicado numeric(12, 2),
  add column if not exists fornecedor_ref text,
  add column if not exists data_evento date;
create index if not exists idx_orcamentos_validade_ate on public.orcamentos (validade_ate);
