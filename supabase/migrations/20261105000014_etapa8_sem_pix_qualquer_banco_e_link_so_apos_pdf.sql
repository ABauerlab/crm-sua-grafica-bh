-- Etapa 8 (decisão do dono): tirar "Pix de qualquer banco" de todos os textos; link de pagamento do agente só depois do PDF formal enviado.
create or replace function pg_temp.limpa(t text) returns text language sql as $$
  select regexp_replace(regexp_replace(regexp_replace(t, ' O Pix vale de qualquer banco\.', '', 'g'), ' e vale de qualquer banco', '', 'g'), ' de qualquer banco', '', 'g')
$$;
update public.conhecimento set resposta_pronta = pg_temp.limpa(resposta_pronta), quando_usar = pg_temp.limpa(quando_usar)
 where resposta_pronta ilike '%qualquer banco%' or quando_usar ilike '%qualquer banco%';
update public.faq_cache set resposta = pg_temp.limpa(resposta) where resposta ilike '%qualquer banco%';
do $$ declare d text; d2 text; begin
  d := pg_get_functiondef('public.followup_montar(uuid,timestamptz)'::regprocedure);
  d2 := replace(d, ' O Pix pode ser pago de qualquer banco.', '');
  if d2 <> d then execute d2; end if;
  d := pg_get_functiondef('public.preparar_link_pagamento(uuid)'::regprocedure);
  d2 := replace(d, 'Pode pagar por Pix (de qualquer banco) ou cartão pelo link. O valor já está certinho.', 'Pode pagar por Pix ou cartão pelo link. O valor já está certinho.');
  d2 := replace(d2, E'  v_val := public.validar_margem(p_orcamento);',
    E'  if o.pdf_enviado_em is null then\n    return jsonb_build_object(''ok'', false, ''motivo'', ''pdf_formal_nao_enviado'', ''alternativa'', ''Envie o PDF formal do orçamento e peça a aprovação do cliente antes do link.'');\n  end if;\n  v_val := public.validar_margem(p_orcamento);');
  if d2 <> d then execute d2; end if;
end $$;
