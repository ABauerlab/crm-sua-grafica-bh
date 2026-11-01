# Preço do fornecedor por dimensão (Bloco C)

Itens como TÓTENS TOTEM DE MÃO POLIONDA 3MM (código TOT3MAO1) variam por largura e altura e o preço só aparece com login no site do fornecedor.

## O que está pronto (Etapa 7B)
- Tabela `catalogo_formulas` (privada ao dono) e função `private.custo_por_dimensao(sku, largura_mm, altura_mm)`: só devolve custo se existir fórmula **ativa e validada** (erro máximo das amostras de 1%). Sem fórmula validada devolve nulo e **nenhuma oferta definitiva é gerada** (o agente diz que vai confirmar e chama o dono em baixa gravidade). O custo nunca vai ao agente; passa por `calcular_preco` com mercado, taxa e piso.
- Origem e data ficam em `origem` e `validada_em`.

## O que falta e só você pode fazer
1. **Termos e API:** abrir os termos de uso do fornecedor e perguntar se existe API, exportação ou tabela por m². **Pergunte ao fornecedor a fórmula ou a tabela por metro quadrado**; é o caminho mais seguro e barato.
2. **Coleta pelo seu login:** passe 8 a 10 pontos (largura x altura x preço) de cada item de dimensão. Com isso eu testo se `preço = máx(mínimo, m² x preço_m²)` reproduz com erro menor que 1% e gravo a fórmula por SKU.
3. **Só se não houver alternativa:** workflow `GBH | FERRAMENTA | consultar_preco_dimensao` com login automatizado (navegador no servidor), credencial **somente** no n8n (nunca no repositório, no front ou em log), limite de taxa, cache de 24 h por SKU, largura e altura, tempo limite e tratamento de sessão expirada. Não foi criado porque o login automatizado só deve existir depois de você confirmar que os termos permitem.

Por que não fiz mais: não tenho o seu login e não devo automatizar acesso a um site de terceiros sem confirmar os termos. A estrutura acima está pronta para receber os dados.
