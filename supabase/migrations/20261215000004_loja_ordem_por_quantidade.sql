-- Loja: dentro do mesmo produto e formato, a lista passa a seguir a ordem do fornecedor:
-- primeiro todas as variações de impressão de uma quantidade, depois todas as da quantidade seguinte
-- (antes era impressão primeiro e quantidade depois). Aditiva e idempotente.
do $mig$
declare r record; d text; a text := 'b.titulo, b.formato, private.loja_ordem_impressao(b.impressao), b.quantidade, b.preco, b.sku) rn';
begin
  for r in select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'loja_sku_lista' loop
    d := pg_get_functiondef(r.oid);
    if position(a in d) > 0 then
      execute replace(d, a, 'b.titulo, b.formato, b.quantidade, private.loja_ordem_impressao(b.impressao), b.preco, b.sku) rn');
    end if;
  end loop;
end
$mig$;
