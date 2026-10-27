-- Sincronização diária dos anúncios da Meta (06h30 de Brasília = 09h30 UTC).
-- Pré-requisito: segredo "cron_secret" no Vault com o mesmo valor do segredo CRON_SECRET da Edge Function meta-ads-sync.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'meta-ads-sync-diario') then
    perform cron.unschedule('meta-ads-sync-diario');
  end if;
  perform cron.schedule(
    'meta-ads-sync-diario',
    '30 9 * * *',
    $job$
      select net.http_post(
        url := 'https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/meta-ads-sync',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)
        ),
        body := '{"days": 7}'::jsonb
      );
    $job$
  );
end $$;
