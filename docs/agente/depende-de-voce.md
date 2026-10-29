# O que depende de você

## Etapa 3 (aberto, 28/10/2026)

1. **Aplicar** `docs/agente/aplicar-etapa3.sql` no SQL Editor (faça o backup antes; é aditivo e idempotente, não apaga dados). Depois rode `supabase/tests/preco_etapa3.sql` (deve terminar com "OK: 67 testes passaram...") e os advisors de segurança. Só então mesclar o PR (o CRM novo já espera as funções).
2. **Instalar a busca no Coolify** seguindo `docs/agente/infra-busca.md` (SearXNG e leitor Playwright, rede interna, sem domínio). Não consegui acessar o Coolify desta sessão.
3. **Criar no n8n a credencial `GBH Supabase (service role)`** e escolher a credencial nos nós HTTP dos 4 workflows. Chaves de busca (Tavily, Serper, Firecrawl) são opcionais, com o passo a passo no mesmo documento.
4. **Termos de uso do concorrente prioritário (alfacards.com.br):** o `robots.txt` libera, mas não achei página de termos. Confirme (ou me diga) se posso ler a página pública do produto com 1 requisição a cada 15 s; até lá `fontes_pesquisa.termos_ok` fica vazio, o que **não** bloqueia, só registra a dúvida. Para bloquear o domínio, marque `termos_ok = false` ou `ativo = false` em `fontes_pesquisa`.
5. **Revisar os parâmetros novos** (`parametros_comerciais.campos_revisar`): meta de margem líquida para o aprendizado (20%), mínimo de 8 orçamentos em 30 dias, limites 15% e 45%, passo de 0,01, alerta de consumo de margem (40%), tempo máximo da pesquisa (45 s), tempo sem repetir pesquisa sem resultado (30 min).
6. **Decisão sua:** ligar o aquecimento de cache de madrugada? (`aquecer_cache_ligado`, desligado; só renova SKUs já orçados, até 10 por noite.)
7. **Testar no CRM:** Configurações > Política de desconto (mude o percentual e veja o pior caso); Catálogo > Saúde de preços; um pedido com item de teste, editando o preço abaixo do piso.

Sugestões (insights): (a) para o concorrente prioritário, o ganho real vem de uma receita de cliques no leitor (escolher quantidade e papel) por tipo de produto, só vale depois de ver quantas pesquisas voltam `sem_dado`; (b) comece a pesquisa pelos 20 SKUs mais orçados de cartão, panfleto e adesivo e olhe a cobertura antes de ligar o aquecimento; (c) com 30 dias de dados, a tela Saúde de preços mostra onde subir ou baixar o fator sem achismo.

---

# Etapa 2 (histórico)

## Estado em 28/10/2026: Etapa 2 concluída

Feito: migrations aplicadas, função `conhecimento` publicada, vetores em geração, advisors rodados, PR #22 mesclado, planilha de custo conferida (igual ao catálogo atual, sem linhas sem código) e trechos de conhecimento marcados como revisados.

Fica para você, quando puder: reler os trechos em Configurações > Conhecimento e validar os `[CONFIRMAR]` (parcelamento, nota fiscal, troca e reembolso, prazo mais curto, composição dos kits, indicação) e ligar a proteção contra senhas vazadas em Authentication > Policies. O restante do documento abaixo é histórico.

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


## Etapa 4: orçamento em PDF

1. **Aplicar** `docs/agente/aplicar-etapa4.sql` (a migration `20261029000009`) no SQL Editor, rodar `supabase/tests/orcamento_etapa4.sql` e os advisors de segurança. Antes, confirme que a migration `20261029000008_orcamentos.sql` da sessão interrompida **não** foi aplicada (a consulta está no `progresso.md` do PR de retomada); se foi, me avise antes de seguir.
2. **Instalar o Gotenberg** no Coolify (`infra/gotenberg/docker-compose.yml`) e criar os segredos da função: `GOTENBERG_URL`, `GOTENBERG_USER`, `GOTENBERG_PASSWORD`. Publicar `supabase functions deploy orcamento-pdf --no-verify-jwt`.
3. **n8n:** nos 4 workflows novos e no `condicao_especial`, abrir cada nó HTTP e escolher a credencial `GBH Supabase (service role)` (o MCP não atribui). Continuam desativados até a Etapa 8.
4. **Brand kit:** conferido no Google Drive (`cores_variaveis.css` e `tipografia_oficial`): paleta e Inter batem; títulos em Inter Display Black, rótulos em Inter Medium caixa alta. Falta só você olhar um PDF de exemplo.
5. **Número do orçamento:** fica `SG-0001` (decisão do dono).
6. **Instagram e site:** gravar em `app_settings.company` (`instagram` = `@suagraficabh`, `site` = `suagraficabh.com.br`) com o SQL do prompt de aplicação; o rodapé do PDF passa a mostrar.
7. **Confirmar:** validade do orçamento em 48 h (`parametros_comerciais.validade_orcamento_horas`) e valores da arte (R$ 39,90 e R$ 49,90).
