-- Correção da Fase 2: o agendamento parava quando acabavam as fichas pendentes e deixava para trás as fotos grandes
-- (que só são recomprimidas 2 por execução). Agora ele continua enquanto houver foto pendente.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'loja-fichas') then perform cron.unschedule('loja-fichas'); end if;
  perform cron.schedule('loja-fichas', '* * * * *', $job$
    select net.http_post(
      url := 'https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/loja-fichas',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)),
      body := '{}'::jsonb, timeout_milliseconds := 5000)
    where exists (select 1 from public.loja_fichas where status in ('pendente', 'erro') and tentativas < 3)
       or exists (select 1 from public.loja_fichas where status = 'ok' and foto_path is null and imagem_origem is not null and foto_tentativas < 2);
  $job$);
end $$;
