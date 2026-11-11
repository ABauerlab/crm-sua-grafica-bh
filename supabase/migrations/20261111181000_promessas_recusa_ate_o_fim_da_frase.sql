-- Continuacao da migration anterior: a frase de recusa ("nao consigo aplicar 20% de desconto porque ...") pode ser longa.
-- Em vez de limitar a 90 caracteres, a recusa vale ate o fim da frase.

do $$
declare
  v_def text;
  v_novo text;
begin
  select pg_get_functiondef('public.agente_promessas_indevidas_execucao(uuid,text)'::regprocedure) into v_def;
  v_novo := replace(v_def, '[^.!?]{0,90}[.!?]', '[^.!?]*[.!?]');
  if v_novo = v_def then
    raise exception 'trecho nao encontrado; nada alterado';
  end if;
  execute v_novo;
end
$$;
