-- 1) Identificador da NF preenchido sozinho a partir do Bling: bling-integracao (acao conferir_nf) lê a nota do pedido
--    (NFC-e ou NF-e), e nf_registrar_bling grava número, tipo, situação e chave. Roda a cada 10 min.
--    O Bling é a fonte da verdade: nota rejeitada ou cancelada volta o pedido para "NF pendente".
-- 2) Sincronização dos anúncios da Meta a cada 15 min (últimos 3 dias); o job diário de 7 dias continua.
-- Aditiva e idempotente.
alter table public.orders add column if not exists nf_tipo text;
alter table public.orders add column if not exists nf_situacao text;
alter table public.orders add column if not exists nf_chave text;
alter table public.orders add column if not exists nf_conferido_em timestamptz;

create or replace function public.nf_pendentes_bling(p_limite integer default 12, p_order uuid default null)
returns table (order_id uuid, bling_pedido_id text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return query
    select o.id, o.bling_pedido_id::text
      from public.orders o
     where o.payment_status = 'aprovado' and o.bling_pedido_id is not null and o.excluido_em is null and coalesce(o.teste, false) = false
       and (p_order is null or o.id = p_order)
       and (p_order is not null or not o.nf_emitida or o.nf_situacao in ('Rejeitada', 'Denegada', 'Cancelada'))
     order by o.nf_conferido_em nulls first, o.paid_at
     limit p_limite;
end $$;

create or replace function public.nf_registrar_bling(p_order uuid, p_numero text, p_tipo text, p_situacao integer, p_rotulo text, p_emitida boolean, p_chave text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_numero is null then
    update public.orders set nf_conferido_em = now() where id = p_order;
    return;
  end if;
  update public.orders
     set nf_identificador = p_numero, nf_tipo = p_tipo, nf_situacao = p_rotulo, nf_chave = p_chave, nf_conferido_em = now(),
         nf_emitida = coalesce(p_emitida, false),
         nf_emitida_em = case when coalesce(p_emitida, false) then coalesce(nf_emitida_em, now()) else null end
   where id = p_order;
end $$;

revoke all on function public.nf_pendentes_bling(integer, uuid) from public, anon;
revoke all on function public.nf_registrar_bling(uuid, text, text, integer, text, boolean, text) from public, anon;
grant execute on function public.nf_pendentes_bling(integer, uuid) to authenticated, service_role;
grant execute on function public.nf_registrar_bling(uuid, text, text, integer, text, boolean, text) to authenticated, service_role;

-- Marcador "faltam dados da NF" some quando a nota já está emitida (NFC-e não exige CPF nem endereço)
create or replace function public.nf_faltantes(o public.orders)
returns text[] language sql stable set search_path = '' as $$
  select case when (o.payment_status = 'aprovado' or o.payment_manual) and not o.nf_emitida and o.cancelado_em is null and o.excluido_em is null and coalesce(o.teste, false) = false
              then coalesce((select public.contato_nf_faltantes(c) from public.contacts c where c.id = o.contact_id), '{}'::text[])
              else '{}'::text[] end;
$$;

create extension if not exists pg_net with schema extensions;
do $$
begin
  if exists (select 1 from cron.job where jobname = 'bling-nf-conferir') then perform cron.unschedule('bling-nf-conferir'); end if;
  perform cron.schedule('bling-nf-conferir', '*/10 * * * *', $job$
    select net.http_post(
      url := 'https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/bling-integracao',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)),
      body := '{"acao": "conferir_nf"}'::jsonb);
  $job$);
  if exists (select 1 from cron.job where jobname = 'meta-ads-sync-15min') then perform cron.unschedule('meta-ads-sync-15min'); end if;
  perform cron.schedule('meta-ads-sync-15min', '*/15 * * * *', $job$
    select net.http_post(
      url := 'https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/meta-ads-sync',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)),
      body := '{"days": 3}'::jsonb);
  $job$);
end $$;
