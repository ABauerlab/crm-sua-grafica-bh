-- Regressão da trava de qualificação (11/11/2026, primeira venda automática).
-- Rodar logado como service role. Reconstrói o estado das 22:40:03 do orçamento SG-0364 (pergunta sem resposta) e confere que bloqueia.
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$
declare r jsonb;
begin
  select public.orcamento_gate_qualificacao(q.id, '2026-11-11 22:40:03-03'::timestamptz, true) into r from public.orcamentos q where q.numero = 364;
  if r is null then raise notice 'SG-0364 não existe neste banco: teste ignorado'; return; end if;
  if (r ->> 'pode')::boolean is not false or r ->> 'motivo' <> 'aguardando_resposta_do_cliente' then
    raise exception 'Esperava bloqueio aguardando_resposta_do_cliente, veio %', r;
  end if;
end $$;
