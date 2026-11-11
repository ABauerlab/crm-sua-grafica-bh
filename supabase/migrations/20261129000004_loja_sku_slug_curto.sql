-- URL do SKU mais curta: sem a conversão repetida do tamanho ("105 x 150 mm (10,5 x 15 cm)" vira "105 x 150 mm"). A ref ao final continua sendo a âncora.
create or replace function private.loja_sku_slug_linha() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.ref is not null then
    new.sku_slug := private.loja_slug_sku(new.titulo, new.cores_rotulo, split_part(coalesce(new.formato_rotulo, ''), ' (', 1), new.quantidade, new.ref);
  end if;
  return new;
end $$;

update public.ecommerce_products
   set sku_slug = private.loja_slug_sku(titulo, cores_rotulo, split_part(coalesce(formato_rotulo, ''), ' (', 1), quantidade, ref)
 where ref is not null;
