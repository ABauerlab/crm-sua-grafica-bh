-- Normaliza os SKUs do catálogo (trim e maiúsculas), para que a busca e os vínculos batam sempre.
-- Os SKUs em minúsculas (ex.: ABALk100 -> ABALK100) são trocados em todas as tabelas-base que guardam SKU.
-- As FKs que apontam para catalogo(sku) são soltas antes e recriadas depois, com a mesma definição (inclusive NOT VALID).
-- Antes de qualquer troca, confere que nenhum SKU novo colide com um SKU já existente; se colidir, a migration aborta.
-- Tudo roda numa única transação: qualquer erro desfaz a migration inteira.

begin;

create temp table _sku_norm as
select sku as antigo, upper(btrim(sku)) as novo
from public.catalogo
where sku <> upper(btrim(sku));

do $$
begin
  if exists (
    select 1 from public.catalogo c join _sku_norm m on c.sku = m.novo
  ) or exists (
    select 1 from _sku_norm group by novo having count(*) > 1
  ) then
    raise exception 'normalizacao_skus_colisao: há SKU novo que colide com outro existente';
  end if;
end $$;

-- 1) guarda e solta as FKs que apontam para catalogo(sku)
create temp table _sku_fk as
select c.conrelid::regclass::text as tabela, c.conname, pg_get_constraintdef(c.oid) as definicao
from pg_constraint c
where c.contype = 'f'
  and c.confrelid = 'public.catalogo'::regclass
  and exists (
    select 1 from pg_attribute a
    where a.attrelid = c.confrelid and a.attname = 'sku' and a.attnum = any (c.confkey)
  );

do $$
declare r record;
begin
  for r in select * from _sku_fk loop
    execute format('alter table %s drop constraint %I', r.tabela, r.conname);
  end loop;
end $$;

-- 2) troca o SKU em todas as tabelas-base que guardam SKU (inclui o próprio catálogo)
do $$
declare r record;
begin
  for r in
    select c.table_name, c.column_name
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
    where c.table_schema = 'public'
      and (c.table_name, c.column_name) in (
        ('catalogo', 'sku'),
        ('catalogo_historico', 'sku'),
        ('catalogo_import_linhas', 'sku'),
        ('catalogo_formulas', 'sku'),
        ('produtos_complementares', 'sku_complementar'),
        ('kit_items', 'sku'),
        ('kit_itens', 'sku'),
        ('orcamento_itens', 'sku'),
        ('orcamento_opcoes', 'sku'),
        ('order_items', 'code'),
        ('itens_fora_catalogo', 'sku_resolvido'),
        ('precos_manuais_log', 'sku'),
        ('precos_praticados', 'sku'),
        ('precos_mercado', 'sku'),
        ('consultas_preco_mercado', 'sku'),
        ('anuncios_produtos', 'sku'),
        ('produto_fotos', 'sku'),
        ('produto_fotos_mapa', 'sku')
      )
  loop
    execute format(
      'update public.%I t set %I = m.novo from _sku_norm m where t.%I = m.antigo',
      r.table_name, r.column_name, r.column_name
    );
  end loop;
end $$;

-- 3) recria as FKs exatamente como estavam
do $$
declare r record;
begin
  for r in select * from _sku_fk loop
    execute format('alter table %s add constraint %I %s', r.tabela, r.conname, r.definicao);
  end loop;
end $$;

-- 4) confere que nada ficou para trás
do $$
begin
  if exists (select 1 from public.catalogo where sku <> upper(btrim(sku))) then
    raise exception 'normalizacao_skus_incompleta: ainda há SKU fora do padrão no catálogo';
  end if;
end $$;

drop table if exists _sku_norm;
drop table if exists _sku_fk;

commit;
