-- Rollback manual da migration 20261028000001 (apaga dados das tabelas novas).
drop function if exists public.ad_performance(date, date);
drop view if exists public.products_priced, public.contact_stats;
drop table if exists public.agent_logs, public.ad_manual_spend, public.ad_daily, public.ad_entities,
  public.kit_items, public.kits, public.products, public.tasks, public.quick_replies, public.conversation_notes cascade;
alter table public.conversations
  drop column if exists attendant_changed_at, drop column if exists attendant_change_reason, drop column if exists needs_human,
  drop column if exists summary, drop column if exists collected_data, drop column if exists labels, drop column if exists ad_window_until;
alter table public.contacts
  drop column if exists email, drop column if exists document, drop column if exists company, drop column if exists segment, drop column if exists address;
delete from public.app_settings where key in ('agent', 'company', 'labels', 'campaign_goals', 'repurchase');
-- Restaurar ingest_inbound_message: reaplicar a versão da migration 20261027000006.
