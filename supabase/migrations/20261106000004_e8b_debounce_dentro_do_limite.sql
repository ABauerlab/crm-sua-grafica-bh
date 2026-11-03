-- Etapa 8B (achado do teste ponta a ponta): agente_debounce dormia até 20 s quando a última mensagem parece incompleta,
-- mas o PostgREST corta qualquer chamada em 8 s (statement_timeout do papel). Resultado: erro 57014, o WF1 falhava e o cliente
-- ficava sem resposta. A espera extra agora cabe no limite (no máximo 5 s, somados aos 6 s do debounce do n8n).
do $$ declare d text; d2 text; begin
  d := pg_get_functiondef('public.agente_debounce(uuid,boolean)'::regprocedure);
  d2 := replace(d, 'v_extra := least(20, greatest(0, 60 - extract', 'v_extra := least(5, greatest(0, 60 - extract');
  if d2 <> d then execute d2; end if;
end $$;
