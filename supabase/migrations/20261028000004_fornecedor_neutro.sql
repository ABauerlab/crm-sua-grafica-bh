-- O nome do fornecedor nunca aparece no sistema: o valor padrão da coluna passa a ser neutro.
alter table public.products alter column supplier set default 'Fornecedor';
update public.products set supplier = 'Fornecedor' where supplier <> 'Fornecedor';
