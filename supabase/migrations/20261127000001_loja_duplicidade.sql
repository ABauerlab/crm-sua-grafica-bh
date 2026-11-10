-- Duplicidade na vitrine: o fornecedor tem SKUs diferentes com a mesma descrição, tamanho e quantidade (variantes que a planilha não descreve, como a base do Wind Banner
-- ou o acabamento). O site juntava tudo em um produto e repetia quantidade e preço.
-- 1) Mesmo produto com títulos (acabamentos) diferentes vira produto separado (sufixo estável no slug).
-- 2) Mesma opção (produto + quantidade) sem diferença descrita: fica só a de menor preço; as outras ficam ocultas e registradas, nunca apagadas.
alter table public.ecommerce_products add column if not exists oculto boolean not null default false;
alter table public.ecommerce_products add column if not exists oculto_motivo text;
create table if not exists public.loja_slug_variantes (sku text primary key, sufixo text not null);
alter table public.loja_slug_variantes enable row level security;
revoke all on public.loja_slug_variantes from anon, authenticated;

create or replace function private.loja_desagrupar_linha() returns trigger language plpgsql set search_path = '' as $$
declare v record; v_resto text; v_suf text;
begin
  if new.categoria_slug in ('linha-de-atacado', 'promocoes') then
    v_resto := regexp_replace(new.titulo, '^(linha de atacado|promoções|promocoes)\s+', '', 'i');
    select d.categoria_slug, d.categoria into v from public.loja_desagrupar d
     where private.loja_norm(v_resto) like d.subcategoria_norm || '%' order by length(d.subcategoria_norm) desc limit 1;
    if found then new.categoria_slug := v.categoria_slug; new.categoria := v.categoria; new.titulo := v_resto; end if;
  end if;
  select s.sufixo into v_suf from public.loja_slug_variantes s where s.sku = new.sku;
  if v_suf is not null and new.produto_slug not like '%' || v_suf then new.produto_slug := new.produto_slug || v_suf; end if;
  if new.oculto then new.ativo := false; end if;
  return new;
end $$;

create or replace function private.loja_dedup() returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_var integer; v_ocultos integer;
begin
  -- 1) produtos cujo slug junta títulos diferentes: cada título vira um produto
  insert into public.loja_slug_variantes (sku, sufixo)
  select e.sku, '-' || left(md5(e.titulo), 6)
    from public.ecommerce_products e
    join (select case when s.sufixo is not null then left(p.produto_slug, length(p.produto_slug) - length(s.sufixo)) else p.produto_slug end base
            from public.ecommerce_products p left join public.loja_slug_variantes s on s.sku = p.sku
           group by 1 having count(distinct p.titulo) > 1) g on true
    left join public.loja_slug_variantes s2 on s2.sku = e.sku
   where (case when s2.sufixo is not null then left(e.produto_slug, length(e.produto_slug) - length(s2.sufixo)) else e.produto_slug end) = g.base
  on conflict (sku) do nothing;
  update public.ecommerce_products e set produto_slug = e.produto_slug || s.sufixo, atualizado_em = now()
    from public.loja_slug_variantes s where s.sku = e.sku and e.produto_slug not like '%' || s.sufixo;
  get diagnostics v_var = row_count;

  -- 2) mesma opção (produto + quantidade): fica a de menor preço; as demais ficam ocultas com o motivo
  with cand as (
    select e.sku, e.produto_slug, e.quantidade, e.preco,
           row_number() over (partition by e.produto_slug, e.quantidade order by e.preco, e.sku) rn,
           first_value(e.sku) over (partition by e.produto_slug, e.quantidade order by e.preco, e.sku) sku_mantido
      from public.ecommerce_products e
     where exists (select 1 from public.catalogo c where c.sku = e.sku and c.active and c.vendavel and c.preco_venda is not null)
  )
  update public.ecommerce_products e set oculto = (c.rn > 1), ativo = (c.rn = 1),
         oculto_motivo = case when c.rn > 1 then 'Variante sem descrição própria: mesma opção (produto e quantidade) que ' || c.sku_mantido else null end,
         atualizado_em = now()
    from cand c where c.sku = e.sku and (e.oculto is distinct from (c.rn > 1) or e.ativo is distinct from (c.rn = 1));
  get diagnostics v_ocultos = row_count;
  return jsonb_build_object('slugs_separados', v_var, 'linhas_alteradas', v_ocultos);
end $$;
revoke all on function private.loja_dedup() from public, anon, authenticated;
