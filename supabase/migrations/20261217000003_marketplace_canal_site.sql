-- Canal 'site' na fila de vínculos (loja SUAGRÁFICABH, preço do site). Ver também 20261217000002.
alter table public.marketplace_anuncios drop constraint if exists marketplace_anuncios_canal_check;
alter table public.marketplace_anuncios add constraint marketplace_anuncios_canal_check check (canal in ('mercado_livre', 'shopee', 'site'));
-- A função public.marketplace_preco_sku passou a devolver preco_venda para p_canal = 'site' (ver migration aplicada marketplace_canal_site).
