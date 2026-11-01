-- Etapa 8: categorias do catálogo estão no plural ("CARTÕES DE VISITA") e o cliente escreve no singular.
-- O termo solto "cartao" expandia "cartao de visita" para "cartao" e trazia caixa de cartão e mini cartão: removido. Plurais entram como sinônimos.
delete from public.sinonimos where grupo = 'cartao de visita' and termo = 'cartao';
insert into public.sinonimos (grupo, termo) values
  ('cartao de visita','cartoes de visita'),
  ('adesivo','adesivos'), ('panfleto','panfletos'), ('panfleto','folhetos'), ('panfleto','flyers'),
  ('banner','banners'), ('sacola','sacolas'), ('caneca','canecas'), ('tag','tags'),
  ('cracha','crachas'), ('calendario','calendarios'), ('camiseta','camisetas')
on conflict do nothing;
