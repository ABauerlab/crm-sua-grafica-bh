-- 19/11/2026: o cordão de crachá (categoria CORDÕES) está cadastrado com a embalagem do fornecedor (até 162 cm de comprimento), acima do limite
-- dos Correios (100 cm), e o checkout dizia "não conseguimos cotar o envio". Cordão é flexível e vai dobrado: o pacote do envio passa a ser
-- dobrado ao meio (ou em mais partes) até caber em 100 cm, e a altura multiplica pelo número de dobras. Só a categoria CORDÕES; bandeiras,
-- banners, totens e afins seguem como "pacote grande" (não cabem nos Correios). Aditiva e idempotente (patch da função existente).
do $m$
declare d text;
begin
  select pg_get_functiondef('public.loja_frete_base(jsonb, text, text)'::regprocedure) into d;
  if position('v_dobras' in d) = 0 then
    d := replace(d, 'v_ok boolean := true;', 'v_ok boolean := true; v_dobras integer;');
    d := replace(d, 'select peso_frete_kg, embalagem_cm into c from public.catalogo where sku = v_sku;', 'select peso_frete_kg, embalagem_cm, categoria into c from public.catalogo where sku = v_sku;');
    d := replace(d, 'if d is null or coalesce(c.peso_frete_kg, 0) <= 0 then v_ok := false; continue; end if;',
      'if d is not null and d[3] > 100 and c.categoria = ''CORDÕES'' then v_dobras := ceil(d[3] / 100)::integer; d := array[d[1] * v_dobras, d[2], ceil(d[3] / v_dobras)]; end if;' || chr(10) ||
      '    if d is null or coalesce(c.peso_frete_kg, 0) <= 0 then v_ok := false; continue; end if;');
    if position('v_dobras' in d) = 0 or position('categoria into c' in d) = 0 or position('v_dobras := ceil' in d) = 0 then raise exception 'loja_frete_base mudou: ajuste o patch.'; end if;
    execute d;
  end if;
end $m$;
revoke all on function public.loja_frete_base(jsonb, text, text) from public, anon, authenticated;
grant execute on function public.loja_frete_base(jsonb, text, text) to service_role;
