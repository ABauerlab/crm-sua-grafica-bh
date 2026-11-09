-- E-commerce Fase 9: envio nacional pelos Correios (SuperFrete) vira um método de entrega do pedido. Aditiva e idempotente.
alter table public.orders drop constraint if exists orders_delivery_method_check;
alter table public.orders add constraint orders_delivery_method_check check (delivery_method = any (array['retirada'::text, 'uber'::text, 'correios'::text]));
