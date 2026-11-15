-- buscar_produto devolvia, para "cartão de visita", Mini Cartão, Cartão Duplo e até Cartão Fidelidade de plástico (R$ 3.289,90).
-- Causa: as categorias elegíveis eram todas as que casam com QUALQUER termo (só "cartão"), e a função espalha 4 opções do mais barato ao mais caro.
-- Correção: ficam só as categorias que casam com o MAIOR número de termos da busca (cartão + visita).
-- Aditiva e idempotente.
create or replace function private.categoria_pontos(p_categoria text, p_toks text[])
returns integer language plpgsql stable security definer set search_path = '' as $$
declare v_n text; t text; v_alt text; pts integer := 0;
begin
  if p_categoria is null then return 0; end if;
  select cn.norm into v_n from private.categoria_norm cn where cn.categoria = p_categoria;
  if v_n is null then v_n := private.norm_busca(p_categoria); end if;
  foreach t in array coalesce(p_toks, '{}'::text[]) loop
    continue when t in ('fosco', 'brilho', 'digital', 'laser', 'offset', 'frente', 'verso', 'cor', 'cores', 'colorido', 'preto', 'branco', 'personalizado', 'simples', 'duplo', 'express', 'papel', 'fino', 'grosso', 'pesado', 'leve');
    v_alt := case when t ~ 'ao$' then regexp_replace(t, 'ao$', 'oes') when t ~ 'oes$' then regexp_replace(t, 'oes$', 'ao') when t ~ 's$' then regexp_replace(t, 's$', '') else t || 's' end;
    if position(t in v_n) > 0 or position(v_alt in v_n) > 0 then pts := pts + 1; end if;
  end loop;
  return pts;
end $$;
revoke all on function private.categoria_pontos(text, text[]) from public, anon, authenticated;

do $mig$
declare d text; novo text; ancora text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'buscar_produto';
  if d is null then raise exception 'buscar_produto não encontrada'; end if;
  if position('categoria_pontos' in d) > 0 then return; end if;
  ancora := 'where private.categoria_bate(d2.categoria, v_toks));';
  if position(ancora in d) = 0 then raise exception 'âncora de buscar_produto não encontrada'; end if;
  novo := replace(d, ancora, ancora || chr(10) || '  if cardinality(v_cats_ok) > 1 then v_cats_ok := array(select c from unnest(v_cats_ok) c where private.categoria_pontos(c, v_toks) = (select max(private.categoria_pontos(c2, v_toks)) from unnest(v_cats_ok) c2)); end if;');
  execute novo;
end
$mig$;

-- Sinônimos de gênero: "fosco" não achava "FOSCA" (18 cartões com laminação fosca contra 6 com papel fosco).
insert into public.sinonimos (grupo, termo)
select g, t from (values ('fosco_fosca','fosco'),('fosco_fosca','fosca'),('brilho_brilhante','brilho'),('brilho_brilhante','brilhante')) v(g,t)
where not exists (select 1 from public.sinonimos s where s.termo = v.t);

-- Material exótico (PVC, plástico, holográfico, hot stamping, kraft, metalizado, madeira, acrílico, imantado) só aparece se o cliente citar.
-- E "A5"/"A6" viram o tamanho do catálogo (150 x 210 e 100 x 150).
-- Relevância dentro da categoria: só entram opções com pontuação de pelo menos 85% da melhor.
do $mig$
declare d text; novo text; a1 text; a2 text; a3 text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'buscar_produto';
  if position('relevancia_categoria' in d) = 0 then
    a1 := '(v_cat_ok and (c.categoria = any (v_cats_ok)))';
    if position(a1 in d) = 0 then raise exception 'âncora de relevância não encontrada'; end if;
    d := replace(d, a1, '(v_cat_ok and (c.categoria = any (v_cats_ok)) and f.score >= 0.85 * (select coalesce(max(f2.score), 0) /* relevancia_categoria */ from _bp_fam f2 join public.catalogo c2 on c2.id = f2.id where c2.quantidade = v_qtd and (c2.categoria = any (v_cats_ok))))');
  end if;
  if position('material_exotico' in d) = 0 then
    a1 := E'where (not v_exact)\n          or (c.quantidade = v_qtd';
    a2 := '(not v_cat_ok and f.score >= v_maxscore * 0.85)))';
    if position(a1 in d) = 0 or position(a2 in d) = 0 then raise exception 'âncoras de material não encontradas'; end if;
    d := replace(d, a1, E'where not exists (select 1 from unnest(array[''pvc'',''plastico'',''holografica'',''hotstamping'',''kraft'',''metalizad'',''madeira'',''acrilico'',''imantad'']) x /* material_exotico */ where position(x in c.especificacao_normalizada) > 0 and position(x in v_norm) = 0)\n      and ((not v_exact)\n          or (c.quantidade = v_qtd');
    d := replace(d, a2, '(not v_cat_ok and f.score >= v_maxscore * 0.85))))');
  end if;
  if position('tamanho_papel_a' in d) = 0 then
    a3 := '  v_variantes := array[v_norm];';
    if position(a3 in d) = 0 then raise exception 'âncora de tamanho não encontrada'; end if;
    d := replace(d, a3, E'  if v_tam is null then v_tam := case when v_norm ~ ''(^| )a5( |$)'' then ''150 x 210'' when v_norm ~ ''(^| )a6( |$)'' then ''100 x 150'' end; /* tamanho_papel_a */ end if;\n  v_norm := btrim(regexp_replace(v_norm, ''(^| )a[56]( |$)'', '' '', ''g''));\n' || a3);
  end if;
  execute d;
end
$mig$;
