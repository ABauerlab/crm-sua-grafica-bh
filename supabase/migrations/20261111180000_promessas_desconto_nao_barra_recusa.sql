-- A trava de saida barrava a resposta da Laura quando ela RECUSAVA um desconto pedido pelo cliente
-- ("nao consigo aplicar 20% de desconto"), porque a regra casa "N% de desconto" em qualquer contexto.
-- Resultado em producao: boa resposta trocada por "Deixa eu confirmar isso..." e alerta ao dono.
-- Agora as frases de recusa sao ignoradas antes de procurar a promessa de desconto.

do $$
declare
  v_def text;
  v_novo text;
begin
  select pg_get_functiondef('public.agente_promessas_indevidas_execucao(uuid,text)'::regprocedure) into v_def;
  v_novo := replace(
    v_def,
    'if t ~ ''(\d+\s*%',
    'if regexp_replace(t, ''(não|nao)\s+(consigo|posso|dá|da|temos|faço|faco|fazemos|há|ha|tem|vou)[^.!?]{0,90}[.!?]'', '' '', ''g'') ~ ''(\d+\s*%'
  );
  if v_novo = v_def then
    raise exception 'trecho do desconto nao encontrado; nada alterado';
  end if;
  execute v_novo;
end
$$;
