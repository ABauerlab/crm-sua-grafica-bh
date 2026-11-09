-- Colunas que existem em produção mas não em nenhuma migration do repositório (deriva levantada em 09/11/2026).
-- Só para o banco local de teste (rodar-local.sh carrega depois das migrations). Fechar a deriva com migration é tarefa à parte.
alter table public.catalogo add column if not exists embalagem_cm text;
alter table public.catalogo add column if not exists estrategia_preco text;
alter table public.catalogo add column if not exists peso_frete_kg numeric;
alter table public.catalogo add column if not exists prazo_cliente_dias integer;
alter table public.catalogo add column if not exists preco_mercado_ref numeric;
alter table public.catalogo add column if not exists preco_planilha_em timestamp with time zone;
alter table public.catalogo add column if not exists preco_venda numeric;
alter table public.catalogo add column if not exists tipo_embalagem text;
alter table public.orcamento_itens add column if not exists acabamento text;
alter table public.orcamento_itens add column if not exists acabamento_custo numeric default 0.00;
alter table public.orcamento_itens add column if not exists acabamento_dias_adicionais integer default 0;
alter table public.orcamento_itens add column if not exists altura_mm integer;
alter table public.orcamento_itens add column if not exists area_m2 numeric;
alter table public.orcamento_itens add column if not exists custo_total numeric;
alter table public.orcamento_itens add column if not exists largura_mm integer;
alter table public.orcamento_itens add column if not exists sku_fornecedor text;
alter table public.orcamento_itens add column if not exists valor_total numeric;
alter table public.orcamentos add column if not exists bloqueio_motivo text;
alter table public.orcamentos add column if not exists data_evento date;
alter table public.orcamentos add column if not exists fornecedor_ref text;
alter table public.orcamentos add column if not exists pagamento_expira_em timestamp with time zone;
alter table public.orcamentos add column if not exists pagamento_gerado_em timestamp with time zone;
alter table public.orcamentos add column if not exists pdf_versao integer default 1 not null;
alter table public.orcamentos add column if not exists piso_aplicado numeric;
alter table public.orcamentos add column if not exists validade_horas integer default 48 not null;
alter table public.parametros_comerciais add column if not exists fonte_preco text default 'planilha'::text not null;
alter table public.parametros_comerciais add column if not exists lucro_bruto_minimo numeric default 65 not null;
