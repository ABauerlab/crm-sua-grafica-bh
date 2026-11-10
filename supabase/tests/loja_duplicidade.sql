-- Duplicidade na vitrine: nunca pode haver duas opções ativas com o mesmo produto e a mesma quantidade (Fase 13b).
-- Rodar no SQL Editor depois de uma carga ou de `select private.loja_dedup()`.
do $$
declare v integer;
begin
  select count(*) into v from (select produto_slug, quantidade from public.ecommerce_products where ativo group by 1, 2 having count(*) > 1) x;
  if v > 0 then raise exception 'FALHOU: % opções ativas repetidas (mesmo produto e quantidade)', v; end if;

  -- produto ativo cujo slug junta títulos diferentes (acabamentos diferentes no mesmo produto)
  select count(*) into v from (select produto_slug from public.ecommerce_products where ativo group by 1 having count(distinct titulo) > 1) x;
  if v > 0 then raise exception 'FALHOU: % produtos com títulos diferentes no mesmo slug', v; end if;

  -- oculto nunca aparece na vitrine
  select count(*) into v from public.ecommerce_products where oculto and ativo;
  if v > 0 then raise exception 'FALHOU: % variantes ocultas ativas', v; end if;

  raise notice 'OK: sem duplicidade na vitrine';
end $$;
