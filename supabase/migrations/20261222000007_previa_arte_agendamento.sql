-- Fase 2: agendamento do worker de prévia de arte. A cada minuto, só chama a função enquanto houver pendente
-- (pendente, aguardando_limite já vencido, ou processando travado) e não expirado, mesmo segredo cron_secret das outras rotinas.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'previa-arte-processar') then perform cron.unschedule('previa-arte-processar'); end if;
  perform cron.schedule('previa-arte-processar', '* * * * *', $job$
    select net.http_post(
      url := 'https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/previa-arte-processar',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)),
      body := '{}'::jsonb, timeout_milliseconds := 110000)
    where exists (
      select 1 from public.previas_arte
       where expira_em > now()
         and (status = 'pendente'
              or (status = 'aguardando_limite' and atualizado_em <= now() - interval '5 minutes')
              or (status = 'processando' and processando_desde <= now() - interval '10 minutes'))
    );
  $job$);
end $$;
