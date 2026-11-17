-- Famílias de anúncio para o lote dos marketplaces: um produto pai por especificação, uma variação por quantidade.
-- Chave da família: categoria + descrição + cores + formato + ficha (tamanho final, acabamento, material, espessura).
-- Em quantidade repetida vale o SKU de menor preço de venda. Aditiva e idempotente; só service role.
create table if not exists public.marketplace_familias (
  id uuid primary key default gen_random_uuid(),
  chave text not null unique,
  codigo_pai text not null unique,
  categoria text,
  descricao text,
  cores text,
  formato text,
  ficha jsonb,
  variacoes jsonb not null,            -- [{sku, quantidade, preco_site, peso_kg, embalagem_cm, prazo_dias, ncm, foto}]
  status text not null default 'rascunho' check (status in ('rascunho', 'imagens_ok', 'publicando', 'publicada', 'erro')),
  imagens jsonb,
  bling_pai_id bigint,
  erro text,
  atualizado_em timestamptz not null default now()
);
alter table public.marketplace_familias enable row level security;
revoke all on public.marketplace_familias from anon, authenticated;

create or replace function public.marketplace_familias_gerar(p_skus text[])
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  with k as (
    select c.sku, c.categoria, c.descricao, c.cores, c.quantidade, c.preco_venda, c.peso_frete_kg, c.embalagem_cm, c.prazo_cliente_dias, c.ncm,
           e.formato_rotulo, e.ficha, e.fotos,
           md5(coalesce(c.categoria,'')||'|'||coalesce(c.descricao,'')||'|'||coalesce(c.cores,'')||'|'||coalesce(e.formato_rotulo,'')||'|'||coalesce(e.ficha->>'tamanho_final','')||'|'||coalesce(e.ficha->>'acabamento','')||'|'||coalesce(e.ficha->>'material','')||'|'||coalesce(e.ficha->>'espessura','')) chave
      from public.catalogo c left join public.ecommerce_products e on e.sku = c.sku
     where c.active is not false and c.custo is not null and c.peso_frete_kg is not null and c.embalagem_cm is not null
  ), alvo as (select distinct chave from k where sku = any (p_skus)),
  uniq as (
    select distinct on (k.chave, k.quantidade) k.* from k join alvo using (chave) order by k.chave, k.quantidade, k.preco_venda, k.sku
  ), fam as (
    select chave, (array_agg(sku order by quantidade))[1] as sku_base,
           max(categoria) categoria, max(descricao) descricao, max(cores) cores, max(formato_rotulo) formato, (array_agg(ficha))[1] ficha,
           jsonb_agg(jsonb_build_object('sku', sku, 'quantidade', quantidade, 'preco_site', preco_venda, 'peso_kg', peso_frete_kg, 'embalagem_cm', embalagem_cm,
                     'prazo_dias', prazo_cliente_dias, 'ncm', ncm, 'foto', (to_jsonb(fotos) -> 0)) order by quantidade) variacoes
      from uniq group by chave
  )
  insert into public.marketplace_familias (chave, codigo_pai, categoria, descricao, cores, formato, ficha, variacoes)
  select chave, 'SGBH-' || sku_base, categoria, descricao, cores, formato, ficha, variacoes from fam
  on conflict (chave) do update set variacoes = excluded.variacoes, ficha = excluded.ficha, atualizado_em = now()
  where public.marketplace_familias.status in ('rascunho', 'imagens_ok', 'erro');
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.marketplace_familias_gerar(text[]) from public, anon, authenticated;
grant execute on function public.marketplace_familias_gerar(text[]) to service_role;
