-- A trava de saída bloqueava resposta correta (ex.: cliente Felipe, 17/11) quando o texto citava um valor que a ferramenta
-- confirmou em rodada anterior da mesma conversa. Agora valem também os valores vistos nas últimas 12 h da conversa.
-- Aditiva e idempotente.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'agente_saida_base_execucao';
  if position('/* valores_da_conversa */' in v_def) = 0 then
    if position($q$  v := regexp_replace(v, '\s*[—–]\s*', ', ', 'g');$q$ in v_def) = 0 then raise exception 'trecho nao encontrado'; end if;
    v_new := replace(v_def, $q$  v := regexp_replace(v, '\s*[—–]\s*', ', ', 'g');$q$,
      $q$  -- Valores que as ferramentas já confirmaram antes nesta mesma conversa (últimas 12 h) também valem: um resumo do que já foi cotado não pode ser bloqueado.
  select v_ctx || coalesce(array_agg(distinct y), '{}') into v_ctx /* valores_da_conversa */
    from (select unnest(e2.valores_vistos) as y from public.agente_execucoes e2
           where e2.conversation_id = ex.conversation_id and e2.id <> ex.id and e2.iniciado_em > now() - interval '12 hours' and e2.valores_vistos is not null) z
   where y is not null and y > 0;

  v := regexp_replace(v, '\s*[—–]\s*', ', ', 'g');$q$);
    execute v_new;
  end if;
end $mig$;
