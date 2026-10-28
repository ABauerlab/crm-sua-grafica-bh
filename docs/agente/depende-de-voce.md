# O que depende de você (Etapa 2)

## Para a Etapa 2 funcionar em produção

1. **Anexar o PDF da tabela de preços do fornecedor.** Ele não chegou nesta sessão, então a importação real não foi feita. Importe pela tela (passo a passo em `docs/agente/relatorio-importacao.md`) ou me mande o arquivo.
2. **Aplicar as migrations 15 a 19** (arquivo único `docs/agente/aplicar-etapa2.sql`, cole no SQL Editor; faça o backup antes). A migration **renomeia** `products` para `catalogo` (dados e ids ficam). Não apliquei em produção por conta própria porque renomeia uma tabela de 20 mil linhas.
3. **Fazer o deploy da função nova:** `supabase functions deploy conhecimento --no-verify-jwt` (ou pelo conector). Depois, **Configurações > Conhecimento > Reindexar tudo** para gerar os vetores.
4. **Rodar os advisors de segurança** depois de aplicar (a regra do projeto). Não rodei porque não apliquei.
5. Mesclar o PR **depois** de aplicar as migrations (o CRM novo já espera as tabelas e funções novas).

## Códigos que preciso de você

* **Os códigos das cerca de 590 linhas sem SKU** (PDV, balcão, adesivo vinil PDV, totens e displays de polionda, apergaminhado). Eu não invento códigos. Quando importar, baixe o CSV "Linhas sem código" e me passe, ou preencha na aba **Sem código**.
* **Os conflitos de SKU repetido com dados diferentes**, se aparecerem: diga qual linha vale.

## Para validar (marcados com [CONFIRMAR] nos trechos)

* Parcelamento no cartão (número de parcelas, juros) e se existe parcelamento.
* Política de nota fiscal.
* Política de troca, reposição e reembolso em caso de reclamação.
* Se dá para encurtar prazo (hoje o agente só oferece chamar você).
* Composição de cada kit (Barbearia, Delivery, Loja, Lançamento) e se o kit tem preço fechado.
* Programa de indicação (existe benefício?).

Os 90 trechos nascem com `revisar = true`. Leia em **Configurações > Conhecimento**, ajuste o tom se quiser e clique em "Salvar e marcar revisado".

## Decisões que tomei e você pode reverter

* **`products` virou `catalogo`**, com `products` mantida como visão de compatibilidade até a Etapa 8.
* **Colunas em português** (`sku`, `custo`, `peso_g`, `tamanho_mm`, `prazo_dias_uteis`...). `order_items.code` continua com o nome antigo e é o SKU do pedido.
* **Pago nunca é bloqueado** por falta de SKU (o dinheiro já entrou): vira alerta alto. **Produção** é bloqueada.
* **Itens que saem da tabela são desativados**, não apagados (pedidos antigos apontam para eles).
* **Limite de destaque de variação:** 20% (você muda na tela a cada importação).
* **Alerta de tabela parcial:** mais de 25% do catálogo atual ausente do arquivo.
* **Preço de kit** hoje é a soma dos preços dos SKUs (sempre segura). A Etapa 3 refina (lucro mínimo uma vez só no conjunto).
* **Limiares de busca** (0,80 semântico, 0,35 texto) são chute inicial: calibre medindo no relatório de recuperação.
* **Branch:** trabalhei na branch da sessão (`claude/optimistic-pasteur-9elhra`), não em `feat/agente-etapa2-catalogo-conhecimento`, porque a sessão me prendeu a ela. O conteúdo é o mesmo; renomeie ao abrir o PR se preferir.

## Sugestões de melhoria (insights)

* **Alerta de "preço de mercado abaixo do piso"** já existe como status `nao_competitivo`; na Etapa 3 vale uma tela "Saúde de preços" com cobertura de mercado por categoria.
* **Foto por produto** (Etapa 4B): `catalogo.grupo_produto` já permite ligar uma foto por grupo, não por SKU (19 mil SKUs).
* **Cache de busca por SKU** para os 200 itens mais vendidos, quando houver vendas.
* **Sinônimos regionais** (ex.: "santinho", "cartão pessoal"): a tabela `sinonimos` aceita novos termos sem deploy.
