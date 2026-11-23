-- 23/11/2026: o checkout (/pagar/<token>) é o espelho do que foi negociado no WhatsApp.
-- Problema (pedido #432): o cliente pediu 5 crachás, o orçamento mostrava 5 un., mas o pedido guarda a linha como
-- 1 pacote (qty = 1) e o checkout mostrava "1 un. x R$ 86,90", o que parecia cobrança de 1 unidade só.
-- Correção: o banco passa a devolver `unidades` em cada item do resumo público, igual ao PDF do orçamento
-- (unidades que o cliente pediu; valores e totais NÃO mudam). Aditiva e idempotente.

-- Unidades reais de uma linha do pedido: as do orçamento (unidades_cliente) quando o SKU aparece uma vez só no pedido;
-- senão, quantidade x tamanho do lote do catálogo.
create or replace function private.checkout_unidades_item(p_order uuid, p_code text, p_qty integer) returns integer
language plpgsql stable security definer set search_path = ''
as $$
declare v_n integer; v_u integer; v_orc uuid; v_lote integer;
begin
  if p_code is null then return null; end if;
  select count(*) into v_n from public.order_items where order_id = p_order and code = p_code;
  if v_n = 1 then
    select id into v_orc from public.orcamentos where order_id = p_order order by criado_em desc limit 1;
    if v_orc is not null then
      select sum(unidades_cliente)::integer into v_u from public.orcamento_itens where orcamento_id = v_orc and sku = p_code and unidades_cliente > 0;
      if v_u > 0 then return v_u; end if;
    end if;
  end if;
  select coalesce(quantidade, 1) into v_lote from public.catalogo where sku = p_code;
  return greatest(coalesce(p_qty, 1), 1) * greatest(coalesce(v_lote, 1), 1);
end;
$$;
revoke all on function private.checkout_unidades_item(uuid, text, integer) from public, anon, authenticated;

do $m$
begin
  if to_regprocedure('public.checkout_carregar_pre_unidades(text)') is null then
    alter function public.checkout_carregar(text) rename to checkout_carregar_pre_unidades;
  end if;
end $m$;
revoke all on function public.checkout_carregar_pre_unidades(text) from public, anon, authenticated;
grant execute on function public.checkout_carregar_pre_unidades(text) to service_role;

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
  return r;
end;
$$;
revoke all on function public.checkout_carregar(text) from public, anon, authenticated;
grant execute on function public.checkout_carregar(text) to service_role;
