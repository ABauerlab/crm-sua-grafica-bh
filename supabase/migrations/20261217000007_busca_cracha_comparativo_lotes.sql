-- Caso Hudson (17/11): ele pediu poucos crachás e a Laura mandou credenciais de papel de 500 unidades.
-- Busca: a categoria igual ao termo vem primeiro (crachá => categoria CRACHÁ, PVC), depois a categoria que casa com o termo,
-- lotes muito maiores que o pedido ficam por último, e a quantidade "exata" só vale na categoria certa.
-- Para quantidade que não existe: comparativo de lotes calculado no banco (N pacotes do lote pequeno x 1 lote maior).
-- Aplicada em produção pelo conector (várias etapas idempotentes); este arquivo registra a mudança.
-- Resumo das marcas no corpo de buscar_produto: /* categoria_igual */, /* categoria_primeiro */, /* lote_razoavel */,
-- /* exata_categoria */, /* lote_da_familia */, /* comparativo_lotes */, /* so_sem_exato */.
select 1;

-- montar_orcamento: se o lote maior do mesmo produto custa menos que os pacotes pedidos, usa o lote maior (aviso
-- `lote_maior_mais_barato`; `opcoes.nao_otimizar_lote = "true"` desliga). Ex.: 2 crachás = R$ 157,90 em pacotes de 1,
-- ou R$ 86,90 no lote de 5. Marca no corpo da função: /* lote_maior_barato */. Aplicada em produção pelo conector.
