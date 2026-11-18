-- Teste do kit agregado "Crachá + cordão" (18/11/2026). Roda como service_role e desfaz tudo no fim.
-- Esperado (decisão do dono, 18/11: o foco é lucrar): o kit só marca o orçamento, NÃO baixa o preço (total igual à soma
-- dos itens da planilha) e validar_margem continua ok. O DO termina com exceção de propósito (rollback).
do $t$
declare
  v_c uuid; v_res jsonb; v_sem numeric; v_com numeric; v_val jsonb;
begin
  perform set_config('request.jwt.claim.role', 'service_role', true);
  select id into v_c from public.contacts order by created_at desc limit 1;
  v_res := public.montar_orcamento(v_c, jsonb_build_array(jsonb_build_object('sku', 'CRCH4010', 'quantidade', 1), jsonb_build_object('sku', 'COR07C', 'quantidade', 1)), jsonb_build_object('teste', true));
  if v_res ->> 'status' <> 'ok' then raise exception 'orçamento não montou: %', v_res; end if;
  select coalesce(sum(i.quantidade * c.preco_venda), 0) into v_sem from public.orcamento_itens i join public.catalogo c on c.sku = i.sku where i.orcamento_id = (v_res ->> 'orcamento_id')::uuid;
  v_com := (v_res ->> 'total')::numeric;
  if v_res -> 'kit' is null then raise exception 'o kit não foi aplicado'; end if;
  if v_com <> v_sem then raise exception 'o kit não pode mexer no preço (sem=% com=%)', v_sem, v_com; end if;
  v_val := public.validar_margem((v_res ->> 'orcamento_id')::uuid);
  if v_val ->> 'status' <> 'ok' then raise exception 'trava de lucro recusou o kit: %', v_val; end if;
  raise exception 'OK (rollback): kit aplicado sem mexer no preço (total %)', v_com;
end
$t$;
