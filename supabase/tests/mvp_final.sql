-- MVP final: limites do orçamento, SKU desconhecido, alerta de valor alto e consolidação. Tudo desfeito no fim.
-- Rodar com papel de servidor (o teste ajusta as claims).
begin;
do $$
declare c uuid; a jsonb; b jsonb; d jsonb; exib jsonb; n int;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform set_config('request.jwt.claim.role', 'service_role', true);
  insert into public.contacts (name, wa_id, is_teste) values ('TESTE MVP FINAL', '5500000000098', true) returning id into c;
  a := public.montar_orcamento(c, '[{"sku":"SAC1OX500","quantidade":1},{"sku":"SAC1OX250","quantidade":1},{"sku":"SAC1OX50","quantidade":1}]', '{"teste":true}');
  if a ->> 'status' <> 'ok' then raise exception 'composição 500+250+50 deveria passar: %', a; end if;
  select itens_exibicao into exib from public.orcamentos where id = (a ->> 'orcamento_id')::uuid;
  if jsonb_array_length(exib) <> 1 or (exib -> 0 ->> 'quantidade')::int <> 800 then raise exception 'consolidação errada: %', exib; end if;
  select count(*) into n from public.alertas where tipo = 'orcamento_valor_alto' and (dados ->> 'orcamento_id') = a ->> 'orcamento_id';
  if (a ->> 'total')::numeric > 10000 and n <> 1 then raise exception 'faltou o alerta de valor alto'; end if;
  b := public.montar_orcamento(c, '[{"sku":"NAO-EXISTE-999","quantidade":1}]', '{"teste":true}');
  if b ->> 'motivo' <> 'sku_nao_encontrado' then raise exception 'esperava sku_nao_encontrado: %', b; end if;
  d := public.montar_orcamento(c, '[{"sku":"SAC1OX1000","quantidade":100}]', '{"teste":true}');
  if d ->> 'motivo' <> 'quantidade_irreal' then raise exception 'esperava quantidade_irreal: %', d; end if;
  if (select value ? 'valor_max_agente' from public.app_settings where key = 'orcamento_agente') then raise exception 'trava de R$ 5.000 ainda existe'; end if;
  if (public.calcular_preco('SAC1OX1', 1, '{}') ->> 'preco_total')::numeric
     < (select custo from public.catalogo where sku = 'SAC1OX1') + 1.80 then raise exception 'preço abaixo de custo + piso do bloco'; end if;
  raise notice 'OK: mvp_final';
end $$;
rollback;
