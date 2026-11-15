-- buscar_produto estourava o statement_timeout (57014) em buscas comuns (13/11/2026, alerta do cliente de teste).
-- Causa: private.categoria_bate normaliza a categoria a cada token e era chamada por linha (milhares de vezes por busca,
-- cerca de 7 s a quente e mais de 18 s sob carga). Agora o casamento é calculado uma vez por categoria distinta.
-- Também remove o link do site da resposta (o site ainda não está pronto para receber clientes pelo WhatsApp).
-- Aditiva e idempotente: reescreve a função só se o texto antigo ainda existir.
do $mig$
declare
  d text;
  novo text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'buscar_produto';
  if d is null then raise exception 'buscar_produto não encontrada'; end if;
  if position('v_cats_ok' in d) > 0 then return; end if;

  novo := d;
  novo := replace(novo, 'v_primeira_cat text;', 'v_primeira_cat text; v_cats_ok text[] := ''{}'';');
  novo := replace(novo, '  v_variantes := array[v_norm];',
    '  v_cats_ok := array(select d2.categoria from (select distinct categoria from public.catalogo where active) d2 where private.categoria_bate(d2.categoria, v_toks));' || chr(10) || '  v_variantes := array[v_norm];');
  novo := replace(novo, 'private.categoria_bate(c.categoria, v_toks)', '(c.categoria = any (v_cats_ok))');
  novo := replace(novo, '''link_produto'', (select ''https://suagraficabh.com.br/produto/'' || e.sku_slug from public.ecommerce_products e where e.sku = r.sku and e.ativo limit 1),' || chr(10) || '      ', '');
  novo := regexp_replace(novo, '-- Busca acabamentos da categoria no [^\n]*', '-- Acabamentos da categoria');

  if position('v_cats_ok text[]' in novo) = 0 or position('categoria_bate(c.categoria' in novo) > 0 then
    raise exception 'patch de buscar_produto não aplicou por completo';
  end if;
  execute novo;
end
$mig$;

-- Segunda parte: private.norm_busca custa ~7 ms por chamada e categoria_bate a repetia por token e por categoria
-- (146 categorias levavam 12 s). Cache da categoria normalizada e uma única normalização por chamada.
create table if not exists private.categoria_norm (categoria text primary key, norm text not null);
revoke all on private.categoria_norm from public, anon, authenticated;

insert into private.categoria_norm (categoria, norm)
select d.categoria, private.norm_busca(d.categoria)
  from (select distinct categoria from public.catalogo where categoria is not null) d
on conflict (categoria) do nothing;

create or replace function private.categoria_bate(p_categoria text, p_toks text[])
returns boolean
language plpgsql volatile security definer set search_path = ''
as $$
declare v_n text; t text; v_alt text;
begin
  if p_categoria is null then return false; end if;
  select cn.norm into v_n from private.categoria_norm cn where cn.categoria = p_categoria;
  if v_n is null then
    v_n := private.norm_busca(p_categoria);
    insert into private.categoria_norm (categoria, norm) values (p_categoria, v_n) on conflict (categoria) do nothing;
  end if;
  foreach t in array coalesce(p_toks, '{}'::text[]) loop
    continue when t in ('fosco', 'brilho', 'digital', 'laser', 'offset', 'frente', 'verso', 'cor', 'cores', 'colorido', 'preto', 'branco', 'personalizado', 'simples', 'duplo', 'express', 'papel', 'fino', 'grosso', 'pesado', 'leve');
    v_alt := case when t ~ 'ao$' then regexp_replace(t, 'ao$', 'oes')
                  when t ~ 'oes$' then regexp_replace(t, 'oes$', 'ao')
                  when t ~ 's$' then regexp_replace(t, 's$', '')
                  else t || 's' end;
    if position(t in v_n) > 0 or position(v_alt in v_n) > 0 then return true; end if;
  end loop;
  return false;
end $$;
