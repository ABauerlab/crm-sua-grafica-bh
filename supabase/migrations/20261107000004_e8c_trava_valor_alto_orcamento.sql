-- Etapa 8C: trava determinística contra orçamento absurdo feito pelo agente (ex.: R$ 23 mil).
-- Causa provável: a quantidade do item de montar_orcamento é o número de PACOTES da opção (1 = a quantidade do SKU), mas o modelo
-- pode mandar a quantidade em unidades (ex.: 50 pacotes de 1000 = 50 mil unidades). O banco aceitava até 50 pacotes e qualquer total.
-- Agora: máximo de 20 pacotes por item e total acima de app_settings 'orcamento_agente'.valor_max_agente (padrão R$ 5.000) vira
-- 'bloqueado: valor_alto' (o agente chama o dono). Idempotente: aplica o patch uma vez sobre a definição atual.
do $m$
declare d text;
begin
  select pg_get_functiondef('public.montar_orcamento(uuid,jsonb,jsonb)'::regprocedure) into d;
  if d like '%valor_max_agente%' then return; end if;
  d := replace(d, 'v_qtd > 50', 'v_qtd > 20');
  d := replace(d, 'quantidade de 1 a 50', 'quantidade de 1 a 20');
  d := replace(d, 'select total into v_total from public.orcamentos where id = v_id;',
    $b$select total into v_total from public.orcamentos where id = v_id;
  if v_total > coalesce((select (value ->> 'valor_max_agente')::numeric from public.app_settings where key = 'orcamento_agente'), 5000) then
    delete from public.orcamentos where id = v_id;
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'valor_alto',
                              'alternativa', 'Pedido de valor alto: não informe valor; diga que vai conferir as condições e chame o dono.');
  end if;$b$);
  execute d;
end
$m$;
