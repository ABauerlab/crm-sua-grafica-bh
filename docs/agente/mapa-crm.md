# Mapa do CRM (Etapa 1)

Fotografia do CRM como ele estava em 28/10/2026, antes das migrations da Etapa 1, e o que muda. Atualizar a cada etapa.

## 1. O que existe

**Front** (`src/`): Vite, React 19, TypeScript, Tailwind v3, componentes estilo shadcn/ui, React Router, TanStack Query. Rotas: `/painel`, `/kanban`, `/inbox/:id`, `/contatos`, `/catalogo`, `/campanhas`, `/pagamentos`, `/tarefas`, `/templates`, `/configuracoes` (abas Empresa, Preços, Kanban, Respostas rápidas, Etiquetas, Prazos e feriados, Metas, WhatsApp e templates, Agente de IA, Dados), `/atendentes`. O front só fala com o Supabase (chave publicável + JWT do dono, RLS). Nada de WhatsApp no front.

**Supabase** (projeto `bhlosshvwmlyzhbghsrc`):

| Área | Tabelas e views |
|---|---|
| Atendimento | `profiles`, `contacts`, `conversations` (uma por contato), `messages`, `conversation_notes`, `quick_replies`, `templates_cache`, `marketing_suppressions` |
| Pedidos | `orders`, `order_items`, `order_events`, `order_files` (bucket privado `order-files`), view `order_financials`, `tasks` |
| Catálogo | `products` (20.381 linhas, uma por opção de quantidade), `kits`, `kit_items`, view `products_priced`, `product_categories` |
| Pagamento (Mercado Pago, em produção) | `pagamentos`, `eventos_pagamento`, `pagamentos_alertas`, funções `private.confirmar_pagamento`, `mp_registrar_pagamento`, `confirmar_pagamento_manual`, `validar_antes_de_cobrar` |
| Campanhas | `ad_entities`, `ad_daily`, `ad_manual_spend`, função `ad_performance`, view `contact_stats` |
| Prazo | `holidays` (30 feriados 2026/2027), `is_business_day`, `add_business_days` |
| Configuração | `app_settings` (`pricing`, `kanban`, `owner`, `agent`, `company`, `labels`, `campaign_goals`, `repurchase`, `deadline`), `agent_logs` |

**Edge Functions**: `whatsapp-webhook`, `whatsapp-send`, `whatsapp-sync-templates`, `whatsapp-media`, `admin-create-agent`, `meta-ads-sync`, `mp-webhook`, `mp-criar-link`, `mp-conferir`. O webhook da Meta é único e continua sendo o `whatsapp-webhook`.

**n8n** (n8n.bauerlab.com.br): 13 workflows de outros projetos do dono (Iracema, Teggly, Fluxo Dos Mercados, SUALOJALAB). Nenhum `GBH |`, nenhuma pasta, nenhuma tag. Credenciais existentes: Google Drive, Postgres, Gemini, Groq, 2 Header Auth. Não falta nada para a Etapa 1; faltam credenciais do Supabase (service role) e do WhatsApp para a Etapa 5. Nenhum workflow de outro projeto foi lido ou alterado.

**Como o preço é calculado hoje (antes da Etapa 1)**:
- Importação do catálogo (`src/lib/spreadsheet.ts`): `suggested_price = custo x multiplicador único` (padrão 2,5), gravado em `products.suggested_price` (hoje todos os 20.381 itens estão com 0).
- `products_priced`: piso = custo x 1,5; desconto máximo = 10%; lucro estimado com taxa fixa 1,5%.
- Kanban e pedido: `order_financials` calcula total, imposto (6%), taxa (`orders.payment_fee_pct`, padrão 1,5%) e lucro líquido; `src/lib/pricing.ts` só gera alertas na tela (abaixo do piso, desconto acima de 10%, lucro abaixo de R$ 60). Os alertas não bloqueavam nada.
- Nada disso olhava mercado, método de pagamento, entrega, WhatsApp ou IA.

## 2. O que será reaproveitado

`conversations` (`needs_human`, `summary`, `collected_data`, `labels`, `ad_window_until`, `ai_handled`), `contacts` (`first_referral`, `marketing_consent`, `segment`), `holidays`, `agent_logs`, `products` (código = SKU do fornecedor, uma linha por quantidade), `orders`/`order_items`, todo o Mercado Pago (`pagamentos`, `eventos_pagamento`, `pagamentos_alertas`, `mp-*`), `templates_cache` e a sincronização de templates, `app_settings`.

## 3. O que foi estendido ou criado (migrations 11 a 14)

Novo: `parametros_comerciais`, `politica_desconto`, `zonas_frete_gratis`, `agente_config`, `anuncios_produtos`, `orcamentos`, `orcamento_itens`, `condicoes_especiais`, `precos_mercado`, `precos_praticados`, `conhecimento` (pgvector, 768 dimensões), `followup_regras`, `followup_fila`, `alertas`, `testes_conversa`; funções `calcular_preco`, `calcular_prazo`, `verificar_frete`, `validar_margem`, `calcular_condicao_especial`. Detalhes em `docs/agente-ia.md`.

**Mapa de nomes** (a spec da etapa usa um nome, o CRM já tinha outro; ficou o que já existia):

| Pedido na etapa | No CRM |
|---|---|
| `feriados` | tabela `holidays` + visão `feriados` |
| `agente_logs` | tabela `agent_logs` (ganhou tokens, custo, ferramenta, modelo) + visão `agente_logs` |
| `conversas.precisa_humano` | `conversations.needs_human` |
| `conversas.resumo` | `conversations.summary` |
| `conversas.dados_coletados` | `conversations.collected_data` |
| `conversas.modo_atendimento` | coluna nova `modo_atendimento` (`ia`/`humano`), sincronizada com `ai_handled` por trigger |
| `contatos.optout` | coluna gerada `optout` (= `marketing_consent = 'opted_out'`) |
| `contatos.origem_anuncio` | coluna gerada `origem_anuncio` (= `first_referral->>'source_id'`) |
| `contatos.segmento` | `contacts.segment` |
| `contatos.status_lead`, `bairro`, `cep` | colunas novas |
| `pedidos.subestatus_pedido` | coluna nova em `orders` |
| SKU | `products.code` (único por opção de quantidade). `order_items.code` e `orcamento_itens.sku` carregam o SKU. A Etapa 2 decide se entra um SKU próprio, que passaria a ter precedência |

## 4. Conflitos com as regras do projeto e como foram resolvidos

| Conflito | Resolução (sem perder dados) |
|---|---|
| Preço sugerido no upload do catálogo (custo x 2,5) | Continua gravado, mas não vale para orçamento. O único preço válido é `calcular_preco`. A tela do catálogo deve rotular a coluna como "base de custo, sem pesquisa" (Etapa 3). Dados intactos |
| Preço de kit (`kits.price`) | Mesmo tratamento: a Etapa 3 recalcula pelos SKUs do kit com a mesma fórmula |
| Preço no cartão do kanban (`order_financials`, taxa 1,5%) | A taxa padrão de `orders.payment_fee_pct` passou de 1,5% para 4,98% (cartão de crédito, a mais alta) e `app_settings.pricing.payment_fee_pct` também. Pedidos antigos não foram reescritos (não havia pedidos). A taxa real por método entra na confirmação do pagamento na Etapa 6 (hoje `mp_registrar_pagamento` não toca na taxa) |
| Sem trava de lucro | Triggers: `order_items` recusa preço abaixo do piso duro; `orders` recusa desconto que leva a prejuízo; `orcamento_itens` e `orcamentos` recusam piso duro e envio com prejuízo. Pagamento confirmado nunca é bloqueado (as travas olham preço e desconto, não status) |
| Catálogo sem SKU próprio | `products.code` já é único por opção. `orcamento_itens.sku` é obrigatório e precisa existir no catálogo. Para `order_items` a exigência fica atrás de `parametros_comerciais.exigir_sku_pedidos` (desligada) porque a tela de pedido ainda aceita item digitado à mão; ligar na Etapa 2 junto com a mudança da tela |
| Prazo de entrega sem corte das 12h e sem arte | `orders_set_due_date` passou a usar `private.prazo_data` (corte das 12h, dia de logística, marco = pagamento e arte aprovada). Antes da arte aprovada vale a estimativa pelo pagamento. `app_settings.deadline` (tela Prazos) é copiado para `parametros_comerciais.dias_logistica` por trigger |
| `app_settings.agent` (liga/desliga e horário) x `agente_config` | `agente_config` é a configuração do agente; o botão do topo do CRM continua em `app_settings.agent` até a Etapa 5 ligar os dois. `ia_ligada` nasce falso |
| `anon` com privilégios amplos nas tabelas | A RLS já bloqueava. Os privilégios do `anon` foram revogados em todas as tabelas e visões do schema `public` (e nos padrões de tabelas futuras). Edge Functions usam service role; o front usa JWT do dono |
| Custo legível | `products.cost`, `order_items.unit_cost` etc. só aparecem para o dono (RLS). As funções novas são `SECURITY INVOKER` e não devolvem custo. `piso`, `piso_duro` e lucro saem de `calcular_preco` e `validar_margem` para uso interno: a ferramenta do agente no n8n precisa filtrar esses campos |

## 5. Pendências que dependem do dono

Ver "O que revisar" em `docs/agente/progresso.md`.
