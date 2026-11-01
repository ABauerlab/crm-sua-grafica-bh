-- Etapa 8: a trava de saída bloqueava QUALQUER "custo"/"custos" (ex.: "o custo da arte"), derrubando a resposta final do agente
-- (o cliente recebia "deixa eu confirmar" repetido). Agora só bloqueia custo interno: "nosso/meu custo", "preço de custo",
-- "custo de produção/fabricação/interno/real" e "custo do fornecedor". Margem, piso, fornecedor, SKU e demais regras seguem iguais.
do $$ declare d text; d2 text; begin
 d := pg_get_functiondef('public.agente_saida_base(uuid,text)'::regprocedure);
 d2 := replace(d, $o$array['custo', '\mcustos?\M(?![- ]?benef)']$o$, $n$array['custo', '(\m(nosso|nossa|nossos|meu|minha)\s+custos?\M|\mpre[cç]o\s+de\s+custo\M|\mcustos?\s+(de\s+)?(produ[cç][aã]o|fabrica[cç][aã]o|interno|internos|real|reais)\M|\mcustos?\s+do\s+fornecedor\M)']$n$);
 if d2 <> d then execute d2; end if;
end $$;
