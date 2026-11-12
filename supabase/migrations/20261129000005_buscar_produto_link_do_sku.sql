-- buscar_produto (ferramenta da Laura) passa a devolver o link da página do SKU exato (um SKU = um produto na loja).
-- Aditiva: só acrescenta o campo link_produto a cada opção; o contrato antigo continua igual.
do $mig$
declare d text;
begin
  select pg_get_functiondef('public.buscar_produto(text,integer,jsonb)'::regprocedure) into d;
  if d like '%link_produto%' then return; end if;
  d := replace(d,
    $a$'quantidade_exata', v_qtd is not null and r.quantidade = v_qtd, 'em_palavras'$a$,
    $b$'quantidade_exata', v_qtd is not null and r.quantidade = v_qtd,
      'link_produto', (select 'https://suagraficabh.com.br/produto/' || e.sku_slug from public.ecommerce_products e where e.sku = r.sku and e.ativo limit 1),
      'em_palavras'$b$);
  if d not like '%link_produto%' then raise exception 'buscar_produto: ponto de inserção não encontrado'; end if;
  execute d;
end $mig$;
