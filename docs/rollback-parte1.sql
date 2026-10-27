-- Rollback manual da migration 20261027000006 (rode só se precisar desfazer; apaga pedidos criados).
-- Restaurar private.is_staff() sem a checagem de e-mail do dono:
create or replace function private.is_staff() returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.profiles where id = (select auth.uid())); $$;
drop view if exists public.order_financials;
drop table if exists public.order_files, public.order_events, public.order_items, public.orders cascade;
drop function if exists private.orders_before_update(), private.orders_after_write();
delete from storage.objects where bucket_id = 'order-files';
delete from storage.buckets where id = 'order-files';
drop table if exists public.app_settings;
alter table public.contacts drop column if exists first_referral, drop column if exists first_referral_at;
alter table public.conversations drop column if exists last_referral;
-- Restaurar ingest_inbound_message: reaplicar a migration 20261027000002.
