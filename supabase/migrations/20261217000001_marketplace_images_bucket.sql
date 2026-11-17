-- Bucket público para as imagens dos anúncios de marketplace (Mercado Livre e Shopee).
-- Só imagens geradas por scripts/gerar-imagens-marketplace.cjs (sem custo, SKU, fornecedor nem contato).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('marketplace-images', 'marketplace-images', true, 5242880, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg'];
