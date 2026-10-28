# Catálogo do fornecedor e SKU (Etapa 2)

A tabela de preços do fornecedor é **privada**. Este documento descreve como o CRM guarda, importa, busca e protege essa tabela, e como o SKU atravessa orçamento, pedido, kanban e kit.

## 1. Regra de ouro: o que é privado

| O quê | Quem vê |
|---|---|
| Tabela original (PDF) | Só o dono, no bucket privado `catalogo-fornecedor` do Supabase Storage. Nunca no repositório (`.gitignore` bloqueia PDF, CSV, JSON e dumps do catálogo; `npm test` falha se aparecer um) |
| `catalogo`, `catalogo_historico`, `catalogo_importacoes`, `catalogo_import_linhas` | Só o dono (`private.is_staff()`). `anon` não tem nem privilégio; atendente comum e logado sem perfil recebem zero linhas |
| Custo, piso, piso duro, margem, lucro | Só o dono e as funções do servidor. Nenhuma função do agente devolve esses campos |
| SKU do fornecedor | Interno. Aparece nas telas do dono (com botão copiar). **Não** aparece no PDF nem em mensagem ao cliente: o cliente vê o número do orçamento (SG-0001) |
| Nome do fornecedor | Em lugar nenhum. Sempre "fornecedor" |

O agente e o front de atendimento só chegam ao catálogo por funções `SECURITY DEFINER` que filtram campos: `buscar_produto`, `agente_preco`, `buscar_conhecimento`. O teste `supabase/tests/catalogo_etapa2.sql` confere que a resposta delas não contém `custo`, `piso`, `margem`, `lucro` nem `fornecedor`.

## 2. Como era antes (Passo 0)

A tela **Catálogo e Kits > Catálogo do fornecedor** já existia, com o botão "Importar planilha".

* **Tabela:** `products` (20.381 linhas em produção, 140 categorias). Colunas: `code` (único), `description`, `category`, `colors`, `weight`, `qty`, `size`, `lead_days`, `grammage`, `cost`, `suggested_price`, `active`, `supplier`, `permite_desconto`.
* **Parser:** `src/lib/spreadsheet.ts`. Lia Excel, CSV e HTML salvo como `.xls`. **PDF era recusado.** O dono escolhia as colunas numa tela de mapeamento.
* **Peso, tamanho, prazo:** guardados como vinham. Conferi com o CFV02 (1.000 cartões 91 x 51 em 300 g/m²): 1.392 g, que é exatamente 1.000 x 0,091 x 0,051 x 300. **Peso é em gramas.** Tamanho em milímetros. Prazo já era bruto.
* **Preço de venda:** `suggested_price = custo x multiplicador único` digitado na hora (padrão 2,5). Todas as 20.381 linhas estavam com 0.
* **Gravação:** `upsert` por `code` em lotes de 500.

### Lacunas encontradas e como foram corrigidas (na mesma tela, sem perder dados)

| Lacuna | Correção |
|---|---|
| PDF não era lido | Leitor de PDF no navegador (`src/lib/catalog-pdf.ts`), conferido contra a contagem independente de linhas que terminam em preço |
| Linha sem código era **descartada em silêncio** (por isso o catálogo atual não tem nenhuma) | Entra como `sem_sku`, `vendavel = false`, aparece na aba "Sem código" e no relatório |
| Código repetido: a última linha vencia em silêncio | Dados idênticos: uma só. Dados diferentes: **conflito**, nenhuma das linhas é aplicada até o dono decidir |
| Linha com custo, quantidade ou prazo faltando sumia | Vai para o servidor e é **rejeitada com motivo**, listada e baixável em CSV |
| Sem pré-visualização nem confirmação | Duas fases: pré-visualização das diferenças, depois "Confirmar e aplicar" |
| Sem histórico | `catalogo_historico` guarda custo e prazo anteriores a cada mudança |
| Sem conferência | Relatório com lidas = novas + alteradas + iguais + duplicadas + conflitos + rejeitadas + sem código; confere o total do arquivo e o CFV02 = R$ 75,99; avisa de tabela com valores cerca de 80% acima |
| Preço sugerido por multiplicador único | A coluna virou **"Base de custo (ref.)"**: custo x multiplicador da faixa, terminado em ,90, **sem pesquisa de mercado**. Nunca vale para orçamento, PDF ou link. O **Preço de venda** exibido vem de `calcular_preco` |
| Sem status de venda, flags nem rastreio | `status_venda`, `vendavel`, `cabe_na_bike`, `grupo_produto`, `especificacao_normalizada`, `origem_importacao_id`, `atualizado_em` |
| `verificar_frete` tratava "0 x 0" como lado zero (910 linhas ganhavam frete grátis indevido) | "0 x 0" e tamanho sem número são **dimensão desconhecida**: sem frete grátis |
| Item de pedido pelo catálogo entrava com `qtd = quantidade do pacote` e `custo = custo do pacote` (custo multiplicado) | A linha é uma opção fechada: `qtd = 1` pacote, custo e preço por pacote |
| SKU opcional no pedido | Obrigatório (ver seção 5) |

## 3. Banco

`products` foi **renomeada** para `catalogo` (mesmos 20.381 registros, mesmos ids, as chaves estrangeiras dos kits seguiram). `products` continua existindo como **visão de compatibilidade** (as funções da Etapa 1 e telas antigas leem por ela). Sai na Etapa 8.

Campos de `catalogo`: `sku` (único quando não nulo), `categoria`, `descricao`, `cores`, `peso_g`, `quantidade`, `tamanho_mm`, `prazo_dias_uteis` (**bruto**; o +1 só entra em `calcular_prazo`), `custo`, `grupo_produto`, `especificacao_normalizada`, `status_venda`, `vendavel`, `permite_desconto`, `cabe_na_bike`, `origem_importacao_id`, `atualizado_em`, mais `gramatura_g`, `preco_base_custo`, `maior_lado_mm`, `piso`, `piso_duro`, `chave_natural` (identifica linha sem código) e `active`.

* `sem_sku` sempre tem `vendavel = false` (constraint). `nao_vender` também.
* `grupo_produto` nasce igual à categoria (editável).
* `cabe_na_bike` por linha: peso e maior lado contra os parâmetros da Etapa 1 (`peso_max_bike_g`, `lado_max_bike_mm`). `verificar_frete` **soma o peso do pedido todo**: 3 pacotes de 1.392 g não cabem, mesmo que cada um caiba sozinho.
* `piso` e `piso_duro` são recalculados na própria linha quando o custo muda. Mudou um parâmetro de preço? Botão **Recalcular pisos** (em lotes) na tela do catálogo.
* Triggers existentes de lucro (Etapa 1) continuam valendo.

## 4. Importação (mesma tela)

1. **Escolher o arquivo** (PDF, Excel ou CSV). O PDF é lido no navegador; colunas pelo cabeçalho de cada página. Se o total de linhas lidas não bater com o de linhas que terminam em preço, a tela avisa antes de continuar.
2. **Mapear as colunas** (igual a antes).
3. **Pré-visualizar:** o arquivo original vai para o bucket privado, as linhas vão em lotes de 1.000 para `catalogo_import_linhas` e o banco classifica cada uma: nova, alterada, igual, duplicada, conflito, rejeitada, sem código. **Nada foi gravado no catálogo ainda.**
4. **Relatório de diferenças:** contagens, itens que saíram da tabela, variação de preço ou prazo acima de X% (padrão 20%), quantos pisos mudam, CFV02, listas navegáveis e CSV de sem código, conflitos e rejeitadas.
5. **Confirmar e aplicar:** alertas graves (CFV02 diferente, valores parecendo x1,8, mais de 25% do catálogo sumindo, total que não confere) exigem marcar "li os alertas". Aplica em lotes; atualiza o histórico; invalida o cache de `precos_mercado` **só dos itens cujo custo mudou**; reclassifica `nao_competitivo`. Itens que saíram da tabela são **desativados, não apagados**.

Mesma tela para as atualizações futuras.

## 5. SKU obrigatório

* `orcamento_itens.sku` e `order_items.code` (o SKU do pedido, nome antigo mantido) têm **chave estrangeira para `catalogo.sku`**, `NOT VALID` (registros antigos ficam isentos; os novos são checados). Pedido sem SKU é recusado (`exigir_sku_pedidos` ligado).
* Item de orçamento precisa existir no catálogo **e ser vendável**.
* **Produção** é recusada com item sem SKU. **Pago** nunca é bloqueado (dinheiro recebido): se o pedido pago tem item sem SKU, abre alerta de gravidade alta para o dono.
* **Item fora do catálogo:** `registrar_item_sem_sku(conversa, descrição, quantidade)` guarda o pedido em `itens_fora_catalogo` (status `sem_sku`), chama o dono (alta, no máximo uma vez a cada 30 minutos por conversa) e orienta o agente a **não montar orçamento nem enviar link**.
* No CRM: o SKU aparece em destaque com botão **copiar** no pedido, no cartão do kanban, no kit e no catálogo. No pedido pago há a aba **Pedido para a fábrica** (SKUs, quantidades, especificação, prazo, arte aprovada, cliente, botão copiar resumo).
* Kits são listas de SKUs (`kit_items.sku`, visão `kit_itens`). O preço do kit vem de `kit_preco`, que usa `calcular_preco` em cada SKU.

## 6. Busca de produto

`buscar_produto(termo, quantidade, filtros)`:

* Sem acento, plural simples removido, tabela `sinonimos` (cartão = cartão de visita; panfleto = flyer = folheto; adesivo = etiqueta = sticker; banner = lona; carregada das categorias por `sinonimos_carregar_categorias()`), texto mais trigram para erro de digitação.
* No máximo **5 opções**, uma por família (mesma categoria, descrição, cores e tamanho), na quantidade mais próxima da pedida: `sku`, `descricao_curta`, `quantidade`, `prazo_dias_uteis` (bruto), `preco` (de `calcular_preco`), `vendavel`, `quantidade_exata`.
* Se a quantidade pedida não existe, `oferecer_mais_proxima = true`.
* Pedido vago devolve `pergunta_qualificacao` (quantidade, tamanho, papel ou cores, nessa ordem).
* Só devolve item vendável com SKU. Se só existir linha sem código, devolve `orientacao = sem_sku_chamar_dono_alta`.
* Busca direta por SKU: **só o dono**.
* `agente_preco(sku, quantidade)` devolve apenas o preço final.

## 7. Testes

| Teste | Como rodar | Resultado |
|---|---|---|
| SQL da Etapa 2 (importação, histórico, segurança, SKU, conhecimento) | `supabase/tests/rodar-local.sh supabase/tests/catalogo_etapa2.sql` ou SQL Editor | 82 passam |
| SQL da Etapa 1 contra o schema novo | `supabase/tests/rodar-local.sh supabase/tests/agente_etapa1.sql` | 54 passam |
| Leitor de PDF, planilha, linha sem código, sigilo | `npm test` | passa |

O Postgres local usa um catálogo **fictício** (`supabase/tests/seed-catalogo.sql`). A importação do PDF real depende do arquivo (ver `docs/agente/relatorio-importacao.md`).
