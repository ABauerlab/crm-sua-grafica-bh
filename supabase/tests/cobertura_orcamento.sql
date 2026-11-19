-- Cobertura de orçamento concorrente (19/11/2026). Roda em transação e desfaz tudo (rollback).
-- Caso real: cartão de retrovisor, concorrente de BH com CNPJ e endereço (100 un. R$ 89 | 500 un. R$ 290 | 1.000 un. R$ 390).
-- Esperado: 100 un. e 1.000 un. recusadas (abaixo do piso da cobertura); 500 un. coberta pela versão Digital (CRT0004), lucro bruto >= R$ 65.
begin;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $$
declare v_c uuid; r jsonb; v_f jsonb; v_o record;
begin
  select id into v_c from public.contacts where is_teste limit 1;
  if v_c is null then select id into v_c from public.contacts limit 1; end if;

  -- 1) sem CNPJ: recusa e pede o documento completo
  r := public.cobrir_orcamento(v_c, '[{"sku":"CRT0004","quantidade":1,"valor_concorrente":290}]', '{"cidade_concorrente":"Belo Horizonte","uf_concorrente":"MG","endereco_concorrente":"Rua Teste 100, Centro"}');
  if r ->> 'motivo' <> 'cnpj_ausente_ou_invalido' then raise exception 'esperava recusa por CNPJ: %', r; end if;

  -- 2) fora da região (Rio de Janeiro): recusa
  r := public.cobrir_orcamento(v_c, '[{"sku":"CRT0004","quantidade":1,"valor_concorrente":290}]', '{"cnpj_concorrente":"11.222.333/0001-81","cidade_concorrente":"Rio de Janeiro","uf_concorrente":"RJ","endereco_concorrente":"Rua do Rio 10, Taquara"}');
  if r ->> 'motivo' <> 'concorrente_fora_da_regiao' then raise exception 'esperava recusa por região: %', r; end if;

  -- 3) caso válido de BH
  r := public.cobrir_orcamento(v_c, '[{"sku":"CRT0002","quantidade":1,"valor_concorrente":89},{"sku":"CRT0009","quantidade":1,"valor_concorrente":290,"tem_verniz":true},{"sku":"CRT0005","quantidade":1,"valor_concorrente":390}]',
    '{"cnpj_concorrente":"11.222.333/0001-81","cidade_concorrente":"Belo Horizonte","uf_concorrente":"MG","endereco_concorrente":"Rua Teste 100, Centro","teste":true}');
  if (r ->> 'cobertas')::int <> 1 then raise exception 'esperava 1 faixa coberta: %', r; end if;
  if (r -> 'faixas' -> 0 ->> 'cobrivel')::boolean or (r -> 'faixas' -> 2 ->> 'cobrivel')::boolean then raise exception 'faixas de 100 e 1000 deveriam ser recusadas: %', r; end if;
  v_f := r -> 'faixas' -> 1;
  if not (v_f ->> 'eh_alternativa_sem_acabamento')::boolean then raise exception 'esperava alternativa sem acabamento: %', v_f; end if;
  select o.total, o.custo_total, o.regra_preco into v_o from public.orcamentos o where o.id = (v_f ->> 'orcamento_id')::uuid;
  if v_o.regra_preco <> 'cobertura_concorrente' or v_o.total >= 290 then raise exception 'orçamento criado errado: %', row_to_json(v_o); end if;
  if v_o.total - 220.99 < 65 then raise exception 'lucro bruto abaixo de R$ 65: %', v_o.total; end if;
  if public.validar_margem((v_f ->> 'orcamento_id')::uuid) ->> 'status' <> 'ok' then raise exception 'validar_margem bloqueou'; end if;
  -- nada de dado interno na resposta
  if r::text ~* '(custo|piso|margem_|fornecedor)' then raise exception 'resposta vazou dado interno: %', r; end if;
end $$;
rollback;
