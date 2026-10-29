# Mapa do CRM (Etapas 1 a 4)

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

## 6. Etapa 2: catálogo, SKU e conhecimento (28/10/2026)

**Funcionalidade que já existia (Passo 0):** Catálogo e Kits > Catálogo do fornecedor > "Importar planilha". Parser em `src/lib/spreadsheet.ts` (Excel, CSV e HTML `.xls`; PDF recusado). Tabela `products` (20.381 linhas, 140 categorias; `code` único = SKU, `weight` em gramas, `size` texto em mm, `lead_days` bruto, `suggested_price` = custo x multiplicador único, hoje 0). `upsert` por `code` em lotes de 500, último vence, linha sem código descartada.

**O que mudou** (detalhes e as 11 lacunas em `docs/catalogo-e-sku.md`):

| Antes | Agora |
|---|---|
| `products` | `catalogo` (mesmos ids). `products` e `products_priced` seguem como visões de compatibilidade |
| `code`, `description`, `category`, `cost`, `colors`, `weight`, `qty`, `size`, `lead_days`, `grammage`, `suggested_price` | `sku`, `descricao`, `categoria`, `custo`, `cores`, `peso_g`, `quantidade`, `tamanho_mm`, `prazo_dias_uteis`, `gramatura_g`, `preco_base_custo` (referência, sem pesquisa) |
| (nada) | `grupo_produto`, `especificacao_normalizada`, `status_venda`, `vendavel`, `cabe_na_bike`, `maior_lado_mm`, `piso`, `piso_duro`, `chave_natural`, `origem_importacao_id`, `atualizado_em` |
| `order_items.code` livre | `order_items.code` é o SKU: chave estrangeira para `catalogo.sku` (`NOT VALID`) e obrigatório para registros novos |
| `kit_items` por `product_id` | também `sku` (visão `kit_itens`) |
| `conhecimento` (vazia, vetor 768) | formato do vendedor (`resposta_pronta`, `fatos`, `proximo_passo`...), vetor 384 (`gte-small`), 90 trechos, `conhecimento_lacunas`, `conhecimento_consultas`, `faq_cache` |

**Novo:** tabelas `catalogo_historico`, `catalogo_importacoes`, `catalogo_import_linhas`, `sinonimos`, `qualificacao_perguntas`, `itens_fora_catalogo`; bucket privado `catalogo-fornecedor`; funções `catalogo_importacao_iniciar/lote/previa/aplicar`, `catalogo_atualizar_competitividade`, `catalogo_recalcular`, `catalogo_definir_sku`, `catalogo_precos`, `buscar_produto`, `agente_preco`, `registrar_item_sem_sku`, `kit_preco`, `pedido_para_fabrica`, `sinonimos_carregar_categorias`, `buscar_conhecimento`, `conhecimento_resolver`, `conhecimento_taxa`; Edge Function `conhecimento`; agendamento `conhecimento-reindexar` (5 em 5 minutos).

**Funções da Etapa 1 alteradas:** `calcular_preco` (recusa item não vendável; ignora coleta de mercado invalidada), `verificar_frete` ("0 x 0" é dimensão desconhecida), `private.orcamento_itens_validar` (item precisa ser vendável), `private.orders_before_update` (Produção exige SKU em todos os itens; Pago sem SKU alerta).

**Telas:** Catálogo (SKU com copiar, base de custo, preço de venda, status, bike, filtro de status, Recalcular pisos, aba Sem código), importação em duas fases, Kits (lista de SKUs, preço de `kit_preco`), Pedido (SKU em destaque, preço de `calcular_preco`, aba Pedido para a fábrica), cartão do kanban (SKUs), Configurações > Conhecimento.

**Preço no CRM (decisão padrão aplicada):** a coluna do catálogo é "Base de custo (ref.)", visível só ao dono. Orçamento (pedido), kit e catálogo leem `calcular_preco`. Nenhum orçamento, PDF ou link usa `preco_base_custo`.

## 7. Etapa 3: estado parcial (não aplicada)

Na branch `feat/agente-etapa3-preco`, a migration `20261029000006_etapa3_preco_inteligente.sql` cria a infraestrutura para pesquisa sob demanda: `consultas_preco_mercado`, fonte normalizada e expiração em `precos_mercado`, `fatores_competitivos`, `ajustes_fator_preco`, atualização de `calcular_preco`, sincronização de `precos_praticados`, `aprender_precos_semana()` e a visão interna `saude_precos`.

O front ganhou as abas **Catálogo > Saúde de preços** e **Configurações > Política de desconto**. Nada disso está em produção nem foi validado contra o Supabase. Os workflows n8n, SearXNG, PDF/link renovado, expiração, alertas, relatórios e testes finais continuam pendentes.

## 7. Etapa 3: autoridade do preço (Passo 0, 28/10/2026)

Cada ponto do CRM que exibe ou grava preço, e o que fazer com ele. Regra: **o único preço que chega ao cliente (orçamento, PDF, link de pagamento, mensagem) é o de `calcular_preco`**; o que não vem dela é interno e rotulado.

| Ponto do CRM | O que mostra ou grava | Decisão |
|---|---|---|
| Catálogo > coluna "Base de custo (ref.)" (`preco_base_custo`) | custo x multiplicador, sem pesquisa | **Rotulada** "base de custo, sem pesquisa". Só o dono vê; nunca usada em orçamento, PDF ou link |
| Catálogo > coluna "Preço de venda" e "Piso" | `catalogo_precos` > `calcular_preco` | **Lê `calcular_preco`** (Etapa 2). Só o dono vê o piso |
| Catálogo > Saúde de preços (nova) | cobertura de mercado, margem, conversão, fator por grupo, fontes de cada preço, não competitivos, condições, resumo semanal | Interna (RLS só dono). Nenhum custo ou piso sai dela para o cliente |
| Kits (`kits.price`) | preço do kit | **Lê `kit_preco`** (calcular_preco por SKU, nunca abaixo do piso do conjunto). Valor digitado não existe mais |
| Pedido > Itens > adicionar item pela busca | preço sugerido | **Lê `calcular_preco`** (regra e confiança aparecem na origem do item) |
| Pedido > Itens > editar preço à mão | `order_items.unit_price` | **Novo:** mostra o lucro líquido e a faixa; abaixo do piso duro **bloqueia** (nem o dono aprova); entre o piso duro e o piso **só com confirmação do dono e motivo**, gravados em `precos_manuais_log` e no pedido (`price_override_reason`); gatilho de banco impede reduzir abaixo do piso por qualquer outro caminho do CRM |
| Pedido > desconto, imposto e taxa (percentuais) | `orders.discount_pct` etc. | Trava existente da Etapa 1 (desconto que leva a prejuízo é recusado). Desconto comercial ao cliente só nasce de `oferecer_condicao_especial` |
| Cartão do kanban, painel, contatos, inbox | valor total do pedido (`order_financials`) | Só exibição do que já foi vendido; não gera preço |
| Orçamento (`orcamentos`, `orcamento_itens`) | preço por item, regra, confiança, margem | Grava o que `calcular_preco` devolveu, mais (colunas novas) fonte do mercado, `nao_competitivo`, piso, piso duro e lucro. Triggers recusam piso duro |
| Configurações > Preços (`app_settings.pricing`) | alertas de piso e desconto máximo da tela do pedido | Continua só como **alerta visual** do CRM (a regra de verdade está em `parametros_comerciais` e nas funções) |
| Configurações > Política de desconto | `politica_desconto` | **Novo:** edita degraus, percentuais, teto em reais, fração da gordura, validade, intervalo e grupos sem desconto; mostra a simulação do pior caso e recusa configuração com prejuízo |
| `aplicar_desconto` (função e ferramenta antiga) | - | **Removida** (não havia dados para migrar). Substituída por `oferecer_condicao_especial` |

**Tabelas e funções novas (migrations 20 e 21):** `fatores_competitivos`, `ajustes_fator_preco`, `consultas_preco_mercado`, `fontes_pesquisa`, `precos_manuais_log`; colunas novas em `parametros_comerciais`, `precos_mercado`, `precos_praticados`, `condicoes_especiais`, `orcamento_itens`; view `saude_precos`; funções `consultar_cache_preco_mercado`, `registrar_pesquisa_mercado`, `reservar_acesso_dominio`, `aprender_precos_semana`, `oferecer_condicao_especial`, `condicao_registrar_link`, `expirar_condicoes_e_orcamentos`, `detectar_padroes_desconto`, `relatorio_condicoes_semana`, `resumo_semanal_precos`, `simular_politica_desconto`, `salvar_politica_desconto`, `definir_grupos_sem_desconto`, `definir_preco_item_pedido`, `skus_para_aquecer`; `calcular_preco`, `agente_preco`, `calcular_condicao_especial` e `validar_margem` substituídas (mesmos nomes e retornos compatíveis). Agendamento `condicoes-expirar` (10 em 10 minutos).

**n8n:** 4 workflows `GBH |` desativados (ver `docs/n8n-mapa.md`).

## 8. Etapa 4: orçamento em PDF (29/10/2026)

**Passo 0:** `orcamentos` e `orcamento_itens` já existiam (Etapa 1, com as travas de lucro); não havia PDF de orçamento. Estendi as tabelas, sem recriar nem renomear nada.

| Ponto | Antes | Agora |
|---|---|---|
| Montagem do orçamento | linhas soltas gravadas por funções da Etapa 3 (condição especial) | `montar_orcamento(contato, SKUs, opções)`: `calcular_preco`, `calcular_prazo`, `verificar_frete`, `validar_margem`, arte, upsell por regra; JSON mínimo ao agente |
| PDF | não havia | Edge Function `orcamento-pdf` (Gotenberg), bucket privado `orcamentos`, `orcamento_documento` (só dados públicos) |
| Link de pagamento | `mp-criar-link` por pedido | mesma função; antes, `preparar_link_pagamento` (`validar_margem`, vencido, SKU, valor do pedido = valor do orçamento) |
| Taxa do método | prevista (`metodo_previsto`, cartão se desconhecido) | prevista no preço; **real** gravada no pedido ao pagar (`taxa_pagamento_real_pct`, `lucro_liquido_real`) |
| Pedido do orçamento | criado à mão pelo dono | criado por `orcamento_para_pedido` na hora do link (arte vira item "Criação de arte", desconto vira `discount_pct`) |
| Tela | sem orçamentos | Pedido > aba Orçamentos; status do orçamento no cartão do kanban |

**Colunas novas:** `orcamentos` (`frete_modo`, `upsell_tipo`, `upsell_texto`, `data_prevista`, `custo_total`, `avisos`, `pdf_hash`, `pdf_gerado_em`, `pdf_enviado_em`, `link_pagamento_expira_em`), `orcamento_itens.especificacao`, `parametros_comerciais.validade_orcamento_horas`, `orders.taxa_pagamento_real_pct` e `orders.lucro_liquido_real`.

**Funções novas:** `montar_orcamento`, `orcamento_documento`, `orcamento_renovar`, `preparar_link_pagamento`, `orcamento_registrar_link`, `private.orcamento_para_pedido`, `private.upsell_regra`, `private.especificacao_publica`, `private.orcamento_numero`. Substituídas (mesmos nomes e retornos): `validar_antes_de_cobrar`, `private.confirmar_pagamento`.

**n8n:** `GBH | FERRAMENTA | montar_orcamento`, `gerar_pdf_orcamento`, `gerar_link_pagamento`, `GBH | WF3 | Orçamento PDF` (desativados). Ver `docs/n8n-mapa.md`.
