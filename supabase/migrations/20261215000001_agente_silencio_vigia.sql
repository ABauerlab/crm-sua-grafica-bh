-- Vigia de silencio da Laura (15/11/2026).
-- Investigacao: nao havia rede de seguranca para lead sem resposta. A funcao agente_watchdog_reconciliar da migration
-- 20261110000001 nunca existiu em producao e, se existisse, marcaria como erro rodadas com mais de 60 s (a P95 real e 128 s).
-- Esta funcao so OBSERVA: cria um alerta ao dono (tipo agente_falhou, gravidade alta) quando uma conversa em modo IA
-- tem mensagem do cliente sem resposta ha mais de 150 s, sem rodada ativa nos ultimos 5 min e fora de teste.
-- Aditiva e idempotente (uma chave de alerta por mensagem).
create or replace function private.agente_silencio_vigiar()
returns integer
language plpgsql
security definer
set search_path = ''
as $f$
declare r record; n integer := 0;
begin
  for r in
    select c.id as conversation_id, c.contact_id, m.id as msg_id
      from public.conversations c
      join lateral (
        select m1.id, m1.created_at from public.messages m1
         where m1.conversation_id = c.id and m1.direction = 'in' and m1.deleted_at is null
         order by m1.created_at desc limit 1
      ) m on true
     where c.modo_atendimento = 'ia'
       and coalesce(c.ai_handled, true)
       and m.created_at between now() - interval '12 hours' and now() - interval '150 seconds'
       and not exists (select 1 from public.messages o where o.conversation_id = c.id and o.direction = 'out' and o.created_at >= m.created_at)
       and not exists (select 1 from public.agente_execucoes e where e.conversation_id = c.id and (e.status = 'rodando' and e.iniciado_em > now() - interval '5 minutes' or e.teste))
  loop
    perform public.alerta_criar('agente_falhou', 'alta', r.contact_id, r.conversation_id, null,
      'A Laura nao respondeu um cliente em mais de 2 minutos e meio. Abra a conversa e responda ou devolva para a IA.',
      jsonb_build_object('mensagem_id', r.msg_id, 'origem', 'vigia_silencio'), 'silencio:' || r.msg_id, null);
    n := n + 1;
  end loop;
  return n;
end $f$;
revoke all on function private.agente_silencio_vigiar() from public, anon, authenticated;

do $c$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and not exists (select 1 from cron.job where jobname = 'agente-silencio-vigia') then
    perform cron.schedule('agente-silencio-vigia', '* * * * *', 'select private.agente_silencio_vigiar()');
  end if;
end $c$;
