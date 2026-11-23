-- CAPI Etapa 1: Purchase do WhatsApp no formato oficial (Conversions API for Business Messaging), atribuído ao anúncio.
-- Aditiva e idempotente. Pagamento nunca é bloqueado por causa da Meta (o gatilho engole qualquer erro).
--  * action_source 'business_messaging' + messaging_channel 'whatsapp' + ctwa_clid em user_data (o WABA entra na Edge Function).
--  * ctwa_clid vem da conversa (último anúncio), do primeiro anúncio do contato ou de outro contato com o mesmo telefone.
--  * Sem ctwa_clid o evento sai como 'system_generated' (casa só por telefone com hash) e o motivo fica em motivo_sem_ctwa.
--  * event_id estável por pagamento do Mercado Pago (purchase-<id do pagamento>); valor = o que o Mercado Pago aprovou.
--  * Estorno nunca gera evento (o gatilho só olha a virada para 'aprovado').

alter table public.meta_eventos add column if not exists ctwa_clid text;
alter table public.meta_eventos add column if not exists messaging_channel text;
alter table public.meta_eventos add column if not exists motivo_sem_ctwa text;
create index if not exists meta_eventos_ctwa on public.meta_eventos (event_name, ctwa_clid);

alter table public.meta_eventos drop constraint if exists meta_eventos_action_source_check;
alter table public.meta_eventos add constraint meta_eventos_action_source_check
  check (action_source in ('website', 'system_generated', 'chat', 'business_messaging'));

-- Telefone em E.164 só com dígitos (com 55 na frente quando vier sem DDI).
create or replace function private.meta_fone(p text)
returns text language sql immutable set search_path = '' as $$
  select case when d = '' then null when length(d) in (10, 11) then '55' || d else d end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x;
$$;

-- ctwa_clid do contato: conversa (anúncio mais recente), primeiro anúncio, ou outro contato com o mesmo telefone.
create or replace function private.meta_ctwa(p_contact uuid, out ctwa text, out motivo text)
language plpgsql stable security definer set search_path = '' as $$
declare v_fone text; v_tem_ref boolean;
begin
  select coalesce(nullif(v.last_referral ->> 'ctwa_clid', ''), nullif(c.first_referral ->> 'ctwa_clid', '')),
         (v.last_referral is not null or c.first_referral is not null), private.meta_fone(c.wa_id)
    into ctwa, v_tem_ref, v_fone
    from public.contacts c left join public.conversations v on v.contact_id = c.id where c.id = p_contact;
  if ctwa is not null then return; end if;
  if v_fone is not null then
    select nullif(c2.first_referral ->> 'ctwa_clid', '') into ctwa
      from public.contacts c2
     where c2.id <> p_contact and nullif(c2.first_referral ->> 'ctwa_clid', '') is not null
       and right(private.meta_fone(c2.wa_id), 8) = right(v_fone, 8)
     order by c2.first_referral_at desc nulls last limit 1;
    if ctwa is not null then motivo := 'casado_por_telefone'; return; end if;
  end if;
  motivo := case when coalesce(v_tem_ref, false) then 'referral_sem_ctwa_clid' else 'contato_sem_anuncio' end;
end $$;
revoke all on function private.meta_ctwa(uuid) from public, anon, authenticated;

create or replace function private.meta_purchase_do_pedido()
returns trigger language plpgsql security definer set search_path = '' as $$
declare c public.contacts%rowtype; v_total numeric; v_valor numeric; v_refs jsonb; v_itens integer;
        v_ctwa text; v_motivo text; v_fone text; v_ev text; v_src text;
begin
  if new.payment_status is distinct from 'aprovado' or old.payment_status is not distinct from 'aprovado' or coalesce(new.teste, false) then return new; end if;
  begin
    select * into c from public.contacts where id = new.contact_id;
    select total into v_total from public.order_financials where order_id = new.id;
    -- valor realmente aprovado no Mercado Pago (cai no total do pedido quando o pagamento foi confirmado à mão)
    select p.valor into v_valor from public.pagamentos p
     where p.order_id = new.id and p.status = 'aprovado' and p.mp_payment_id is not distinct from new.payment_external_id
     order by p.aprovado_em desc nulls last limit 1;
    select coalesce(jsonb_agg(e.ref) filter (where e.ref is not null), '[]'::jsonb), coalesce(sum(i.qty), 0)
      into v_refs, v_itens
      from public.order_items i left join public.ecommerce_products e on e.sku = i.code where i.order_id = new.id;
    v_fone := private.meta_fone(c.wa_id);
    if new.canal = 'site' then
      v_src := 'website';
    else
      select t.ctwa, t.motivo into v_ctwa, v_motivo from private.meta_ctwa(new.contact_id) t;
      v_src := case when v_ctwa is not null then 'business_messaging' else 'system_generated' end;
    end if;
    v_ev := 'purchase-' || coalesce(nullif(new.payment_external_id, ''), new.id::text);
    insert into public.meta_eventos (event_id, event_name, action_source, messaging_channel, ctwa_clid, motivo_sem_ctwa, event_time, user_data, custom_data, pedido_id)
    values (v_ev, 'Purchase', v_src, case when v_src = 'business_messaging' then 'whatsapp' end, v_ctwa,
            case when new.canal <> 'site' and v_ctwa is null then v_motivo end,
            coalesce(new.payment_confirmed_at, new.paid_at, now()),
            jsonb_strip_nulls(jsonb_build_object(
              'ph', private.sha256(v_fone),
              'em', private.sha256(c.email),
              'external_id', private.sha256(c.id::text),
              'ctwa_clid', v_ctwa,
              'ct', private.sha256(regexp_replace(lower(coalesce(c.municipio, '')), '[^a-z]', '', 'g')),
              'st', private.sha256(lower(c.uf)),
              'zp', private.sha256(regexp_replace(coalesce(c.cep, ''), '\D', '', 'g')),
              'country', private.sha256('br'))),
            jsonb_build_object('currency', 'BRL', 'value', coalesce(v_valor, v_total, 0), 'content_ids', v_refs, 'content_type', 'product',
                               'num_items', v_itens, 'order_id', 'SG-' || new.number, 'canal', new.canal),
            new.id)
    on conflict (event_id) do nothing;
  exception when others then
    -- a medição de anúncio nunca pode impedir a confirmação do pagamento
    raise warning 'meta_purchase_do_pedido: %', sqlerrm;
  end;
  return new;
end $$;
