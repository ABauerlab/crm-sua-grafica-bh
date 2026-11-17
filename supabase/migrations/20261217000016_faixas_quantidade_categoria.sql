-- Faixas de quantidade por categoria para a escada de preço da Laura (regra W). Aplicada pelo conector.
-- Tabela public.faixas_quantidade_categoria (categoria -> quantidades-alvo, editável pelo dono); private.faixas_escada(sku)
-- escolhe, na mesma família do SKU (categoria, papel, cores, tamanho), os lotes mais próximos dos alvos e só mantém os que
-- baixam o valor por unidade; buscar_produto devolve faixas_sugeridas e orientacao_faixas (marca /* escada */).
-- Sem categoria na tabela: usa 10x e 50x o lote pedido. O texto completo da migration está no banco (fonte da verdade).
select 1;
