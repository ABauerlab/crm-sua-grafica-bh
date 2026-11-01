-- Etapa 8: a ficha traduzida chamava de "papel" o adesivo BOPP, PVC, vinil etc. A espessura em gramas só aparece quando o item é papel/cartão;
-- para plásticos e adesivos a ficha diz o material em palavras simples.
create or replace function private.traduzir_especificacao(p_cores text, p_gramatura integer, p_tamanho text, p_material text)
returns text language plpgsql immutable set search_path = ''
as $$
declare v_base text := private.traduzir_especificacao(p_cores, null, p_tamanho); v_m text := upper(coalesce(p_material, '')); v_gram text; v_mat text;
begin
  if v_m ~ 'BOPP|PVC|VINIL|PET|PLASTIC|ACETATO|POLIETILENO|ADESIV|ETIQUETA|LONA|BANNER|TECIDO|ACRILIC' then
    v_mat := case
      when v_m ~ 'PVC' then 'material em PVC (plástico resistente à água)'
      when v_m ~ 'BOPP' and v_m ~ 'TRANSPARENTE' then 'adesivo BOPP transparente (plástico resistente à água)'
      when v_m ~ 'BOPP' then 'adesivo BOPP (plástico resistente à água)'
      when v_m ~ 'VINIL' then 'adesivo de vinil (resistente à água)'
      when v_m ~ 'LONA' then 'lona'
      when v_m ~ 'ADESIV' then 'adesivo em papel'
      else null end;
    return concat_ws(', ', v_mat, nullif(v_base, ''));
  end if;
  if p_gramatura is not null and p_gramatura > 0 then
    v_gram := case when p_gramatura < 120 then 'papel fino' when p_gramatura < 200 then 'papel médio' when p_gramatura < 250 then 'papel firme' else 'papel grosso e firme' end || ' (' || p_gramatura || 'g)';
  end if;
  return concat_ws(', ', nullif(v_base, ''), v_gram);
end;
$$;
do $$ declare d text; d2 text; begin
  d := pg_get_functiondef('public.buscar_produto(text,integer,jsonb)'::regprocedure);
  d2 := replace(d, 'private.traduzir_especificacao(r.cores, r.gramatura_g, r.tamanho_mm)', 'private.traduzir_especificacao(r.cores, r.gramatura_g, r.tamanho_mm, concat_ws('' '', r.categoria, r.descricao))');
  if d2 <> d then execute d2; end if;
end $$;
