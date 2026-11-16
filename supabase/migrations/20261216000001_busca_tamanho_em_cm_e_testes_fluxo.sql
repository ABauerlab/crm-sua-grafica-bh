-- 16/11/2026: "adesivo redondo 5cm" trazia um adesivo de R$ 1.137,90 porque a busca não entendia centímetros.
-- buscar_produto agora converte "N cm" no menor tamanho de catálogo (de preferência quadrado) que comporta N cm, só dentro das categorias
-- que casam com a busca, e ignora medidas do tipo 100x70. Aditiva e idempotente (já aplicada em produção).
do $mig$
declare d text; a text := '/* tamanho_papel_a */ end if;';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'buscar_produto';
  if position('tamanho_em_cm' in d) = 0 then
    if position(a in d) = 0 then raise exception 'âncora de tamanho não encontrada'; end if;
    d := replace(d, a, a || E'\n  if v_tam is null and v_norm ~ ''(^| )[0-9]+([.,][0-9]+)? ?cm( |$)'' and v_norm !~ ''[0-9] ?x ?[0-9]'' then /* tamanho_em_cm */\n    select c.tamanho_mm into v_tam from public.catalogo c\n     where c.active and c.vendavel and c.preco_venda is not null and (c.categoria = any (v_cats_ok)) and c.tamanho_mm ~ ''^[0-9]+ x [0-9]+$''\n       and split_part(c.tamanho_mm, '' x '', 1)::int >= round(replace((regexp_match(v_norm, ''([0-9]+([.,][0-9]+)?) ?cm''))[1], '','', ''.'')::numeric * 10)\n       and split_part(c.tamanho_mm, '' x '', 2)::int >= round(replace((regexp_match(v_norm, ''([0-9]+([.,][0-9]+)?) ?cm''))[1], '','', ''.'')::numeric * 10)\n     order by abs(split_part(c.tamanho_mm, '' x '', 1)::int - split_part(c.tamanho_mm, '' x '', 2)::int), split_part(c.tamanho_mm, '' x '', 1)::int limit 1;\n    v_norm := btrim(regexp_replace(v_norm, ''(^| )[0-9]+([.,][0-9]+)? ?cm( |$)'', '' '', ''g''));\n  end if;');
    execute d;
  end if;
end
$mig$;

-- Cenários novos: envio para fora de BH (SuperFrete) e aprovação com nota fiscal.
insert into public.testes_conversa (nome, descricao, entradas, esperado, ativo)
select 'e13-envio-ubatuba', 'Cliente de fora de BH: cotar envio pelos Correios e confirmar CEP',
       '{"nome":"Kodara","mensagens":[{"texto":"Oi! Quero 500 cartões de visita 4x4, já tenho a arte pronta. Vocês enviam para Ubatuba SP? O CEP é 11680-000"}]}'::jsonb,
       '{"texto_nao_contem":["não enviamos","não fazemos envio","Uber"],"texto_contem_algum":["Correios","PAC","SEDEX","Ubatuba"],"ferramentas_obrigatorias":["verificar_frete"],"max_chars_mensagem":420}'::jsonb, true
where not exists (select 1 from public.testes_conversa where nome = 'e13-envio-ubatuba');
insert into public.testes_conversa (nome, descricao, entradas, esperado, ativo)
select 'e14-aprovado-gera-link', 'Orçamento aberto, cliente aprova e pede nota fiscal: a Laura confirma os dados da nota antes do link',
       '{"nome":"Marcos","preparar":["orcamento_aberto"],"mensagens":[{"texto":"APROVADO. Pode mandar o Pix. Quero nota fiscal no CNPJ 12.345.678/0001-95."}]}'::jsonb,
       '{"ferramentas_obrigatorias":["gerar_pdf_orcamento"],"texto_nao_contem":["assistente virtual"],"max_chars_mensagem":420}'::jsonb, true
where not exists (select 1 from public.testes_conversa where nome = 'e14-aprovado-gera-link');
