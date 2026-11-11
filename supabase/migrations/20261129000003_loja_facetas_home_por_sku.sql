-- O cache de facetas da home passa a contar SKUs (um SKU = um produto), igual à lista.
create or replace function private.loja_facetas_cache_atualizar() returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into private.loja_facetas_cache (id, json, atualizado_em) values (true, public.loja_facetas_sku(null, null, '{}'::jsonb), now())
    on conflict (id) do update set json = excluded.json, atualizado_em = excluded.atualizado_em;
end $$;
select private.loja_facetas_cache_atualizar();
