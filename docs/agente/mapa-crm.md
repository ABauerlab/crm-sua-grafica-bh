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

## E-commerce Fases 1 e 3 (09/11/2026)- **Preço:** `calcular_preco` lê `catalogo.preco_venda` (planilha oficial). Fórmula antiga em `private.calcular_preco_mercado`, usada só para SKU sem preço ou com `parametros_comerciais.fonte_preco = 'mercado'`. Novos parâmetros: `fonte_preco`, `lucro_bruto_minimo`.
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

## Fase 13 (10/11/2026)
- Banco: `loja_desagrupar` (+ gatilho `zz_loja_desagrupar` em `ecommerce_products`), `private.loja_familias` (+ view `_v`), `private.loja_facetas_cache`; funções `loja_familia`, `loja_facetas_home`; `loja_modelos_f`, `loja_facetas` e `loja_arvore` reescritas. Crons `loja-atributos` e `loja-facetas-home`.
- Edge Function `loja-arquivo` (PDF da arte no checkout; grava em `order-files` e `order_files`, art_status `enviada`). Loja: `/opcao/[familia]`, `BarraLateral`, `ListaModelos`; `lib/departamentos.ts` e a paginação saíram.


## E-commerce/CRM Fase 16 (11/11/2026)
- `orders.origin_label = 'ecommerce'` e `orders.canal = 'ecommerce'` identificam pedidos do checkout. `site` permanece como valor legado e também é classificado como E-commerce. `loja-checkout`, `loja_checkout_preparar`, `loja_pedido_status` e `validar_antes_de_cobrar` mantêm compatibilidade.
- Kanban `/kanban`: filtro rápido por Todos os Pedidos, WhatsApp (Laura) e E-commerce / Site; os pedidos seguem as mesmas colunas `ORDER_STAGES`.
- Catálogo: `loja_modelos_f` lista um card por `produto_slug`; `variacoes` conta SKUs/tiragens. `loja_facetas`, `loja_arvore` e cache da home contam o mesmo agrupamento. `loja_produto` complementa a ficha com `material_catalogo`, `gramatura_g`, `codigo_cores` e `acabamentos_catalogo`.
- Loja: `ModeloCard` abre diretamente a página da variação; `/opcao/[familia]` permanece para compatibilidade. `CategoriasPage` adiciona atalhos às cinco categorias principais.

## Fase 17: loja por SKU (11/11/2026)
- `ecommerce_products` ganhou `sku_slug` e `variante`; funções `loja_sku_*`; `buscar_produto` devolve `link_produto`. Loja: `ecommerce/components/ModeloCard.tsx` (card por SKU), `ecommerce/app/produto/[slug]/page.tsx` (página do SKU), `ecommerce/lib/vitrine.ts` (`skuProduto`, `skuSlugs`). CRM: `src/features/catalog/ProductsTab.tsx` (lista com altura mínima).


## Fase 3 (15/11/2026): busca de produto rápida e recuperação
- Banco: `private.categoria_norm` (cache) e `private.categoria_bate` reescrita; `buscar_produto` sem `link_produto` e rápida (migration `20261201000003`). `holidays` ganhou o escopo `minas_gerais` e 2028 (`20261201000004`).
- n8n: `GBH | FERRAMENTA | buscar_produto` com busca de reserva e `em_palavras` (cópia em `n8n/GBH-FERRAMENTA-buscar_produto.json`); `despachar` com motivo real da falha; WF2 com regras 25 a 28.
- Edge Function `cliente-pago-avisar` v12 com a nova mensagem pós-pagamento.
- CRM: Configurações > Agente de IA mostra o estado real; Prazos e feriados mostra o escopo.

### Envio de pedidos pagos ao Bling (15/11/2026)
- Edge Function `bling-integracao` (ações `status`, `url_autorizacao`, `trocar_codigo`, `descobrir_loja`, `ativar`, `enviar`, `processar`; cron `bling-enviar` a cada 2 min, só envia com `app_settings.bling.ativo = true`). Lógica pura em `_shared/bling-envio.ts`; testes em `npm run test:bling`.
- Bloqueios reais: `pedido_nao_pago`, `pedido_nao_encontrado`, `ncm_de_item`. As demais lacunas fiscais viram aviso e o pedido segue.
- `orders.bling_pedido_id` e `contacts.bling_contact_id` são bigint; `bling_resultado` converte o texto antes de gravar.
- Itens manuais (sem SKU, fora da arte) viram produto `SG<número>-<n>` no Bling com NCM sugerido por palavra-chave (`ncmSugerido`): conferir antes de emitir a nota.
- Contato: usa o documento quando existe; senão o nome provisório "Cliente WhatsApp <final do telefone>" e o código `SG-xxxx`; se o Bling disser que o código já existe, o contato é reaproveitado pela pesquisa do código.
- Envio idempotente: antes de criar, consulta `GET /pedidos/vendas?numerosLojas[]=<número>` e só reaproveita se o `numeroLoja` for exatamente igual.
- Celular: sem o 55, 10 ou 11 dígitos (`celularBling`).


## Rodada de 17/11/2026
- Banco: `agente_pode_enviar_rodada`, `private.resumo_composto`, `alternativa_lote_maior` e `orientacao_quantidade` em `buscar_produto`, regras de follow-up `Q1` e `Q2` (`referencia = conversa_parada`), `mp_movimentos`, `mp_saldo_historico`, `financeiro_mp`, `mp_movimentos_vincular`, cron `mp-extrato-sync` (5 min).
- Funções: `mp-extrato` (dono, service role ou `x-cron-secret`). Telas: Financeiro com extrato do Mercado Pago.
- n8n: WF1 usa `agente_pode_enviar_rodada` e espera a rodada em andamento; WF2 tem o nó `Regras adicionais (rodada 17/11)`.
- **Atenção (17/11/2026):** `public.agente_chamar_dono(uuid,text,text,text)` só liga `conversations.needs_human` e usa gravidade alta para reclamação, cancelamento, estorno/reembolso, defeito, pedido de pessoa ou pagamento não identificado. Falha do agente e trava de saída são avisos baixos e não travam. Migration `20261217000013_atencao_so_em_reclamacao.sql`.

## Diário do tráfego pago (18/11/2026)
`docs/agente/diario-trafego-pago.md` guarda a avaliação diária das conversas reais do anúncio (números, gargalos, melhorias e backlog). Em 18/11 a primeira rodada de correções entrou: `private.followup_orcamentos_abertos` (cron 10 min), `private.fiscal_extrair` (gatilho em `messages`), `private.condicao_fora_padrao_trg`, `private.saida_travas_extra`, `private.saida_repeticao`, aprovação por pagamento em `preparar_link_pagamento`, `agente_config` 6/16 e regras O a W no WF2. Migrations `20261218000001` e `20261218000002`.

## Estudos do dono (18/11/2026)
33 trechos de conhecimento (papéis, acabamentos, arquivo, upsell, kits por segmento, fichas, objeções e urgência honesta) e regras X a AB do WF2. Só banco de conhecimento e prompt; nenhuma função de preço, prazo, frete ou pagamento mudou. Ver `docs/agente/estudos-do-dono-18-11.md`.

## Botão Responder com IA (18/11/2026)
`ia_rascunhos` (leitura só para a equipe), `agente_execucoes.rascunho`, `ia_rascunho_preparar` e `ia_rascunho_salvar`, função `ia-rascunho` (JWT da equipe), gatilho de rascunho no WF1 e regra do modo rascunho no WF2. Ver `docs/agente/ia-responder-botao.md`.


## Kits agregados e link automático (18/11/2026)
`kits_agregados` + `kits_agregados_componentes` (crachá + cordão), `orcamentos.kit_agregado_id/kit_abatimento`, `private.kit_agregado_aplicar`, `public.montar_orcamento` (wrapper de `montar_orcamento_pre_kit`). `orcamento-pdf` envia o link de pagamento em mensagem separada depois do PDF (`link_enviado`). `preparar_link_pagamento` não exige mais aprovação do cliente. UI: `src/features/catalog/KitsAgregados.tsx` (aba Kits do Catálogo). Detalhes em `docs/agente/progresso.md`.


## Checkout próprio (18/11/2026)
`orders.checkout_token`, `checkout_eventos`, `order_items.checkout_extra`; Edge Functions `checkout-dados` e `checkout-mp-processar`; `mp-criar-link` devolve `https://suagraficabh.com.br/pagar/<token>` (kill switch `CHECKOUT_PROPRIO=false`). Página em `ecommerce/app/pagar/[token]` e `ecommerce/components/pagar/`. Ver `docs/checkout-proprio.md`.

## Destravar IA, cobertura de orçamento e lembrete de anúncio (19/11/2026)
Banco: `private.agente_reprocessar_conversa` + gatilhos `conversations_devolvida_limpar` e `conversations_devolvida_reprocessar` (voltar para a IA reprocessa); `public.cobrir_orcamento`, `private.cobertura_processar`, `private.cnpj_valido`, `private.texto_norm`, `cobertura_log`, `app_settings.cobertura`; regra `Q1_ANUNCIO` (`followup_regras.referencia = 'anuncio_parado'`), `private.fu_agendar_anuncio`, `private.fu_texto_anuncio`, `private.desc_publica`; `followup_agendar` e `followup_montar` viraram invólucros de `private.followup_agendar_base` e `private.followup_montar_base`; `public.agente_anexo_pre_pagamento`. n8n: ferramenta `cobrir_orcamento` (WF2 e `despachar`), leitura de anexo com Gemini no WF1 (nós "Anexo: ..."), frase de espera única no WF2, prompt rodada 19/11. Ver `docs/agente/cobertura-orcamento.md`.

Recusa de preço (19/11/2026): regra `Q2_RECUSA` (`followup_regras.referencia = 'recusa_preco'`), `private.fu_resposta_fria`, `private.fu_ultima_cotacao`, `private.fu_texto_tiragens_menores`, `private.fu_agendar_recusa`; `followup_montar` anterior em `private.followup_montar_pre_recusa`. Teste `supabase/tests/recusa_preco_tiragens.sql`.

- Checkout `/pagar`: `ecommerce/components/pagar/{Quantidades,Cupom,FreteCep,BuscaProdutos}.tsx`; banco `20261220000001_checkout_cupom_frete_quantidades.sql`; ações `cupom`, `cupom_remover`, `frete_cotar`, `frete_definir` em `checkout-dados`.
## Plano de Ação, Fase 1 (20/11/2026)
- `calcular_preco` ganhou os parâmetros `piso_sem_lucro_minimo` e `preco_minimo_reais` (piso de R$ 65 validado por pedido composto, não por item); `private.montar_orcamento_base` e `private.confirmar_pagamento` (fecha `pagamentos_alertas` abertos) atualizadas. Migration `20261222000002` e `20261222000003`.
- `private.fu_nome` devolve `null` (não mais `'cliente'`); `followup_montar_base`, `fu_texto_q`, `fu_texto_anuncio`, `fu_texto_tiragens_menores` tratam a saudação sem nome; PAG_6H corrigido ("fechamento do seu pedido"). Migration `20261222000003`.
- `carrinhos_abandonados` ganhou automação: `private.carrinho_abandonado_varrer` (cron `carrinho-abandonado-varrer`, 15 em 15 min), regra `CARRINHO_ABANDONADO` em `followup_regras` (reaproveita `followup_fila`/WF6). Migration `20261222000004`.
- `meta-conversions-api` alerta o dono (gravidade alta, dedupe por dia) quando faltam `META_PIXEL_ID`/`META_CAPI_TOKEN`, em vez do retorno silencioso antigo.
- `GBH | WF2 | Agente`: 9 nós "Regras adicionais" + `systemMessage` de 37 regras (>50 mil caracteres) viraram 1 nó ("Prompt consolidado (Fase 1)", ~7,5 mil caracteres); `Agente de atendimento.systemMessage` agora é só `{{ $json.system }}`. 38 nós (antes 45). Detalhes em `docs/n8n-mapa.md`.
- Fora do escopo desta rodada (ver `docs/agente/progresso.md`): loop de 6 saudações do WF1, timeout de `buscar_produto`, `agente_falhou` silencioso, divergência preço-texto×PDF ("Lead #15"), ampliação da leitura de imagem/PDF do cliente.

## Passo 1, blindagem final (20/11/2026)
- `public.agente_iniciar` ganhou idempotência: reconfere o status da própria execução dentro da trava da conversa e devolve `ok=false, motivo='ja_processada'` em vez de reiniciar uma rodada que um retry do n8n (timeout de rede, não falha real) já tinha começado. Fecha o loop de saudações duplicadas do WF1. Migration `20261222000005`.
- `GBH | FERRAMENTA | buscar_produto`: timeout de 20 s/25 s para 12 s/10 s nos dois nós que chamam `buscar_produto` (busca principal e busca de reserva).
- `GBH | WF2 | Agente` (prompt consolidado): regra de PREÇO E FERRAMENTAS reforçada — o SKU passado para `montar_orcamento` tem que ser exatamente o mesmo que `buscar_produto` devolveu para a opção citada nesta rodada (fecha a divergência preço-texto×PDF/link, "Lead #15"); `orcamento-pdf` e `preparar_link_pagamento` já tinham as travas certas (orçamento encerrado/vencido recusado, valor do pedido conferido contra o orçamento antes do link).
- Meta CAPI confirmada operando com as Secrets já cadastradas pelo dono (fila sem pendentes travados).

## Bugs urgentes de atendimento real (20/11/2026)
- `GBH | WF2 | Agente`: `maxOutputTokens` 2048→4096 (mensagem cortada no meio); nova condição de repetição automática quando o texto não termina em pontuação final; prompt ganhou a regra de citar impressão+papel/acabamento junto de todo preço, a regra de abertura de cartão de visita só em 4x4 colorido, e teve 2 correções da Fase 1 restauradas (300 caracteres por mensagem, proibição de dizer "aprovado"/anunciar o link) depois de uma regressão do Passo 1.
- `private.fu_assunto`: bordas de palavra em todos os padrões (corrige "stamping" virando "bottons" pela substring "pin") e só olha mensagens do cliente (`direction = 'in'`), nunca as da própria Laura.
- `private.saida_travas_extra`: nova trava para "cliente" usado como vocativo quando o contato não tem nome válido.
- "Pix de qualquer banco" removido de `fu_texto_anuncio`, `fu_texto_tiragens_menores`, `followup_montar_base`, `cobertura_processar`, da tabela `conhecimento`, de `orcamento-pdf`, do prompt do WF2, da sticky note do `gerar_link_pagamento`, do site e do banner de checkout. `followup_regras.Q1_ANUNCIO` desativada (redundante com a abertura de anúncio da Fase 1). Migration `20261222000008`.

## Fase 2 do Plano de Ação: prévia de arte (20/11/2026)
- Tabela `previas_arte` (fila: pendente/processando/pronta/erro/aguardando_limite), funções `previa_arte_criar/status/enviar_briefing/regenerar/ajustar/fechar/proxima/concluir`, buckets `previas-uploads` e `previas-arte`. Migrations `20261222000006` e `20261222000007`.
- Edge Functions `previa-arte`, `previa-arte-upload`, `previa-arte-processar` (worker: API oficial configurável, Gotenberg para o PNG com marca d'água).
- Página `/previa/<token>` no e-commerce; ferramenta `gerar_link_previa` (15ª do despachante, as 14 anteriores intactas). WF2 (regra ARTE E AMOSTRA) chama para lead qualificado que pede prévia/trava por medo de pagar antes da arte (21/11/2026). `PREVIA_ARTE_API_KEY`/`PREVIA_ARTE_PROVEDOR=gemini` cadastrados; modelo padrão `gemini-3.8-flash` (o antigo `gemini-2.0-flash` estava 404). Geração real testada ponta a ponta. Detalhes em `docs/ecommerce.md`.

## Item 7 do Plano de Ação: confirmação de pagamento sem dado fiscal (20/11/2026)
- `montarConfirmacaoCliente`/`templateConfirmacaoCliente` (`_shared/alertas.ts` e a cópia em `cliente-pago-avisar/index.ts`): mensagem fixa "Oi, {nome}! Aqui é o João Victor da Sua Gráfica BH! Seu pagamento foi confirmado! Seu pedido {numero} já entrou na fila. Previsão de ficar pronto: {data_prevista}.", sem pedido de CPF/CNPJ/e-mail/CEP nem o trecho da Praça Sete (o checkout próprio `/pagar/<token>` já coleta esses dados). `pagamento_pos_reservar_msg` devolve `nome` por `private.fu_nome` (nulo sem nome válido → saudação "Oi!"/"você", nunca "cliente"). Migration `20261222000009`.
- `GBH | WF2 | Agente`: regra "NOTA FISCAL E CADASTRO" reescrita — a Laura só pergunta pelo chat o que faltar depois do checkout, não pede tudo de novo por reflexo.

## 4 frentes (21/11/2026): frete, prévia de arte, condição 24h e recompra
- `loja-frete`: dentro da Grande BH fora dos 7 bairros centrais grátis, expõe "Entrega por aplicativo" com o valor de referência de `verificar_frete` (antes não oferecia nenhuma opção; venda real perdida). `OpcaoEnvio.servico` ganhou `'uber'`.
- Prévia de arte: `previa_arte_regenerar` aceita `status='erro'` (botão "Tentar de novo" estava travado); worker disparado no envio do formulário (cron cai para 5 min, só reforço); `/previa` sem chrome da loja; formulário com um campo de texto único; `previa_arte_limpar_expiradas` (48h, só não pagos). Migration `20261222000010`.
- Prévia de arte (22/11/2026): geração virou image-to-image — o worker manda a foto real do produto pro Gemini (`responseModalities: ['IMAGE']`) e recebe o mockup já com a arte do cliente aplicada nele (não mais HTML/arte solta ao lado da foto). `_shared/previa-arte.ts`: `montarPromptMockup`/`extrairImagemGemini` substituem `montarPromptArte`/`extrairHtml`; marca d'água continua só por código. Modelo padrão `gemini-2.5-flash-image` (`gemini-3.8-flash-image` deu 404).
- `private.followup_montar_base`: `PAG_24H` sem condição vigente aciona `oferecer_condicao_especial` (G1) antes de cobrar frio. `followup_regras` RECOMPRA_* padronizadas em 30 dias (`revisar=false`). Migration `20261222000011`.

## Checkout próprio: entrega e layout (22/11/2026)
- Migration `20261222000012`: `order_items_validar` não aplica o piso à linha de frete do checkout; `checkout_definir_frete` aceita entrega por aplicativo (linha a R$ 0,00, valor combinado na hora); `checkout_carregar` devolve `frete.aplicativo`; `checkout_sincronizar_orcamento` ignora a linha do aplicativo.
- `loja-frete`: opção `uber` com `a_combinar: true` (sem valor fixo). Front: `components/pagar/Linha.tsx` recolhe entrega, quantidade e sugestões; pagamento fica logo depois de dados e arte.
