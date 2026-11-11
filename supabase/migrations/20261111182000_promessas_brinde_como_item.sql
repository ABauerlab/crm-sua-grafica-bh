-- A trava barrava "adesivos pra produtos ou brindes" (um item do catalogo) como se fosse promessa de brinde gratis,
-- porque a regra casava a palavra "brinde" solta. Agora so casa "de brinde" (ex.: "te dou um adesivo de brinde").

do $$
declare
  v_def text;
  v_novo text;
begin
  select pg_get_functiondef('public.agente_promessas_indevidas_execucao(uuid,text)'::regprocedure) into v_def;
  v_novo := replace(v_def, '|brinde|ganha', '|de\s+brinde|ganha');
  if v_novo = v_def then
    raise exception 'trecho nao encontrado; nada alterado';
  end if;
  execute v_novo;
end
$$;
