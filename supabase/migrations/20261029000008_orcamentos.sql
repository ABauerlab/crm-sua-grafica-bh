-- Etapa 4: orçamento em PDF. Migration aditiva e idempotente.
create sequence if not exists public.orcamento_numero_seq start with 1 increment by 1;

create or replace function public.proximo_numero_orcamento()
returns text
language sql
security definer
set search_path = public
as $$
  select 'SG-' || lpad(nextval('public.orcamento_numero_seq')::text, 4, '0');
$$;

create table if not exists public.orcamentos (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique default public.proximo_numero_orcamento(),
  contato_id uuid,
  pedido_id uuid,
  status text not null default 'rascunho' check (status in ('rascunho','enviado','pago','vencido','cancelado','bloqueado')),
  subtotal numeric(12,2) not null default 0 check (subtotal >= 0),
  valor_arte numeric(12,2) not null default 0 check (valor_arte >= 0),
  valor_frete numeric(12,2) not null default 0 check (valor_frete >= 0),
  total numeric(12,2) not null default 0 check (total >= 0),
  data_prevista date,
  validade_horas integer not null default 48 check (validade_horas > 0),
  valido_ate timestamptz not null default (now() + interval '48 hours'),
  pdf_storage_path text,
  pdf_gerado_em timestamptz,
  pdf_versao integer not null default 1,
  pagamento_url text,
  pagamento_gerado_em timestamptz,
  pagamento_expira_em timestamptz,
  avisos jsonb not null default '[]'::jsonb,
  -- Campos internos: nunca expor no JSON do agente ou no PDF do cliente.
  regra_preco text,
  confianca_preco text,
  margem_percentual numeric(7,3),
  custo_total numeric(12,2),
  piso_aplicado numeric(12,2),
  fornecedor_ref text,
  bloqueio_motivo text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.orcamento_itens (
  id uuid primary key default gen_random_uuid(),
  orcamento_id uuid not null references public.orcamentos(id) on delete cascade,
  sku text not null,
  descricao text not null,
  especificacao jsonb not null default '{}'::jsonb,
  quantidade numeric(12,3) not null check (quantidade > 0),
  valor_unitario numeric(12,2) not null check (valor_unitario >= 0),
  valor_total numeric(12,2) not null check (valor_total >= 0),
  -- Internos: nunca expor ao cliente.
  sku_fornecedor text,
  custo_unitario numeric(12,2),
  custo_total numeric(12,2),
  created_at timestamptz not null default now()
);

create index if not exists idx_orcamentos_contato on public.orcamentos(contato_id);
create index if not exists idx_orcamentos_pedido on public.orcamentos(pedido_id);
create index if not exists idx_orcamentos_status on public.orcamentos(status);
create index if not exists idx_orcamentos_valido_ate on public.orcamentos(valido_ate);
create index if not exists idx_orcamento_itens_orcamento on public.orcamento_itens(orcamento_id);

create or replace function public.atualizar_orcamento_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_orcamentos_updated_at on public.orcamentos;
create trigger trg_orcamentos_updated_at
before update on public.orcamentos
for each row execute function public.atualizar_orcamento_updated_at();

create or replace view public.orcamentos_cliente as
select
  o.id,
  o.numero,
  o.status,
  o.subtotal,
  o.valor_arte,
  o.valor_frete,
  o.total,
  o.data_prevista,
  o.valido_ate,
  o.pdf_storage_path,
  o.pdf_gerado_em,
  o.pdf_versao,
  o.pagamento_url,
  o.pagamento_expira_em,
  o.avisos,
  o.created_at,
  o.updated_at
from public.orcamentos o;

create or replace view public.orcamento_itens_cliente as
select
  id,
  orcamento_id,
  descricao,
  especificacao,
  quantidade,
  valor_unitario,
  valor_total
from public.orcamento_itens;

comment on table public.orcamentos is 'Orçamentos comerciais; campos de custo, margem, fornecedor e regra são internos.';
comment on table public.orcamento_itens is 'Itens públicos e campos internos separados na mesma linha, com exposição somente pelas views cliente.';
