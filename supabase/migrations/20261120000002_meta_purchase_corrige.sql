-- Correção do gatilho de Purchase: faltava o valor de pedido_id no insert, o que fazia a confirmação de pagamento falhar.
-- Agora o gatilho também engole qualquer erro de medição (vira aviso no log): pagamento nunca é bloqueado por causa da Meta.
-- Purchase: um por pedido (event_id = purchase-<pedido>), quando o pagamento é aprovado. Pedido de teste não conta.
create or replace function private.meta_purchase_do_pedido()
returns trigger language plpgsql security definer set search_path = '' as $$
declare c public.contacts%rowtype; v_total numeric; v_refs jsonb; v_itens integer;
begin
  if new.payment_status is distinct from 'aprovado' or old.payment_status is not distinct from 'aprovado' or coalesce(new.teste, false) then return new; end if;
  begin
  select * into c from public.contacts where id = new.contact_id;
  select total into v_total from public.order_financials where order_id = new.id;
  select coalesce(jsonb_agg(e.ref) filter (where e.ref is not null), '[]'::jsonb), coalesce(sum(i.qty), 0)
    into v_refs, v_itens
    from public.order_items i left join public.ecommerce_products e on e.sku = i.code where i.order_id = new.id;
  insert into public.meta_eventos (event_id, event_name, action_source, event_time, user_data, custom_data, pedido_id)
  values ('purchase-' || new.id::text, 'Purchase', case when new.canal = 'site' then 'website' else 'chat' end, coalesce(new.paid_at, now()),
          jsonb_strip_nulls(jsonb_build_object(
            'ph', private.sha256(regexp_replace(coalesce(c.wa_id, ''), '\D', '', 'g')),
            'em', private.sha256(c.email),
            'external_id', private.sha256(c.id::text),
            'ct', private.sha256(regexp_replace(lower(coalesce(c.municipio, '')), '[^a-z]', '', 'g')),
            'st', private.sha256(lower(c.uf)),
            'zp', private.sha256(regexp_replace(coalesce(c.cep, ''), '\D', '', 'g')),
            'country', private.sha256('br'))),
          jsonb_build_object('currency', 'BRL', 'value', coalesce(v_total, 0), 'content_ids', v_refs, 'content_type', 'product',
                             'num_items', v_itens, 'order_id', 'SG-' || new.number, 'canal', new.canal),
          new.id)
  on conflict (event_id) do nothing;
  exception when others then
    -- a medição de anúncio nunca pode impedir a confirmação do pagamento
    raise warning 'meta_purchase_do_pedido: %', sqlerrm;
  end;
  return new;
end $$;
