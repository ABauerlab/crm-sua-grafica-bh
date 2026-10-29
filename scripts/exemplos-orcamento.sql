-- Gera os documentos dos 6 orçamentos de exemplo no Postgres LOCAL descartável (catálogo fictício, nada de produção).
-- Uso: scripts/gerar-exemplos-orcamento.ts (roda esta consulta e renderiza os PDFs). Tudo é desfeito no final.
begin;
select set_config('request.jwt.claim.role', 'service_role', true);
create temp table _ex (n serial, nome text, doc jsonb) on commit drop;
do $$
declare
  c uuid; r jsonb; o uuid; cond jsonb; g text;
begin
  insert into public.contacts (wa_id, name) values ('5531900009000', 'Mariana Souza') returning id into c;
  delete from public.precos_mercado;

  r := public.montar_orcamento(c, '[{"sku":"CFV02","quantidade":1}]', '{"arte":"cliente"}');
  insert into _ex (nome, doc) values ('01-cartao-simples', public.orcamento_documento((r ->> 'orcamento_id')::uuid));

  r := public.montar_orcamento(c, '[{"sku":"CFV02","quantidade":1},{"sku":"PFL01","quantidade":1},{"sku":"ADV01","quantidade":2}]', '{"arte":"paga","bairro":"Savassi"}');
  insert into _ex (nome, doc) values ('02-kit-divulgacao', public.orcamento_documento((r ->> 'orcamento_id')::uuid));

  r := public.montar_orcamento(c, '[{"sku":"CFV02","quantidade":1}]', '{"arte":"paga"}');
  insert into _ex (nome, doc) values ('03-com-arte', public.orcamento_documento((r ->> 'orcamento_id')::uuid));

  r := public.montar_orcamento(c, '[{"sku":"CFV02","quantidade":1}]', '{"arte":"com_frete","bairro":"Funcionários"}');
  insert into _ex (nome, doc) values ('04-entrega-central-gratis', public.orcamento_documento((r ->> 'orcamento_id')::uuid));

  r := public.montar_orcamento(c, '[{"sku":"PFL01","quantidade":1}]', '{"arte":"cliente","bairro":"Contagem"}');
  insert into _ex (nome, doc) values ('05-fora-da-regiao', public.orcamento_documento((r ->> 'orcamento_id')::uuid));

  -- condição especial: com mercado a preço folgado, a função decide o desconto e gera o orçamento atualizado
  insert into public.precos_mercado (sku, chave_especificacao, fonte, preco, confianca)
    select 'CFV02', (select especificacao_normalizada from public.catalogo where sku = 'CFV02'), f, p, 'alta'
      from (values ('a.com.br', 330.00), ('b.com.br', 340.00), ('c.com.br', 350.00)) t (f, p);
  r := public.montar_orcamento(c, '[{"sku":"CFV02","quantidade":1}]', '{"arte":"paga"}');
  o := (r ->> 'orcamento_id')::uuid;
  update public.orcamentos set status = 'enviado' where id = o;
  foreach g in array array['G1', 'G2', 'G3'] loop
    cond := public.oferecer_condicao_especial(o, g);
    exit when cond ->> 'tipo' <> 'sem_condicao';
  end loop;
  if cond ->> 'tipo' = 'sem_condicao' then raise exception 'sem condição para o exemplo: %', cond; end if;
  insert into _ex (nome, doc) values ('06-condicao-especial-' || (cond ->> 'tipo'), public.orcamento_documento((cond ->> 'orcamento_id')::uuid));
end $$;
select jsonb_agg(jsonb_build_object('nome', nome, 'doc', doc) order by n) from _ex;
rollback;
