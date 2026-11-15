-- Feriados: escopo estadual (Minas Gerais) e calendário de 2028. Aditiva e idempotente.
alter table public.holidays drop constraint if exists holidays_scope_check;
alter table public.holidays add constraint holidays_scope_check check (scope = any (array['nacional', 'minas_gerais', 'belo_horizonte', 'gráfica']));

insert into public.holidays (day, name, scope) values
  ('2026-07-17', 'Data Magna de Minas Gerais', 'minas_gerais'),
  ('2027-07-17', 'Data Magna de Minas Gerais (sábado)', 'minas_gerais'),
  ('2028-07-17', 'Data Magna de Minas Gerais', 'minas_gerais'),
  ('2028-01-01', 'Confraternização Universal (sábado)', 'nacional'),
  ('2028-02-28', 'Carnaval (segunda)', 'nacional'),
  ('2028-02-29', 'Carnaval (terça)', 'nacional'),
  ('2028-04-14', 'Sexta-feira Santa', 'nacional'),
  ('2028-04-21', 'Tiradentes', 'nacional'),
  ('2028-05-01', 'Dia do Trabalho', 'nacional'),
  ('2028-06-15', 'Corpus Christi', 'nacional'),
  ('2028-08-15', 'Assunção de Nossa Senhora', 'belo_horizonte'),
  ('2028-09-07', 'Independência do Brasil', 'nacional'),
  ('2028-10-12', 'Nossa Senhora Aparecida', 'nacional'),
  ('2028-11-02', 'Finados', 'nacional'),
  ('2028-11-15', 'Proclamação da República', 'nacional'),
  ('2028-11-20', 'Consciência Negra', 'nacional'),
  ('2028-12-08', 'Imaculada Conceição', 'belo_horizonte'),
  ('2028-12-12', 'Aniversário de Belo Horizonte', 'belo_horizonte'),
  ('2028-12-25', 'Natal', 'nacional')
on conflict (day) do nothing;
