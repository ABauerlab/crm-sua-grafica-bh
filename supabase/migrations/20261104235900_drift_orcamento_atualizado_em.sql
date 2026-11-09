-- Drift de produção: a função e o gatilho abaixo foram criados em produção fora do repositório.
-- Esta migration traz a definição atual de produção (sem mudar comportamento) para que o banco
-- possa ser recriado do zero. Aditiva e idempotente: em produção não altera nada.
-- O prefixo vem antes de 20261105000001_etapa8_endurecer_funcoes.sql, que faz alter nesta função.
create or replace function public.atualizar_orcamento_atualizado_em()
returns trigger
language plpgsql
set search_path = ''
as $$ begin new.atualizado_em = now(); return new; end; $$;

drop trigger if exists trg_orcamentos_atualizado_em on public.orcamentos;
create trigger trg_orcamentos_atualizado_em
  before update on public.orcamentos
  for each row execute function public.atualizar_orcamento_atualizado_em();
