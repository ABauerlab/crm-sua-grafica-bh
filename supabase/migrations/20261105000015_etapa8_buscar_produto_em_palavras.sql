-- Etapa 8: cada opção de buscar_produto traz "em_palavras": a ficha traduzida para o cliente (cores frente e verso, medida em cm, espessura).
create or replace function private.traduzir_especificacao(p_cores text, p_gramatura integer, p_tamanho text) returns text
language plpgsql immutable set search_path = ''
as $$
declare v_c text := upper(regexp_replace(coalesce(p_cores, ''), '\s', '', 'g')); v_cores text; v_tam text; v_gram text; v_nums text[]; v_i int; v_n numeric; v_partes text[] := '{}';
begin
  v_cores := case v_c
    when '4X0' then 'colorido só na frente, verso em branco'
    when '4X1' then 'colorido na frente e preto e branco no verso'
    when '4X4' then 'colorido na frente e no verso'
    when '1X0' then 'uma cor (preto) só na frente'
    when '1X1' then 'uma cor na frente e no verso'
    else null end;
  if v_cores is not null then v_partes := array_append(v_partes, v_cores); end if;
  v_nums := regexp_split_to_array(regexp_replace(coalesce(p_tamanho, ''), '[^0-9.,x ]', '', 'g'), '\s*[xX]\s*');
  if array_length(v_nums, 1) >= 2 and v_nums[1] ~ '^[0-9.,]+$' and v_nums[2] ~ '^[0-9.,]+$' then
    v_tam := '';
    for v_i in 1 .. least(array_length(v_nums, 1), 3) loop
      v_n := replace(v_nums[v_i], ',', '.')::numeric / 10;
      v_tam := v_tam || case when v_i > 1 then ' x ' else '' end || replace(trim(trailing '.' from trim(trailing '0' from to_char(v_n, 'FM999990.00'))), '.', ',');
    end loop;
    v_partes := array_append(v_partes, v_tam || ' cm');
  end if;
  if p_gramatura is not null and p_gramatura > 0 then
    v_gram := case when p_gramatura < 120 then 'papel fino' when p_gramatura < 200 then 'papel médio' when p_gramatura < 250 then 'papel firme' else 'papel grosso e firme' end || ' (' || p_gramatura || 'g)';
    v_partes := array_append(v_partes, v_gram);
  end if;
  return array_to_string(v_partes, ', ');
end;
$$;
do $$ declare d text; d2 text; begin
  d := pg_get_functiondef('public.buscar_produto(text,integer,jsonb)'::regprocedure);
  d2 := replace(d, 'c.cores, c.tamanho_mm, c.quantidade, c.prazo_dias_uteis, c.vendavel, f.score', 'c.cores, c.tamanho_mm, c.gramatura_g, c.quantidade, c.prazo_dias_uteis, c.vendavel, f.score');
  d2 := replace(d2, '''quantidade_exata'', v_qtd is not null and r.quantidade = v_qtd));', '''quantidade_exata'', v_qtd is not null and r.quantidade = v_qtd, ''em_palavras'', private.traduzir_especificacao(r.cores, r.gramatura_g, r.tamanho_mm)));');
  if d2 <> d then execute d2; end if;
end $$;
