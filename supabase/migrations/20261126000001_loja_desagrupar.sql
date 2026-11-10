-- Um item por categoria: itens das categorias agregadoras do fornecedor (Linha de Atacado, Promoções) vão para a categoria natural.
create table if not exists public.loja_desagrupar (subcategoria_norm text primary key, categoria_slug text not null, categoria text not null);
alter table public.loja_desagrupar enable row level security;
revoke all on public.loja_desagrupar from anon, authenticated;

insert into public.loja_desagrupar (subcategoria_norm, categoria_slug, categoria)
select m.nome_norm, m.categoria_slug, m.categoria from (
  select a.nome_norm, c.categoria_slug, c.categoria, row_number() over (partition by a.nome_norm order by similarity(a.nome_norm, c.cn) desc) rn
    from public.loja_subcategorias a
    join (select distinct categoria_slug, categoria, private.loja_norm(categoria) cn from public.ecommerce_products
           where categoria_slug not in ('linha-de-atacado', 'promocoes')) c on similarity(a.nome_norm, c.cn) > 0.35
   where a.categoria_slug in ('linha-de-atacado', 'promocoes')) m
 where m.rn = 1
on conflict (subcategoria_norm) do nothing;

create or replace function private.loja_desagrupar_linha() returns trigger language plpgsql set search_path = '' as $$
declare v record; v_resto text;
begin
  if new.categoria_slug in ('linha-de-atacado', 'promocoes') then
    v_resto := regexp_replace(new.titulo, '^(linha de atacado|promoções|promocoes)\s+', '', 'i');
    select d.categoria_slug, d.categoria into v from public.loja_desagrupar d
     where private.loja_norm(v_resto) like d.subcategoria_norm || '%' order by length(d.subcategoria_norm) desc limit 1;
    if found then new.categoria_slug := v.categoria_slug; new.categoria := v.categoria; new.titulo := v_resto; end if;
  end if;
  return new;
end $$;
create or replace trigger zz_loja_desagrupar before insert or update on public.ecommerce_products for each row execute function private.loja_desagrupar_linha();

update public.ecommerce_products set atualizado_em = now() where categoria_slug in ('linha-de-atacado', 'promocoes');
