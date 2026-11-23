-- 23/11/2026: a campanha (Black Friday) deixou de chegar ao /pagar/<token> quando a 20261222000012 recriou checkout_carregar
-- sem passar pelo wrapper da campanha (campanha = null em produção). Devolve a campanha no resumo público. Aditiva e idempotente.
create or replace function public.checkout_carregar(p_token text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r jsonb; o public.orders%rowtype;
begin
  r := public.checkout_carregar_pre_unidades(p_token);
  if not coalesce((r ->> 'ok')::boolean, false) then return r; end if;
  o := private.checkout_pedido(p_token);
  if o.id is null then return r; end if;
  r := jsonb_set(r, '{itens}', coalesce((
    select jsonb_agg(
             case when e ->> 'tipo' = 'produto' and m.u is not null then e || jsonb_build_object('unidades', m.u) else e end
             order by t.ord)
      from jsonb_array_elements(r -> 'itens') with ordinality as t(e, ord)
      left join lateral (
        select private.checkout_unidades_item(o.id, oi.code, oi.qty) as u
          from public.order_items oi
         where oi.order_id = o.id and oi.description = t.e ->> 'descricao' and oi.unit_price = (t.e ->> 'unitario')::numeric
           and oi.code is not null
         limit 1) m on true), r -> 'itens'));
  return r || jsonb_build_object('campanha', public.loja_campanha());
end;
$$;
revoke all on function public.checkout_carregar(text) from public, anon, authenticated;
grant execute on function public.checkout_carregar(text) to service_role;
