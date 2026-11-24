-- loja_dedup (cron loja-atributos) levava 8 s em média e até 91 s por hora, com statement timeouts e muito Disk IO,
-- porque varre e compara a vitrine inteira mesmo sem nada novo. Agora só roda quando a vitrine mudou desde a última
-- execução (assinatura gravada em app_settings) e o agendamento passa de hora em hora para a cada 6 horas.
-- Mudança de preço, planilha ou sincronização altera ecommerce_products e dispara a próxima rodada. Aditiva e idempotente.
create or replace function private.loja_dedup_se_mudou() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_sig text; v_ant text; v_r jsonb;
begin
  select count(*)::text || '|' || coalesce(max(atualizado_em)::text, '') into v_sig from public.ecommerce_products;
  select value ->> 'sig' into v_ant from public.app_settings where key = 'loja_dedup';
  if v_ant is not distinct from v_sig then return jsonb_build_object('pulou', true); end if;
  v_r := private.loja_dedup();
  select count(*)::text || '|' || coalesce(max(atualizado_em)::text, '') into v_sig from public.ecommerce_products;
  insert into public.app_settings (key, value) values ('loja_dedup', jsonb_build_object('sig', v_sig, 'em', now()))
  on conflict (key) do update set value = excluded.value;
  return v_r;
end $$;
revoke all on function private.loja_dedup_se_mudou() from public, anon, authenticated;
select cron.unschedule('loja-atributos') where exists (select 1 from cron.job where jobname = 'loja-atributos');
select cron.schedule('loja-atributos', '7 */6 * * *', $c$set statement_timeout = '120s'; select private.loja_dedup_se_mudou(); select private.loja_atributos_atualizar()$c$);
