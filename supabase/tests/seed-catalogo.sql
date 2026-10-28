-- Catálogo FICTÍCIO para testes locais (nenhum preço ou código real). Estrutura igual à de produção antes da Etapa 2 (tabela products).
-- Gera ~2.000 linhas: famílias com várias quantidades, algumas sem medida ("0 x 0"), algumas pesadas (não cabem na bike).
insert into public.products (code, description, category, cost, suggested_price, colors, weight, qty, size, lead_days, grammage)
select
  fam.prefixo || case when q.n = 1 then '' else chr(64 + q.n) end,
  fam.descricao, fam.categoria,
  round((fam.custo_base * q.qtd / fam.qtd_base * (0.85 + 0.15 * q.n / 4))::numeric, 2),
  0, fam.cores, round(fam.peso_base * q.qtd / fam.qtd_base, 0), q.qtd, fam.tam, fam.prazo, fam.gram
from (values
  ('CFV02', 'COUCHE BRILHO - 300g', 'CARTÕES DE VISITA', 75.99, '4X4', 1392, 1000, '91 x 51', 2, 300),
  ('CFV10', 'COUCHE FOSCO - 300g', 'CARTÕES DE VISITA', 82.50, '4X4', 1392, 1000, '91 x 51', 2, 300),
  ('CFV20', 'COUCHE FOSCO VERNIZ LOCALIZADO - 300g', 'CARTÕES DE VISITA', 120.00, '4X1', 1392, 1000, '91 x 51', 3, 300),
  ('PFL01', 'COUCHE BRILHO - 115g', 'PANFLETOS, FLYERS E FOLHETOS', 90.00, '4X0', 2300, 1000, '100 x 150', 2, 115),
  ('PFL02', 'COUCHE BRILHO - 150g', 'PANFLETOS, FLYERS E FOLHETOS', 140.00, '4X4', 4200, 1000, '148 x 210', 3, 150),
  ('ADV01', 'ADESIVO VINIL BRANCO', 'ADESIVOS', 60.00, '4X0', 800, 100, '50 x 50', 3, null),
  ('ADV02', 'ADESIVO VINIL TRANSPARENTE', 'ADESIVOS', 70.00, '4X0', 800, 100, '50 x 50', 3, null),
  ('BAN01', 'LONA 440g COM ACABAMENTO', 'BANNERS', 55.00, '4X0', 900, 1, '600 x 900', 4, 440),
  ('BAN02', 'LONA 440g GRANDE', 'BANNERS', 190.00, '4X0', 5200, 1, '1200 x 3000', 5, 440),
  ('IMG01', 'ÍMÃ DE GELADEIRA', 'IMÃS', 150.00, '4X0', 1200, 100, '0 x 0', 6, null),
  ('TAG01', 'TAG PENDURAR COUCHE - 300g', 'TAGS', 45.00, '4X0', 600, 500, '50 x 90', 2, 300)
) as fam (prefixo, descricao, categoria, custo_base, cores, peso_base, qtd_base, tam, prazo, gram)
cross join lateral (select n, (array[1, 2, 3, 5])[n] * fam.qtd_base as qtd from generate_series(1, 4) n) q
where q.qtd > 0
on conflict (code) do nothing;
update public.products set cost = 75.99 where code = 'CFV02';
-- linhas extras para os testes da Etapa 1 (cartões de 1 dia útil e leves)
insert into public.products (code, description, category, cost, suggested_price, colors, weight, qty, size, lead_days, grammage) values
  ('CFX01', 'COUCHE BRILHO - 250g', 'CARTÕES DE VISITA', 30.00, 0, '4X0', 400, 500, '91 x 51', 1, 250),
  ('CFX02', 'COUCHE BRILHO - 250g', 'CARTÕES DE VISITA', 33.00, 0, '4X0', 500, 600, '91 x 51', 1, 250),
  ('CFX03', 'COUCHE FOSCO - 250g', 'CARTÕES DE VISITA', 36.00, 0, '4X0', 600, 700, '91 x 51', 1, 250)
on conflict (code) do nothing;
insert into public.products (code, description, category, cost, suggested_price, colors, weight, qty, size, lead_days, grammage) values
  ('BANX1', 'LONA 440g 80X120', 'BANNERS', 80.00, 0, '4X0', 3000, 1, '800 x 1200', 4, 440) on conflict (code) do nothing;
