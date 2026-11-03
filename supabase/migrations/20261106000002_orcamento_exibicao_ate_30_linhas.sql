-- A exibição consolidada do orçamento (itens_exibicao) passa a aceitar até 30 linhas (eventos grandes têm mais de 10 produtos).
-- Aditiva e idempotente.
alter table public.orcamentos drop constraint if exists orcamentos_itens_exibicao_tipo;
alter table public.orcamentos add constraint orcamentos_itens_exibicao_tipo
  check (itens_exibicao is null or (jsonb_typeof(itens_exibicao) = 'array' and jsonb_array_length(itens_exibicao) between 1 and 30));
