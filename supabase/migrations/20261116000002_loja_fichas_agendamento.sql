-- E-commerce Fase 2: liga o processamento das fichas (20 produtos por minuto, uma página a cada 2 s).
-- Verificação de marca desligada como nas fotos do WhatsApp (decisão do dono: as fotos da origem não têm logo); marca_ok fica nulo.
update public.app_settings
   set value = value || jsonb_build_object('por_execucao', 20, 'verificar_marca', false)
 where key = 'loja_fichas';

-- Agendamento: a cada minuto, só faz algo enquanto houver pendente (mesmo segredo cron_secret das outras rotinas).
do $$
begin
  if exists (select 1 from cron.job where jobname = 'loja-fichas') then perform cron.unschedule('loja-fichas'); end if;
  perform cron.schedule('loja-fichas', '* * * * *', $job$
    select net.http_post(
      url := 'https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/loja-fichas',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)),
      body := '{}'::jsonb, timeout_milliseconds := 5000)
    where exists (select 1 from public.loja_fichas where status in ('pendente', 'erro') and tentativas < 3);
  $job$);
end $$;
