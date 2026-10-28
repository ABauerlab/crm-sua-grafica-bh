# Relatório de importação do catálogo (Etapa 2)

## Situação: a tabela de preços (PDF) NÃO chegou nesta sessão

O prompt pedia para anexar o PDF, mas nenhum arquivo foi anexado à sessão (procurei no ambiente inteiro e não há PDF). Por isso **a importação do PDF não foi feita**, nada do arquivo real foi lido e **não existe relatório real de linhas sem código ainda**. Preferi não inventar números.

Tudo o que a importação precisa está pronto e testado com dados fictícios. Para importar:

1. Aplique as migrations da Etapa 2 (`docs/agente/aplicar-etapa2.sql`).
2. Publique o CRM e abra **Catálogo e Kits > Catálogo do fornecedor > Importar tabela**.
3. Escolha o PDF, confira o mapeamento, clique em **Pré-visualizar diferenças** e leia o relatório.
4. Se estiver tudo certo, marque os alertas (se houver) e **Confirmar e aplicar**.
5. Baixe o CSV de **Linhas sem código** e me passe (ou preencha os códigos na aba **Sem código**).

## O que já consegui conferir no catálogo atual de produção (somente leitura)

| Item | Valor |
|---|---|
| Linhas em `products` | 20.381 |
| Categorias distintas | 140 (o PDF novo tem cerca de 198) |
| Linhas sem código | 0 (o importador antigo **descartava em silêncio** as linhas sem código, por isso nenhuma entrou) |
| CFV02 (1.000 cartões) | R$ 75,99 (confere com a tabela de valores atuais) |
| CFV02D (2.000 cartões) | R$ 143,99 |
| Linhas com tamanho "0 x 0" (dimensão desconhecida) | 910 |
| Peso | em gramas (CFV02: 1.392 g = 1.000 x 91 x 51 mm x 300 g/m²) |
| Preço sugerido (`suggested_price`) | 0 em todas as linhas |

O catálogo atual tem **mais linhas (20.381) que o PDF novo (cerca de 19,5 mil)** e menos categorias (140 contra 198). Isso indica que o catálogo de hoje veio de outro arquivo. Espere na pré-visualização:

* muitas linhas **novas** e muitas **que saíram da tabela**. Se mais de 25% do catálogo atual sumir, a tela dispara o alerta "mais de 25% do catálogo atual não aparece neste arquivo" e exige sua confirmação. Itens que saíram são **desativados, nunca apagados**; confira a lista antes de confirmar;
* cerca de 590 linhas **sem código** (PDV, balcão, adesivo vinil PDV, totens e displays de polionda, apergaminhado): entram com `sku = null`, `status_venda = sem_sku`, `vendavel = false`;
* o CFV02 do arquivo precisa ser **R$ 75,99**. Se não for, ou se os valores parecerem cerca de 80% acima dos atuais (a tabela antiga com custo x1,8), a tela avisa **antes** de aplicar.

## Como o relatório vai aparecer

Contagens (todas somam as lidas, nenhuma linha some em silêncio):

| Campo | Significado |
|---|---|
| Lidas | Linhas de dados lidas do arquivo (confrontada com a contagem independente de linhas que terminam em preço) |
| Novas / Alteradas / Iguais | Contra o catálogo atual, por SKU |
| Sem código | Linhas sem SKU (lista com categoria, descrição, quantidade, tamanho e prazo; CSV para baixar) |
| Duplicadas (iguais) | SKU repetido com os mesmos dados: entra uma só |
| Conflitos | SKU repetido com dados diferentes: **nenhuma das linhas é aplicada**, você decide |
| Rejeitadas | Sem descrição, custo, quantidade ou prazo; código com caracteres inválidos. Cada uma com o motivo |
| Saíram da tabela | Desativadas na aplicação |
| Acima de X% | Preço ou prazo alterado acima do limite (padrão 20%) |
| Pisos que mudam | Itens com custo alterado (piso e piso duro são recalculados) |

Depois de aplicar: inseridas, atualizadas, desativadas e quantos itens ficaram **não competitivos** (filtro "Não competitivo" no catálogo). O relatório fica salvo em `catalogo_importacoes.relatorio`.

## Linhas sem código

_Aguardando o PDF._ Depois da importação, a lista completa (categoria, descrição, quantidade, tamanho, prazo) estará em **Catálogo e Kits > Sem código** e no CSV "Linhas sem código". Me peça os códigos com esse CSV.

## Verificações feitas sem o PDF real

* Leitor de PDF testado com **um PDF fictício gerado com o mesmo leiaute** (9 colunas, 2 páginas, números alinhados à direita e à esquerda, linha sem código, descrição quebrada em duas linhas, cabeçalho repetido por página): leu as 5 linhas e a data de emissão, e o total lido bateu com a contagem independente.
* Leitor com itens simulados no `npm test`.
* Importação de ponta a ponta no Postgres local (nova, alterada, igual, duplicada, conflito, rejeitada, sem código, remoção em massa, CFV02 diferente, histórico, invalidação de cache): 82 testes.
* Tempo das migrations com 20 mil linhas: cerca de 10 segundos.

**Risco que só o PDF real resolve:** o leiaute exato das colunas. Se a pré-visualização mostrar colunas trocadas ou o aviso "O PDF tem X linhas com preço e eu li Y", **não aplique**: me mande o PDF e ajusto o leitor. A tela também aceita a mesma tabela exportada para Excel/CSV.
