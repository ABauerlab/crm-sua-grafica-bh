-- CAPI Etapa 2: eventos antes da compra (WhatsApp) + reenvio dos Purchases 407 e 426 com ctwa_clid.
-- Aditiva e idempotente. Todo gatilho engole erro: medição de anúncio nunca bloqueia contato, link nem pagamento.
--  * Lead (nome configurável em app_settings.meta_capi.lead_chat_evento, padrão LeadSubmitted, o nome que a Meta documenta para
--    Business Messaging): uma vez por contato, no primeiro ctwa_clid. event_id = lead-<contato>.
--  * InitiateCheckout: uma vez por pedido, quando o link de pagamento é gerado. event_id = ic-<pedido>.
--  * Só com ctwa_clid e clique de até 7 dias; fora disso o evento é gravado como 'descartado' com o motivo (auditoria).
--  * Números de teste e contatos de teste nunca geram evento.

alter table public.meta_eventos add column if not exists motivo text;
alter table public.meta_eventos drop constraint if exists meta_eventos_event_name_check;
alter table public.meta_eventos add constraint meta_eventos_event_name_check
  check (event_name in ('PageView', 'ViewContent', 'AddToCart', 'InitiateCheckout', 'Lead', 'LeadSubmitted', 'QualifiedLead', 'Purchase', 'Contact'));

-- meta_ctwa passa a devolver também a hora do clique (para a regra dos 7 dias)
drop function if exists private.meta_ctwa(uuid);
create or replace function private.meta_ctwa(p_contact uuid, out ctwa text, out motivo text, out clique_em timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare v_conv text; v_first text; v_first_at timestamptz; v_janela timestamptz; v_tem_ref boolean; v_fone text;
begin
  select nullif(v.last_referral ->> 'ctwa_clid', ''), nullif(c.first_referral ->> 'ctwa_clid', ''), c.first_referral_at, v.ad_window_until,
         (v.last_referral is not null or c.first_referral is not null), private.meta_fone(c.wa_id)
    into v_conv, v_first, v_first_at, v_janela, v_tem_ref, v_fone
    from public.contacts c left join public.conversations v on v.contact_id = c.id where c.id = p_contact;
  if v_conv is not null then
    ctwa := v_conv;
    -- anúncio mais recente da conversa: a janela de 72 h começa no clique
    clique_em := case when v_conv is not distinct from v_first then v_first_at else coalesce(v_janela - interval '72 hours', v_first_at) end;
    return;
  end if;
  if v_first is not null then ctwa := v_first; clique_em := v_first_at; return; end if;
  if v_fone is not null then
    select nullif(c2.first_referral ->> 'ctwa_clid', ''), c2.first_referral_at into ctwa, clique_em
      from public.contacts c2
     where c2.id <> p_contact and nullif(c2.first_referral ->> 'ctwa_clid', '') is not null
       and right(private.meta_fone(c2.wa_id), 8) = right(v_fone, 8)
     order by c2.first_referral_at desc nulls last limit 1;
    if ctwa is not null then motivo := 'casado_por_telefone'; return; end if;
  end if;
  motivo := case when coalesce(v_tem_ref, false) then 'referral_sem_ctwa_clid' else 'contato_sem_anuncio' end;
end $$;
revoke all on function private.meta_ctwa(uuid) from public, anon, authenticated;

create or replace function private.meta_eh_teste(p_contact uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(c.is_teste, false) or exists (
    select 1 from public.numeros_teste n
     where length(regexp_replace(n.telefone, '\D', '', 'g')) >= 8
       and right(private.meta_fone(c.wa_id), 10) = right(regexp_replace(n.telefone, '\D', '', 'g'), 10))
  from public.contacts c where c.id = p_contact;
$$;
revoke all on function private.meta_eh_teste(uuid) from public, anon, authenticated;

-- Dados do cliente com hash (mesmos campos do Purchase) + ctwa_clid em texto puro
create or replace function private.meta_user_data(p_contact uuid, p_ctwa text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'ph', private.sha256(private.meta_fone(c.wa_id)),
    'em', private.sha256(c.email),
    'external_id', private.sha256(c.id::text),
    'ctwa_clid', p_ctwa,
    'ct', private.sha256(regexp_replace(lower(coalesce(c.municipio, '')), '[^a-z]', '', 'g')),
    'st', private.sha256(lower(c.uf)),
    'zp', private.sha256(regexp_replace(coalesce(c.cep, ''), '\D', '', 'g')),
    'country', private.sha256('br')))
  from public.contacts c where c.id = p_contact;
$$;
revoke all on function private.meta_user_data(uuid, text) from public, anon, authenticated;

-- Lead: primeiro contato vindo de anúncio
create or replace function private.meta_lead_do_contato()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_ctwa text := nullif(new.first_referral ->> 'ctwa_clid', ''); v_nome text; v_quando timestamptz; v_velho boolean;
begin
  if v_ctwa is null then return new; end if;
  if tg_op = 'UPDATE' and nullif(old.first_referral ->> 'ctwa_clid', '') is not null then return new; end if;
  begin
    if private.meta_eh_teste(new.id) then return new; end if;
    select coalesce(nullif(s.value ->> 'lead_chat_evento', ''), 'LeadSubmitted') into v_nome from public.app_settings s where s.key = 'meta_capi';
    v_nome := coalesce(v_nome, 'LeadSubmitted');
    v_quando := coalesce(new.first_referral_at, now());
    v_velho := v_quando < now() - interval '7 days';
    insert into public.meta_eventos (event_id, event_name, action_source, messaging_channel, ctwa_clid, event_time, user_data, custom_data, status, erro, motivo)
    values ('lead-' || new.id::text, v_nome, 'business_messaging', 'whatsapp', v_ctwa, v_quando,
            private.meta_user_data(new.id, v_ctwa), jsonb_build_object('canal', 'whatsapp'),
            case when v_velho then 'descartado' else 'pendente' end, case when v_velho then 'clique com mais de 7 dias' end,
            'primeiro_contato_de_anuncio')
    on conflict (event_id) do nothing;
  exception when others then
    raise warning 'meta_lead_do_contato: %', sqlerrm;
  end;
  return new;
end $$;
revoke all on function private.meta_lead_do_contato() from public, anon, authenticated;
drop trigger if exists meta_lead_do_contato on public.contacts;
create trigger meta_lead_do_contato after insert or update of first_referral on public.contacts
  for each row execute function private.meta_lead_do_contato();

-- InitiateCheckout: link de pagamento gerado (uma vez por pedido, mesmo que o link seja refeito)
create or replace function private.meta_checkout_do_pagamento()
returns trigger language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype; v_ctwa text; v_clique timestamptz; v_velho boolean;
begin
  if not coalesce(new.eh_link, false) then return new; end if;
  begin
    select * into o from public.orders where id = new.order_id;
    if not found or o.canal = 'site' or coalesce(o.teste, false) or private.meta_eh_teste(o.contact_id) then return new; end if;
    select t.ctwa, t.clique_em into v_ctwa, v_clique from private.meta_ctwa(o.contact_id) t;
    if v_ctwa is null then return new; end if;
    v_velho := v_clique is null or v_clique < now() - interval '7 days';
    insert into public.meta_eventos (event_id, event_name, action_source, messaging_channel, ctwa_clid, event_time, user_data, custom_data, pedido_id, status, erro, motivo)
    values ('ic-' || o.id::text, 'InitiateCheckout', 'business_messaging', 'whatsapp', v_ctwa, coalesce(new.criado_em, now()),
            private.meta_user_data(o.contact_id, v_ctwa),
            jsonb_build_object('currency', 'BRL', 'value', new.valor, 'order_id', 'SG-' || o.number, 'canal', o.canal),
            o.id, case when v_velho then 'descartado' else 'pendente' end,
            case when v_velho then 'clique com mais de 7 dias ou sem data do clique' end, 'link_de_pagamento_gerado')
    on conflict (event_id) do nothing;
  exception when others then
    raise warning 'meta_checkout_do_pagamento: %', sqlerrm;
  end;
  return new;
end $$;
revoke all on function private.meta_checkout_do_pagamento() from public, anon, authenticated;
drop trigger if exists meta_checkout_do_pagamento on public.pagamentos;
create trigger meta_checkout_do_pagamento after insert on public.pagamentos
  for each row execute function private.meta_checkout_do_pagamento();

-- Reenvio dos Purchases com anúncio que saíram sem ctwa_clid (pedidos 407 e 426), só se o clique e a aprovação têm até 7 dias.
-- O envio antigo fica no histórico com a explicação; o novo usa o event_id padrão por pagamento do Mercado Pago.
do $$
declare r record; v_ctwa text; v_clique timestamptz; v_valor numeric; v_refs jsonb; v_itens integer; v_novo text;
begin
  for r in select o.* from public.orders o where o.number in (407, 426) and o.payment_status = 'aprovado' and nullif(o.payment_external_id, '') is not null loop
    select t.ctwa, t.clique_em into v_ctwa, v_clique from private.meta_ctwa(r.contact_id) t;
    continue when v_ctwa is null or v_clique is null or v_clique < now() - interval '7 days' or coalesce(r.payment_confirmed_at, r.paid_at) < now() - interval '7 days';
    v_novo := 'purchase-' || r.payment_external_id;
    select p.valor into v_valor from public.pagamentos p where p.order_id = r.id and p.status = 'aprovado' and p.mp_payment_id is not distinct from r.payment_external_id order by p.aprovado_em desc nulls last limit 1;
    select coalesce(jsonb_agg(e.ref) filter (where e.ref is not null), '[]'::jsonb), coalesce(sum(i.qty), 0) into v_refs, v_itens
      from public.order_items i left join public.ecommerce_products e on e.sku = i.code where i.order_id = r.id;
    insert into public.meta_eventos (event_id, event_name, action_source, messaging_channel, ctwa_clid, event_time, user_data, custom_data, pedido_id, motivo)
    values (v_novo, 'Purchase', 'business_messaging', 'whatsapp', v_ctwa, coalesce(r.payment_confirmed_at, r.paid_at),
            private.meta_user_data(r.contact_id, v_ctwa),
            jsonb_build_object('currency', 'BRL', 'value', coalesce(v_valor, (select total from public.order_financials where order_id = r.id), 0),
                               'content_ids', v_refs, 'content_type', 'product', 'num_items', v_itens, 'order_id', 'SG-' || r.number, 'canal', r.canal),
            r.id, 'reenvio_com_ctwa_clid: o primeiro envio saiu sem ctwa_clid e com action_source chat; clique em ' || to_char(v_clique at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC, dentro de 7 dias')
    on conflict (event_id) do nothing;
    update public.meta_eventos set motivo = coalesce(motivo, 'substituido_por ' || v_novo || ': saiu sem ctwa_clid e com action_source chat')
     where pedido_id = r.id and event_name = 'Purchase' and event_id <> v_novo and ctwa_clid is null;
  end loop;
end $$;

-- Preenchimento do que ainda está dentro dos 7 dias do clique (mesma regra do gatilho; os mais velhos não entram)
insert into public.meta_eventos (event_id, event_name, action_source, messaging_channel, ctwa_clid, event_time, user_data, custom_data, motivo)
select 'lead-' || c.id::text, coalesce((select nullif(s.value ->> 'lead_chat_evento', '') from public.app_settings s where s.key = 'meta_capi'), 'LeadSubmitted'),
       'business_messaging', 'whatsapp', c.first_referral ->> 'ctwa_clid', c.first_referral_at,
       private.meta_user_data(c.id, c.first_referral ->> 'ctwa_clid'), jsonb_build_object('canal', 'whatsapp'), 'primeiro_contato_de_anuncio'
  from public.contacts c
 where nullif(c.first_referral ->> 'ctwa_clid', '') is not null and c.first_referral_at > now() - interval '7 days'
   and not private.meta_eh_teste(c.id)
on conflict (event_id) do nothing;

insert into public.meta_eventos (event_id, event_name, action_source, messaging_channel, ctwa_clid, event_time, user_data, custom_data, pedido_id, motivo)
select 'ic-' || x.order_id::text, 'InitiateCheckout', 'business_messaging', 'whatsapp', x.ctwa, x.criado_em,
       private.meta_user_data(x.contact_id, x.ctwa),
       jsonb_build_object('currency', 'BRL', 'value', x.valor, 'order_id', 'SG-' || x.number, 'canal', x.canal), x.order_id, 'link_de_pagamento_gerado'
  from (
    select distinct on (o.id) o.id as order_id, o.contact_id, o.number, o.canal, p.valor, p.criado_em, t.ctwa, t.clique_em
      from public.pagamentos p join public.orders o on o.id = p.order_id
      cross join lateral private.meta_ctwa(o.contact_id) t
     where p.eh_link and p.criado_em > now() - interval '7 days' and o.canal <> 'site' and not coalesce(o.teste, false)
       and t.ctwa is not null and t.clique_em > now() - interval '7 days' and not private.meta_eh_teste(o.contact_id)
     order by o.id, p.criado_em) x
on conflict (event_id) do nothing;
