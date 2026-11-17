-- O extrato e o saldo automáticos do Mercado Pago saíram da tela de Financeiro (saldo agora é manual).
-- Pausa o agendamento mp-extrato-sync (a cada 5 min). Reversível: cron.alter_job(job_id, active := true).
-- A função mp-extrato, mp-saldo e as tabelas mp_movimentos e mp_saldo_historico ficam intactas como histórico.
-- Idempotente.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'mp-extrato-sync') then
    perform cron.alter_job(job_id := (select jobid from cron.job where jobname = 'mp-extrato-sync'), active := false);
  end if;
end $$;
