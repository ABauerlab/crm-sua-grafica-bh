-- Lote 2: a busca base esconde um dos SKUs gêmeos (mesma descrição, preço 2x ou mais diferente).
-- Esta função devolve também os gêmeos faltantes, cada um com o preço de calcular_preco e o rótulo diferencial
-- (ex.: ROLLUP001 kit completo x COM0013 só a lona), para a Laura nunca trocar um pelo outro.
create or replace function private.buscar_completar_gemeos(p_ops jsonb)
 returns jsonb language plpgsql stable set search_path to ''
as $f$
declare o jsonb; g record; pr jsonb; extra jsonb := '[]'::jsonb;
begin
  for o in select value from jsonb_array_elements(p_ops) loop
    continue when not coalesce((o ->> 'sku_gemeo')::boolean, false);
    for g in
      select c.sku, c.quantidade, concat_ws(' ', c.categoria, c.descricao, c.cores, c.tamanho_mm) as descr
        from public.catalogo_gemeos gm0
        join public.catalogo_gemeos gm on gm.grupo = gm0.grupo and gm.sku <> gm0.sku
        join public.catalogo c on c.sku = gm.sku
       where gm0.sku = o ->> 'sku' and c.status_venda = 'vender' and c.active
         and not exists (select 1 from jsonb_array_elements(p_ops || extra) x where x ->> 'sku' = c.sku)
       order by c.sku limit 3
    loop
      pr := public.calcular_preco(g.sku, g.quantidade, '{}'::jsonb);
      continue when not coalesce((pr ->> 'ok')::boolean, false) or not coalesce((pr ->> 'lucro_ok')::boolean, false) or (pr ->> 'preco_total') is null;
      extra := extra || jsonb_build_array(private.buscar_enriquecer_opcao(jsonb_build_object(
        'sku', g.sku, 'preco', (pr ->> 'preco_total')::numeric, 'quantidade', g.quantidade, 'vendavel', true,
        'quantidade_exata', true, 'descricao_curta', g.descr)));
    end loop;
  end loop;
  return p_ops || extra;
end;
$f$;
revoke execute on function private.buscar_completar_gemeos(jsonb) from public, anon, authenticated;

do $do$
declare v_def text;
  v_old text := $o$    r := jsonb_set(r, '{opcoes}', v_ops);
    select bool_or$o$;
  v_new text := $n$    v_ops := private.buscar_completar_gemeos(v_ops); /* gemeos_completar */
    r := jsonb_set(r, '{opcoes}', v_ops);
    select bool_or$n$;
begin
  select pg_get_functiondef('public.buscar_produto(text, integer, jsonb)'::regprocedure) into v_def;
  if position('gemeos_completar' in v_def) > 0 then return; end if;
  if position(v_old in v_def) = 0 then raise exception 'wrapper: trecho esperado não encontrado'; end if;
  execute replace(v_def, v_old, v_new);
end $do$;
revoke execute on function public.buscar_produto(text, integer, jsonb) from public, anon;
grant execute on function public.buscar_produto(text, integer, jsonb) to authenticated, service_role;
