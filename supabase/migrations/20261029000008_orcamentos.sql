-- Etapa 4: integração aditiva com as tabelas de orçamento já existentes.
-- Não recria nem renomeia tabelas existentes.
alter table if exists public.orcamentos
  add column if not exists validade_horas integer not null default 48,
  add column if not exists pdf_gerado_em timestamptz,
  add column if not exists pdf_versao integer not null default 1,
  add column if not exists pagamento_gerado_em timestamptz,
  add column if not exists pagamento_expira_em timestamptz,
  add column if not exists avisos jsonb not null default '[]'::jsonb,
  add column if not exists custo_total numeric(12,2),
  add column if not exists piso_aplicado numeric(12,2),
  add column if not exists fornecedor_ref text,
  add column if not exists bloqueio_motivo text;

alter table if exists public.orcamento_itens
  add column if not exists especificacao jsonb not null default '{}'::jsonb,
  add column if not exists valor_total numeric(12,2),
  add column if not exists sku_fornecedor text,
  add column if not exists custo_unitario numeric(12,2),
  add column if not exists custo_total numeric(12,2);

create index if not exists idx_orcamentos_validade_ate on public.orcamentos(validade_ate);
create index if not exists idx_orcamento_itens_orcamento on public.orcamento_itens(orcamento_id);

create or replace function public.atualizar_orcamento_atualizado_em()
returns trigger language plpgsql as $$ begin new.atualizado_em = now(); return new; end; $$;
drop trigger if exists trg_orcamentos_atualizado_em on public.orcamentos;
create trigger trg_orcamentos_atualizado_em before update on public.orcamentos for each row execute function public.atualizar_orcamento_atualizado_em();

create or replace view public.orcamentos_cliente as
select id, numero, status, entrega, bairro, cep, metodo_previsto, arte_modo, arte_valor, frete_valor, desconto_valor, subtotal, total, validade_ate, pdf_path, pdf_gerado_em, pdf_versao, link_pagamento, pagamento_expira_em, avisos, criado_em, atualizado_em
from public.orcamentos;

create or replace view public.orcamento_itens_cliente as
select id, orcamento_id, descricao, quantidade, preco_unitario, especificacao, valor_total
from public.orcamento_itens;

insert into storage.buckets (id, name, public)
values ('orcamentos', 'orcamentos', false)
on conflict (id) do nothing;

comment on table public.orcamentos is 'Orçamentos comerciais; custos, margem, piso, fornecedor e SKU permanecem internos.';
