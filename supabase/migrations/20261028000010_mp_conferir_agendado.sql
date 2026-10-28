-- Conferência automática dos pagamentos em aberto no Mercado Pago a cada 10 minutos (rede de segurança para aviso perdido).
-- Usa o mesmo segredo "cron_secret" do Vault e o segredo CRON_SECRET da Edge Function, já criados para a sincronização da Meta.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'mp-conferir-pendentes') then
    perform cron.unschedule('mp-conferir-pendentes');
  end if;
  perform cron.schedule(
    'mp-conferir-pendentes',
    '*/10 * * * *',
    $job$
      select net.http_post(
        url := 'https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/mp-conferir',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)
        ),
        body := '{}'::jsonb
      );
    $job$
  );
end $$;
