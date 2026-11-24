-- Trava de saída: CNPJ citado tem que bater com o oficial (58.481.181/0001-03),
-- senão a mensagem inteira é bloqueada (a Laura já cortou o número pela metade uma vez).
begin;
create temp table _t (n int, ok boolean, nome text);
create or replace function pg_temp.chk(p_ok boolean, p_nome text) returns void language plpgsql as $$
begin insert into _t values ((select count(*) + 1 from _t), coalesce(p_ok, false), p_nome); end $$;

do $$
declare v_r jsonb;
begin
  v_r := public.agente_saida_base_execucao(null, 'Pra você checar nossa procedência com calma e ter total segurança: CNPJ: 58.481.');
  perform pg_temp.chk(not (v_r ->> 'ok')::boolean, 'cnpj truncado é bloqueado');
  perform pg_temp.chk(v_r -> 'motivos' ? 'vazamento:cnpj_incorreto', 'cnpj truncado gera o motivo certo');

  v_r := public.agente_saida_base_execucao(null, 'O CNPJ da Sua Gráfica BH é 58.481.181/0001-03.');
  perform pg_temp.chk((v_r ->> 'ok')::boolean, 'cnpj correto passa');

  v_r := public.agente_saida_base_execucao(null, 'Somos uma gráfica séria de BH, pode confiar!');
  perform pg_temp.chk((v_r ->> 'ok')::boolean, 'texto sem cnpj passa normalmente');

  v_r := public.agente_saida_base_execucao(null, 'O CNPJ é 12.345.678/0001-99.');
  perform pg_temp.chk(not (v_r ->> 'ok')::boolean, 'cnpj de outra empresa/inventado é bloqueado');
end $$;

select case when count(*) filter (where not ok) = 0
  then 'OK: ' || count(*) || ' testes passaram'
  else 'FALHOU: ' || string_agg(nome, ', ') filter (where not ok)
  end as resultado
from _t;
rollback;
