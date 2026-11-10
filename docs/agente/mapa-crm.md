# Mapa do CRM (Etapas 1 a 5)

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

**Orçamento em PDF:** `orcamentos.itens_exibicao` e `orcamentos.alternativas` (exibição consolidada e quadro de alternativas, migration `20261106000001`).

**Mensagens:** `messages.type` aceita text, image, document, audio, video, sticker, location, contacts, reaction, template e other; colunas `reply_to_wa_id`, `meta`, `forwarded`, `sent_by`, `deleted_at` (apagada só no CRM). `whatsapp-send` ganhou `action` (delete, restore, react), `reply_to` e anexos de vários tipos.

**Edge Functions**: `whatsapp-webhook`, `whatsapp-send`, `whatsapp-sync-templates`, `whatsapp-media`, `admin-create-agent`, `meta-ads-sync`, `mp-webhook`, `mp-criar-link`, `mp-conferir`, `orcamento-pdf`, `conhecimento`, `produto-fotos` (Etapa 4B). O webhook da Meta é único e continua sendo o `whatsapp-webhook`.

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

## 9. Etapa 4B: fotos de produto

Antes: o CRM não guardava nenhuma imagem de produto. Agora: tabelas `produto_fotos`, `produto_fotos_grupos`, `produto_fotos_envios`; bucket privado `produto-fotos`; funções `foto_resolver_grupo`, `foto_estado_grupo`, `foto_limites`, `foto_registrar`, `foto_decidir`, `foto_fechar_busca`, `foto_registrar_envio`, `foto_aprovadas`, `fotos_painel`, `fotos_grupos_para_aquecer` (todas em `public`, com checagem interna de dono ou servidor); `app_settings.fotos` (origem, cache, aquecimento, verificação de marca, limites); Edge Function `produto-fotos`; tela Catálogo > Fotos; trecho de conhecimento `foto-produto`; 2 workflows no n8n. Ver `docs/fotos-de-produto.md`.

## 10. Etapa 5: agente de atendimento

**Passo 0 (como o CRM gravava a entrada):** `whatsapp-webhook` (único receptor da Meta) valida a assinatura e chama `ingest_inbound_message` (atômica e idempotente por `wa_message_id`, devolve o id da mensagem ou `null` se duplicada). Conversa nova nasce com `ai_handled = false` (modo humano); `contacts.first_referral` e `conversations.last_referral` guardam o anúncio; `optout` é coluna gerada de `marketing_consent`. Nenhum webhook novo na Meta: o receptor passou a avisar o n8n.

| Ponto | Antes | Agora |
|---|---|---|
| Acionar o agente | nada | `whatsapp-webhook` chama o webhook do WF1 (segredos `N8N_WF1_URL` e `N8N_WF1_TOKEN`), só com o id da mensagem, depois do tratamento de PARAR; sem segredo não faz nada |
| Enviar como agente | `whatsapp-send` exigia JWT de atendente | nova `agente-enviar` (só service role; confere IA, modo humano, pedido pago e janela) |
| Baixar mídia no n8n | `whatsapp-media` só para atendente | também aceita a service role |
| IA ligada | botão do topo (`app_settings.agent.enabled`) e `agente_config.ia_ligada` separados | o agente só responde com **os dois** ligados |
| Conversa nova | modo humano | a IA assume o primeiro contato (sem troca de atendente e sem resposta enviada) |
| Resposta a follow-up | n/d | volta para a IA (salvo dono no comando ou pagamento em andamento) e cancela lembretes pendentes |

**Novo:** tabela `agente_execucoes`; colunas em `agente_config`; 23 funções `agente_*` (lista em `docs/agente-ia.md`); 21 cenários `e5-*` em `testes_conversa`; função `agente-enviar`; 9 workflows no n8n (`docs/n8n-mapa.md`). Migration `20261101000001_etapa5_agente.sql` (cópia em `docs/agente/aplicar-etapa5.sql`). Testes: `supabase/tests/agente_etapa5.sql` (96) e `npm run test:agente`.



## Etapa 6: alertas ao dono, PWA e pós-pagamento
- **PWA:** `public/manifest.webmanifest`, `public/sw.js` (cache do casco, `push`, `notificationclick`), `public/offline.html`, ícones em `public/icons/` (gerados de `public/favicon.svg` por `scripts/gerar-icones-pwa.cjs`, incluindo 180x180 do iOS e maskable). Meta tags do iOS em `index.html`. O login continua em `localStorage` ("Continuar conectado").
- **CRM:** Configurações > Notificações (`src/features/notifications/NotificationsTab.tsx`, `src/lib/push.ts`, `src/hooks/alertas.ts`). Layout: selo de pendências, abertura do pedido ou da conversa ao tocar, aviso marcado como lido ao abrir.
- **Banco** (migration `20261101000004`): `push_subscriptions`, `pagamento_pos`, `app_segredos`; `alertas` ganhou chave, dados, status e tentativas por canal e `lido_em`; `app_settings.notificacoes`. Funções (só service role): `alerta_criar`, `alertas_proximos`, `alerta_resultado`, `alertas_resumo_montar`, `alertas_varredura`, `alerta_destino_dono`, `pagamento_pos_pendentes`, `pagamento_pos_processar`, `pagamento_pos_reservar_msg`, `pagamento_pos_msg_resultado`. `agente_chamar_dono` passa por `alerta_criar`; `agente_bloqueio` ignora o número do dono. Gatilhos: `pagamentos_alertas` (estorno e outros) e `messages` (nova mensagem em modo humano).
- **Edge Functions:** `alertas-enviar` (processar: service role; teste e chave_publica: dono logado) e `cliente-pago-avisar` (service role). Ambas com `verify_jwt = false` e conferência própria.
- **n8n:** `GBH | WF5 | Pagamento e alertas` e `chamar_dono` atualizado.

## Etapa 7: follow-ups, status do pedido, painel de pedidos e observabilidade
**Passo 0:** já existiam `followup_regras` e `followup_fila` (Etapa 1), `agendar_followup` do agente (Etapa 5), `orders.subestatus_pedido` (coluna sem uso), `orders` e `order_events`, o kanban e o botão Pausar IA. Nada foi duplicado: as tabelas foram estendidas e as duas visões (Kanban e Pedidos) leem `useOrders`.

| Ponto | Antes | Agora |
|---|---|---|
| Envio de follow-up | fila sem consumidor | `followup_agendar`, `followup_reservar`, `followup_montar`, `followup_resultado`; WF6 e WF7; Edge Function `proativo-enviar` |
| Subestatus | coluna `subestatus_pedido` sem uso | `em_producao`, `pronto_retirada`, `saiu_entrega` (constraint); botões no cartão e no detalhe; `pedido_avisos` (um aviso por pedido e tipo) |
| Entregue | só mover o cartão | `pedido_marcar_entregue` e gatilho `orders_entregue_agenda` (satisfação e recompra) |
| Lista de pedidos | só kanban | `/pedidos` (abas, filtros, lote, CSV, lista para o fornecedor) |
| Enviado à fábrica | não existia | `orders.enviado_fabrica_em`, `fornecedor_lista_pendente`, `fornecedor_marcar_enviado` |
| Erros e custo | sem fluxo de erro | `agente_erro_registrar`, `observabilidade_checar`, WF9; `app_settings.observabilidade` e `app_settings.followup`; `app_settings.retirada` |
| Painel do agente | sem métricas | `painel_agente(de, ate)`; Painel > Agente |

**Telas novas:** Pedidos (`src/pages/Orders.tsx`), `src/features/orders/StatusPedido.tsx`, `src/features/agent/FollowupsTab.tsx`, `src/features/agent/AgentPanel.tsx`, hooks em `src/hooks/etapa7.ts`. **Tempo real:** `pedido_avisos` e `followup_fila` no `useRealtimeSync`.
**Parâmetro alterado:** `parametros_comerciais.validade_orcamento_horas` 48 para 168.

## Etapa 7B, Bloco A
**Novo:** colunas em `orders` (`parcelas`, `taxa_fonte`, `taxa_pagamento_real_valor`, `liquido_recebido`, `urgente*`, `excluido_*`, `arquivado_em`, `cancelado_*`, `reembolso_pendente`), em `contacts` (`urgente*`) e em `parametros_comerciais` (`parcelas_sem_juros_max`, `parcela_adicional_pct`); tabelas `pedidos_auditoria` e `erros_operacao`; funções `pagamento_taxa_real`, `orcamento_lucro_por_metodo`, `pedido_excluir`, `pedido_cancelar_ou_arquivar`, `pedido_esta_atrasado`, `pedidos_atrasados`, `registrar_urgencia`, `pagamentos_divergencias_checar`, `private.erro_tipo`. **Alteradas:** `private.taxa_pagamento(metodo, parcelas)`, `calcular_preco` (ignora método), `confirmar_pagamento_manual(order, metodo, parcelas)`, `agente_erro_registrar` (tipos e ações). Telas: Novo pedido e Confirmar pagamento exigem método; Pedido > Zona de risco; selo URGENTE; atrasado só em produção; Orçamentos mostra taxa e lucro por método.

## Etapa 7B, Bloco B
**Novo:** `conversations/tasks/alertas.setor`, `orcamentos.motivo_perda`, tabelas `estrategia_recuperacao`, `oportunidades_bauerlab`, `orcamento_opcoes`, `cupons_recompra`, view `opcoes_conversao`, `app_settings.bauerlab` e `.cupom_recompra`; funções `agente_encaminhar_setor`, `agente_promessas_indevidas`, `agente_bauerlab`, `orcamento_registrar_perda`, `recuperacao_proximo_passo`, `pedido_pendencias`, `montar_opcoes`, `orcamento_opcao_escolher`, `cupom_recompra_emitir/aplicar/simular`, `private.mensagem_incompleta`. **Alteradas:** `agente_debounce(msg, esperar)`, `agente_salvar_contato`, `agente_saida_segura`. Conhecimento: 10 trechos (fonte `Etapa 7B`).

## Etapa 7B, Blocos C e D
**Novo:** `catalogo_formulas`, `produtos_complementares`, `melhorias_sugeridas`, `experimentos`, `experimento_grupos`, `indicacoes`, `contacts.codigo_indicacao`, view `atribuicao_pedidos`; funções `painel_comercial`, `rentabilidade_cliente`, `complementar_sugerir`, `estudo_diario_coletar`, `melhoria_decidir`, `experimento_variante/resultado`, `indicacao_codigo/registrar`, `private.custo_por_dimensao`.

## Etapa 7C: conhecimento v2, personas e fila da arte
**Novo:** `conhecimento.usos/ultimo_uso_em/substituido_por`, `conhecimento_sugestoes`, `cupons_recompra.beneficio`, `orders.arte_fila_em/arte_qualidade/arte_baixa_ok_em/arte_resumo/arte_ultimo_alerta_em/arte_aprovada_registro`, `order_files.qualidade`, `app_settings` (`personas`, `politica`, `parcelamento`, `arte`, `cupom_recompra.teto_reais`). Funções: `agente_persona`, `arte_receber`, `arte_baixa_ok`, `arte_aprovar`, `arte_fila`, `arte_varredura`, `agente_encaminhar_arte`, `politica_texto`, `conhecimento_criar_de_lacuna`, `conhecimento_sugestao_decidir`, `conhecimento_reverter_importacao_7c`. Embrulhadas (corpo original em `*_base`): `agente_contexto`, `agente_entrada`, `pagamento_pos_reservar_msg`, `pagamento_pos_processar`. Substituídas: `agente_bloqueio`, `agente_saida_segura`, `conhecimento_resolver`, `buscar_conhecimento`, `cupom_recompra_aplicar`, `private.conhecimento_score_texto`. Telas: Fila da arte (`/arte`), Configurações > Personas e política, Conhecimento (usos, lacunas, sugestões).

## Etapa 8 (auditoria)
`agente_config.piloto_ativo`, `piloto_wa_ids`, `piloto_percentual` (modo piloto usado por `agente_bloqueio`, retorna `fora_do_piloto`). `private.order_items_validar` usa o custo do catálogo no caminho do CRM. Gatilhos de pedido e orçamento que chamam `taxa_pagamento` agora são `SECURITY DEFINER`. Relatório: `docs/auditoria-agente.md`.

### Etapa 8 (complemento)
`produto-opcoes` (Edge Function, sem JWT, dono ou service role): manda abertura + uma mensagem por opção, com foto e ficha traduzida; chamada pela ferramenta `enviar_foto_produto` com `opcoes: <produto>; <quantidade>`. `buscar_produto` devolve `em_palavras` e `quantidades_disponiveis`. `private.traduzir_especificacao`, `private.categoria_bate`, `private.wa_variantes`. `orcamento_marcar_enviado` cria o card em "cotando". `preparar_link_pagamento` exige PDF formal enviado. `agente_bloqueio` aceita piloto por número e por percentual, e contatos com tag `teste`.


## Etapa 8B: teste ponta a ponta do atendimento
- **Código:** `tests/e2e/` (cenários, personas, verificações, juiz, executor, retratos). `npm run e2e` (completo, `--critico`, `--categoria`, `--cenario`) e `npm run test:e2e` (autoteste offline, dentro do `npm test`). Protocolos sem chave de serviço: `PROTOCOLO-RETRATOS.md` e `PROTOCOLO-JUIZ.md`.
- **Banco (aditivo):** `contacts.is_teste`; `e2e_mensagens`; `agente_teste_preparar` aceita `continuar_conversation` e o preparo `optout`; `e2e_criar_caso`, `e2e_snapshot`, `e2e_aguardar`, `e2e_apagar_casos`, `e2e_limpar` (só apaga `is_teste`), todas só para `service_role`. `agente_debounce` com espera extra máxima de 5 s.
- **Docs:** `docs/agente/e2e-relatorio.md`, `e2e-liberacao-gradual.md`, `e2e-roteiro-manual.md`, `e2e-prompt-wf2-ciclo1.md`.

## MVP final (03/11/2026)
- `app_settings.orcamento_agente` (`valor_alerta` 10000, `unidades_max` 50000, `pacotes_max_linha` 100) comanda os limites de `montar_orcamento`; a chave `valor_max_agente` (trava de R$ 5.000) foi removida.
- `parametros_comerciais.markup_minimo_bloco` (R$ 1,80): piso por bloco no preço sem mercado (`calcular_preco`).
- Alerta `orcamento_valor_alto` (categoria própria em `private.alerta_categoria`, só WhatsApp, respeita o silêncio noturno).
- `orcamentos.itens_exibicao` passa a ser preenchido por `montar_orcamento` quando o mesmo produto vem em sub-lotes.
- n8n `pesquisar_preco_mercado`: só SearXNG e Playwright.

## E-commerce Fases 1 e 3 (09/11/2026)
- **Preço:** `calcular_preco` lê `catalogo.preco_venda` (planilha oficial). Fórmula antiga em `private.calcular_preco_mercado`, usada só para SKU sem preço ou com `parametros_comerciais.fonte_preco = 'mercado'`. Novos parâmetros: `fonte_preco`, `lucro_bruto_minimo`.
- **Carga:** `planilha_precos_import` (staging privada), `importar_precos_planilha`, `aplicar_planilha_precos_lote`, `aplicar_planilha_precos`, `planilha_precos_relatorio`, `private.sku_planilha`, `private.pode_importar_precos` (dono, service role ou token de 2 h em `app_segredos`).
- **Vitrine:** `ecommerce_products` (leitura pública, sem a coluna `sku`), `ecommerce_sincronizar`, `private.ecommerce_sincronizar_interno`, `private.ecommerce_sincronizar_skus`, tradutores `private.cores_rotulo`, `private.formato_rotulo`, `private.titulo_vitrine`, `private.slugify`.
- **Front do CRM:** `src/features/catalog/PlanilhaPrecosImport.tsx`, `src/lib/planilha-precos.ts`.
- **Loja:** `ecommerce/` (Next.js). Ver `docs/ecommerce.md`.
- **n8n:** `montar_orcamento` sem pesquisa de mercado; `pesquisar_preco_mercado` despublicado.

## E-commerce Fase 2 (09/11/2026)
- `loja_fichas` (fila por produto, privada), `loja_fichas_pegar`, `loja_ficha_gravar` (só service role), `loja_fichas_resumo`, `private.loja_chave`, gatilho `ecommerce_titulo_da_ficha` em `ecommerce_products`, bucket público `loja-produtos`, agendamento `loja-fichas`, configuração `app_settings.loja_fichas`.
- Edge Function `loja-fichas` com `_shared/ficha-origem.ts` e `_shared/marca.ts`.

## E-commerce Fase 4 (09/11/2026)
- Funções públicas (anon): `loja_buscar`, `loja_cotar`, `loja_calcular`. Só service role: `loja_checkout_preparar`. Privadas: `loja_sku`, `loja_arte`, `loja_prazo`, `loja_frete_publico`, `loja_cep_grande_bh`, `loja_palavras_busca`, `loja_tamanho_papel`.
- `ecommerce_products.busca` (gatilho `ecommerce_busca_texto`, índice trigrama). `parametros_comerciais.arte_conferencia_valor`.
- Edge Function `loja-checkout`; validação em `_shared/loja-validar.ts`. Pedidos do site: `orders.origin_label = 'site'`.

## E-commerce Fase 5 (09/11/2026)
- Funções públicas: `loja_categorias`, `loja_produto`, `loja_slugs`. Páginas e componentes em `ecommerce/app` e `ecommerce/components` (Configurador, ModalWhatsApp, CarrinhoIcone, CobrimosBanner, ProdutoCard). Carrinho em `ecommerce/lib/carrinho.ts`.

## E-commerce Fase 6 (09/11/2026)
- `catalogo`: `ncm`, `ncm_revisar`, `unidade`, `origem_mercadoria`. `fiscal_ncm_regras` + `fiscal_aplicar_ncm`.
- `contacts`: `tipo_pessoa`, `ie_indicador`, `inscricao_estadual`, `logradouro`, `numero`, `complemento`, `municipio`, `uf`, `codigo_ibge`, `bling_contact_id`.
- `orders`: `canal` (gatilho `orders_canal_site`), `marketplace_pedido_id`, `bling_pedido_id`, `bling_enviado_em`, `bling_erro`.
- `bling_pedido_payload`, `bling_eventos`, view `catalogo_marketplace` (`private.preco_marketplace`), `app_settings.bling` e `app_settings.marketplaces`. Edge Function `bling-webhook`. Script `scripts/enrich-marketplace-ads.ts`.

## E-commerce Fase 7 (09/11/2026)
- `meta_eventos` (fila), `meta_evento_registrar` (anon), `meta_eventos_lote` e `meta_eventos_resultado` (service role), `private.sha256`, gatilho `meta_purchase_do_pedido` em `orders`, `app_settings.meta_capi`, agendamento `meta-conversions`. Edge Function `meta-conversions-api`. Loja: `lib/meta.ts`, `components/MetaPixel.tsx`, `Consentimento.tsx`, `ViewContent.tsx`, rota `/api/v1/eventos`.

## E-commerce Fase 8 (09/11/2026)
- `blog_fontes`, `blog_pautas`, `blog_posts` (RLS dono), `loja_blog_lista`, `loja_blog_post`, `loja_blog_slugs` (anon, só publicados), `app_settings.blog`, agendamento `blog-pautas`. Edge Function `blog-pautas` (+ `_shared/blog.ts`). CRM: `src/features/catalog/BlogTab.tsx` (Catálogo > Blog do site). Loja: `lib/blog.ts`, `lib/ajuda.ts`, `components/PostCorpo.tsx`, `components/AjudaCentral.tsx`, páginas `/blog`, `/blog/[slug]`, `/ajuda`. Detalhes em `docs/blog.md`.

## E-commerce Fase 9 (09/11/2026)
- Tabelas: `cep_bairros` (cache CEP -> bairro, só service role), `carrinhos_abandonados` (RLS equipe) e a view `v_carrinhos_recuperar`. Funções: `verificar_frete` (CEP em cache vale pelo bairro e cidade BH; sem cache, faixa antiga), `loja_frete_base` (service role), `loja_carrinho_salvar` (anon), `loja_carrinho_fechar` (service role), `loja_pedido_status` (anon, por UUID). `orders.delivery_method` aceita `correios`.
- Edge Functions: `loja-frete` (nova), `loja-checkout` (Pix direto, envio, `acao: "pagar"`); módulos `_shared/loja-frete.ts` e `_shared/mp-pix.ts` (testados em `npm run test:loja`).
- Loja: `/checkout` (`CheckoutCliente.tsx`), carrinho enxuto, rotas `/api/v1/frete`, `/carrinho`, `/checkout/pay`, `/pedido/status`. Site na Hostinger: ver `docs/ecommerce.md` (Output Directory `.next`).

## E-commerce Fase 10 (10/11/2026)
- Segurança: `calcular_acabamento_seguro` só para `service_role` (migration `20261123000001`); `ecommerce/package.json` com `overrides.postcss`. Sem tabela, função ou rota nova.


## Fase 11 (10/11/2026)
- `conversations.brain` (jsonb) = cérebro da Laura: itens, orçamento, assunto atual e recentes, dúvidas pendentes. Escrito por `private.cerebro_recalcular` (chamado em `agente_entrada`), lido em `agente_contexto` (`cerebro`). `agente_cerebro_atualizar(uuid)` força o recálculo.
- `orders.stage` ganhou `pronto` (entre `producao` e `entregue`); `ORDER_STAGES` e limite de 48 h no Kanban.
- Novos: `loja_modelos`, `loja_acabamentos`, `acabamentos_extras`; `loja_buscar` e `loja_produto` devolvem `sku`; `loja_produto` devolve `irmaos`.
- CRM: `AvisoCliente` (Kanban), `ReabrirJanela` (ChatPanel), gaveta inferior em `Inbox`, `salvarCliente` em `hooks/orders.ts`.

## Fase 12 (10/11/2026)
- Tabelas (só servidor): `loja_verticais`, `loja_taxonomia`, `loja_subcategorias`, `loja_facetas_def`, `loja_sinonimos`; `private.loja_atributos` (tabela, atualizada por `private.loja_atributos_atualizar`, cron `loja-atributos` a cada 15 min) e `private.loja_atributos_v` (view de origem).
- Funções públicas: `loja_arvore`, `loja_facetas`, `loja_modelos_f`, `loja_interpretar_busca`. Rotas da loja: `/api/v1/taxonomia`, `/api/v1/facetas`, `/api/v1/modelos`. Componentes: `Filtros.tsx`, `MenuLateral.tsx` (por verticais), `Header.tsx` (mega menu). `lib/departamentos.ts` foi removido.
