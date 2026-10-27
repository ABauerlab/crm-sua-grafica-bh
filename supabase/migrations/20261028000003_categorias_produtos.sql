-- Categorias distintas do catálogo (o catálogo do fornecedor tem mais de 20 mil itens e 140 categorias).
create or replace view public.product_categories with (security_invoker = true) as
select category, count(*) as products
from public.products
where active and category is not null
group by category;
