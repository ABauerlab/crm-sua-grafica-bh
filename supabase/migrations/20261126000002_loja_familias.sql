-- Hierarquia de navegação: categoria > subcategoria > opção (família) > tamanhos. A família é o título sem o tamanho; o acabamento vira etiqueta.
create table if not exists private.loja_familias (
  sku text primary key, familia text not null, titulo_card text not null, tamanho text not null, tags text[] not null default '{}'
);
create index if not exists loja_familias_familia_idx on private.loja_familias (familia);
alter table private.loja_familias enable row level security;

create or replace view private.loja_familias_v as
select e.sku,
       md5(e.categoria_slug || '|' || private.slugify(t.sem_tam)) familia,
       coalesce(nullif(t2.card, ''), t.sem_tam) titulo_card,
       coalesce(t.dim, t.tamanho_nome, case when x2.c ~* 'metro quadrado' then 'Metro quadrado' end, nullif(e.formato_rotulo, ''), 'Único') tamanho,
       array_remove(array[
         case when 'hot-stamping' = any (a.acab) then 'Hot Stamping' end,
         case when 'relevo' = any (a.acab) then 'Relevo seco' end,
         case when 'uv' = any (a.acab) then 'Verniz UV' end,
         case when 'soft-touch' = any (a.acab) then 'Soft Touch' end,
         case when 'fosca' = any (a.acab) then 'Laminação fosca' end,
         case when 'brilho' = any (a.acab) then 'Laminação brilho' end,
         case when 'holografica' = any (a.acab) then 'Holográfico' end,
         case when e.cores_rotulo is not null and length(e.cores_rotulo) between 3 and 45 then e.cores_rotulo end,
         case when e.prazo_dias_uteis <= 1 then 'Produção 24h' end], null) tags
  from public.ecommerce_products e
  join private.loja_atributos a on a.sku = e.sku
 cross join lateral (select regexp_replace(e.titulo, '^(linha de atacado|promoções|promocoes)\s+', '', 'i') b) x1
 cross join lateral (select regexp_replace(x1.b, '^' || regexp_replace(e.categoria, '([.*+?^${}()|\[\]\\])', '\\\1', 'g') || '\s+', '', 'i') c) x2
 cross join lateral (select
     substring(x2.c from '(?i)(L\s?\d+(?:[.,]\d+)?\s?x\s?P\s?\d+(?:[.,]\d+)?\s?x\s?A\s?\d+(?:[.,]\d+)?|\d+(?:[.,]\d+)?\s?x\s?\d+(?:[.,]\d+)?(?:\s?x\s?\d+(?:[.,]\d+)?)?\s?(?:mm|cm|m)\M)') dim,
     initcap(substring(x2.c from '(?i)\mtamanho\s+(gg|g|m|p|pp|mini|m[eé]dia|grande|pequen[ao]|personalizado)\M')) tamanho_nome,
     btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(x2.c,
       '(?i)\s*(?:L\s?\d+(?:[.,]\d+)?\s?x\s?P\s?\d+(?:[.,]\d+)?\s?x\s?A\s?\d+(?:[.,]\d+)?|\d+(?:[.,]\d+)?\s?x\s?\d+(?:[.,]\d+)?(?:\s?x\s?\d+(?:[.,]\d+)?)?\s?(?:mm|cm|m)\M)', ' ', 'g'),
       '(?i)\s*\mmetro quadrado\M', ' ', 'g'),
       '(?i)\s*\mtamanho\s+(?:gg|g|m|p|pp|mini|m[eé]dia|grande|pequen[ao]|personalizado)\M', ' ', 'g'),
       '(?i)\m(\w+)\s+\1\M', '\1', 'g')) sem_tam) t
 cross join lateral (select btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(t.sem_tam,
     '(?i)\s*lam(?:ina[cç][aã]o)?\.?\s*(?:soft touch|fosca|brilho|hologr[aá]fica)(?:\s*(?:frente e verso|frente|fv|fr|verso))?', '', 'g'),
     '(?i)\s*hot stamping(?:\s*(?:frente e verso|frente|fv|fr|verso))?', '', 'g'),
     '(?i)\s*\m(?:sem lamina[cç][aã]o|sem acabamento extra|uv|sem verniz|verniz(?: brilhante| total| localizado)?(?: na frente| frente| e verso)?)\M', '', 'g'),
     '(?i)\s*brilho especial nos detalhes?o?\s*(?:frente|fr)?', '', 'g'),
     '(?i)(?:\s+(?:e|com|fv|fr))+\s*$', '', 'g')) card) t2;

create or replace function private.loja_atributos_atualizar(p_forcar boolean default false)
returns text language plpgsql security definer set search_path = '' as $$
declare v_ass text; v_old text;
begin
  select count(*)::text || '|' || coalesce(max(atualizado_em)::text, '') || '|' || (select count(*) from public.loja_subcategorias)::text into v_ass from public.ecommerce_products;
  select assinatura into v_old from private.loja_atributos_meta where id;
  if not p_forcar and v_old = v_ass then return 'sem mudanca'; end if;
  delete from private.loja_atributos;
  insert into private.loja_atributos select * from private.loja_atributos_v;
  delete from private.loja_familias;
  insert into private.loja_familias select * from private.loja_familias_v;
  insert into private.loja_atributos_meta (id, assinatura, atualizado_em) values (true, v_ass, now())
    on conflict (id) do update set assinatura = excluded.assinatura, atualizado_em = excluded.atualizado_em;
  return 'atualizado';
end $$;
