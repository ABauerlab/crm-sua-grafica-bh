-- Caso Hudson (17/11): ele pediu poucos crachás e a Laura mandou credenciais de papel de 500 unidades.
-- Busca: a categoria igual ao termo vem primeiro (crachá => categoria CRACHÁ, PVC), depois a categoria que casa com o termo,
-- lotes muito maiores que o pedido ficam por último, e a quantidade "exata" só vale na categoria certa.
-- Para quantidade que não existe: comparativo de lotes calculado no banco (N pacotes do lote pequeno x 1 lote maior).
-- Aplicada em produção pelo conector (várias etapas idempotentes); este arquivo registra a mudança.
-- Resumo das marcas no corpo de buscar_produto: /* categoria_igual */, /* categoria_primeiro */, /* lote_razoavel */,
-- /* exata_categoria */, /* lote_da_familia */, /* comparativo_lotes */, /* so_sem_exato */.
select 1;
