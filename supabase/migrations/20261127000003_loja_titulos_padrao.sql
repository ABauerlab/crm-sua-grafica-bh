-- Títulos padronizados: itens sem ficha da origem (título cru, ex.: "Couche Brilho - Digital - 300g") passam a ter nome de balcão ("Couchê Brilho Digital 300g").
create or replace function private.titulo_vitrine(p_categoria text, p_descricao text)
returns text language sql immutable set search_path = '' as $$
  select btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
    initcap(lower(coalesce(nullif(btrim(
      case when p_categoria is not null and upper(btrim(p_descricao)) like upper(btrim(p_categoria)) || ' -%'
           then substr(btrim(p_descricao), length(btrim(p_categoria)) + 3)
           else p_descricao end), ''), p_categoria))),
    '\s+-\s+', ' ', 'g'), '\mCouche\M', 'Couchê', 'gi'), '\mPvc\M', 'PVC', 'gi'), '\mBopp\M', 'BOPP', 'gi'), '\mLaminacao\M', 'Laminação', 'gi'),
    '\mHolografic([ao])\M', 'Holográfic\1', 'gi'), '\mPlastico\M', 'Plástico', 'gi'), '\mAcrilico\M', 'Acrílico', 'gi'), '\mPapeis\M', 'Papéis', 'gi'));
$$;

update public.ecommerce_products e set titulo = private.titulo_vitrine(c.categoria, c.descricao), atualizado_em = now()
  from public.catalogo c
 where c.sku = e.sku and coalesce(e.ficha ->> 'titulo', '') = '' and e.titulo is distinct from private.titulo_vitrine(c.categoria, c.descricao);
