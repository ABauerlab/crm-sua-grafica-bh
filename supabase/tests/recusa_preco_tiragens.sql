-- Q2_RECUSA: resposta fria ao preço gera as tiragens menores do mesmo produto (rollback; só leitura)
begin;
do $$
begin
  assert private.fu_resposta_fria('Ok'), 'ok deveria ser resposta fria';
  assert private.fu_resposta_fria('Obrigada!'), 'obrigada deveria ser resposta fria';
  assert private.fu_resposta_fria('vou ver, obrigada'), 'vou ver, obrigada deveria ser fria';
  assert not private.fu_resposta_fria('quero 500 unidades'), 'pedido de quantidade não é resposta fria';
  assert exists (select 1 from public.followup_regras where codigo = 'Q2_RECUSA' and ativo), 'regra Q2_RECUSA ausente';
end $$;
rollback;
