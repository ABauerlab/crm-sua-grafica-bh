-- 22/11/2026: a indexação do banco de conhecimento rodava a cada 6 horas (documentação dizia 5 min).
-- Ficha editada ficava até 6 h sem vetor. Passa para a cada 5 minutos: a função só processa trechos sem vetor.
do $m$
begin
  if exists (select 1 from cron.job where jobname = 'conhecimento-reindexar') then
    perform cron.alter_job((select jobid from cron.job where jobname = 'conhecimento-reindexar'), schedule := '*/5 * * * *');
  end if;
end $m$;
