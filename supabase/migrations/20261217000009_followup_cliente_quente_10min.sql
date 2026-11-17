-- Cliente quente (pedido do dono, 17/11/2026): 10 minutos sem resposta já é motivo de retomar a conversa.
-- Q1 (conversa parada antes do orçamento) e F1 (depois do orçamento) passam de 40 min / 2 h para 10 min; o WF6 roda a cada 3 min.
-- O lembrete Q também deixa de depender de needs_human (a Laura segue atendendo no modo IA; só o modo humano pausa).
update public.followup_regras set atraso_minutos = 10, descricao = 'Cliente quente: lembrete 10 minutos depois da última mensagem da Laura sem resposta (mensagem livre)' where codigo = 'Q1';
update public.followup_regras set atraso_minutos = 10, descricao = 'Cliente quente: 10 minutos depois do orçamento sem resposta (mensagem livre, sem desconto)' where codigo = 'F1';
do $mig$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'followup_agendar';
  if position('/* q_quente */' in v_def) = 0 then
    execute replace(v_def, ' and coalesce(cv.ai_handled, true) and not coalesce(cv.needs_human, false)', ' and coalesce(cv.ai_handled, true) /* q_quente */');
  end if;
end $mig$;
