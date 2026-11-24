-- Regressão 24/11/2026. Roda no banco com o catálogo real, como service_role, e desfaz tudo ao final.
begin;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $t$
declare r jsonb; v_skus text; v_cfg record; v_ex uuid;
begin
  -- Jordan: 10x15cm frente e verso tem que trazer PA65G6 (4X4, 100 x 150) como primeira opção
  r := public.buscar_produto('panfleto 10x15cm frente e verso', 1000, '{}'::jsonb);
  if r -> 'opcoes' -> 0 ->> 'sku' <> 'PA65G6' then raise exception 'PA65G6 deveria ser a 1ª opção, veio %', r -> 'opcoes' -> 0 ->> 'sku'; end if;
  r := public.buscar_produto('flyer 10 x 15 cm 4x4', 1000, '{}'::jsonb);
  select string_agg(o ->> 'sku', ',') into v_skus from jsonb_array_elements(r -> 'opcoes') o;
  if v_skus not like '%PA65G6%' then raise exception 'PA65G6 sumiu de 10 x 15 cm 4x4: %', v_skus; end if;
  -- medida sem tamanho no catálogo não pode zerar a busca
  r := public.buscar_produto('panfleto 12x18cm', 1000, '{}'::jsonb);
  if jsonb_array_length(r -> 'opcoes') = 0 then raise exception '12x18cm não pode zerar as opções'; end if;

  -- Alice: lista grande precisa caber nos limites da guarda de loop
  select * into v_cfg from public.agente_config where id = 1;
  if v_cfg.max_ferramenta_por_rodada < 15 or v_cfg.max_chamadas_por_rodada < 40 then raise exception 'limites de ferramenta voltaram a ser curtos'; end if;

  -- Paulo: com pedido pago, confirmar alteração é barrado; verificar com o responsável passa
  select ex.id into v_ex from public.agente_execucoes ex join public.orders o on o.contact_id = ex.contact_id
   where (o.payment_status = 'aprovado' or o.payment_manual) and o.excluido_em is null and coalesce(o.stage, '') not in ('entregue', 'perdido', 'cancelado') limit 1;
  if v_ex is not null then
    if not (private.saida_travas_extra(v_ex, 'Já anotei e confirmei com a produção para saírem sem furo.') @> array['promessa:alteracao_pos_pagamento']) then raise exception 'confirmação de alteração deveria ser barrada'; end if;
    if private.saida_travas_extra(v_ex, 'Vou verificar com o responsável se ainda dá pra ajustar antes da produção.') @> array['promessa:alteracao_pos_pagamento'] then raise exception 'verificação com o responsável não pode ser barrada'; end if;
  end if;

  -- Cron: pg_cron e conexão direta do banco valem como servidor
  if not private.dono_ou_servidor() or not private.atendente_ou_servidor() then raise exception 'cron sem permissão'; end if;
end
$t$;
rollback;
