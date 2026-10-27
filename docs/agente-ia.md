# Agente de IA: pontos de integração

O CRM já guarda tudo que o agente precisa. Ele lê e escreve direto no Supabase (chave **service role**, só no servidor do agente, nunca no front) e não exige mudar nenhuma tela.

## Regra de ouro
**O agente nunca calcula preço.** Ele consulta o banco e usa o que vier de lá:
- Produtos: view `products_priced` (`suggested_price`, `floor_price`, `max_discount_price`, `est_net_profit`).
- Kits: tabelas `kits` e `kit_items` (preço do kit em `kits.price`).
- Limites: `app_settings` chave `pricing` (`floor_multiplier`, `max_discount_pct`, `min_net_profit`, `tax_pct`, `payment_fee_pct`).
- Totais e lucro do pedido: view `order_financials` (calculada no banco).

Nunca oferecer abaixo de `floor_price`, nunca dar desconto acima de `max_discount_pct` e nunca fechar pedido com lucro líquido menor que `min_net_profit`. Fora disso, **passar para uma pessoa**. O CRM também alerta e exige justificativa quando o dono ultrapassa esses limites.

## Sigilo do fornecedor
O agente **nunca cita o nome do fornecedor** (nem confirma se existe um) para ninguém. Para o cliente, a Sua Gráfica BH produz e entrega. Se perguntarem de onde vem o produto, responder que é produção própria e parceira, sem nomes, ou transferir para uma pessoa.

## Catálogo (produtos)
Tabela `products` (e view `products_priced`, que soma os preços calculados). Uma linha por variação vendável, com as mesmas colunas da planilha do fornecedor:

| Campo | Planilha | Exemplo |
|---|---|---|
| `code` | Código | `GIFT1515` (único) |
| `category` | Categoria | `ABRIDORES E CHAVEIROS` |
| `description` | Descrição do serviço | `ABRIDORES E CHAVEIROS - IMPRESSÃO UV - 10g` |
| `colors` | Cores | `4X0` |
| `weight` | Peso | `1250` (valor da coluna Peso) |
| `qty` | Qtde | `25` |
| `size` | Tam | `57 x 57` |
| `lead_days` | Prazo | `5` (dias) |
| `cost` | Preço R$ | `252.99` (custo, o que a Sua Gráfica paga) |
| `suggested_price`, `floor_price`, `max_discount_price`, `est_net_profit` | calculados | vêm do banco |

O agente filtra por esses campos (ex.: `category`, `qty`, `size`) em vez de interpretar texto. A gramatura do papel, quando existe, está escrita dentro de `description`.

## Estado do atendimento
| Onde | Campo | Significado |
|---|---|---|
| `app_settings` (`key = 'agent'`) | `enabled` | Chave geral. `false` = IA pausada em todas as conversas (botão "Pausar IA" no topo do CRM). Ler antes de cada resposta. |
| idem | `hours` (`start`, `end`, `days` 0-6) | Horário de funcionamento da IA |
| idem | `handoff_message` | Texto a enviar ao transferir para uma pessoa |
| `conversations` | `ai_handled` | `true` = a IA responde esta conversa; `false` = humano |
| `conversations` | `needs_human` | A IA marca `true` quando precisa de uma pessoa (aparece como "Atenção" na lista) |
| `conversations` | `attendant_changed_at`, `attendant_change_reason` | Quando e por que a vez mudou |
| `conversations` | `summary` | Resumo curto escrito pela IA (aparece no rodapé do chat) |
| `conversations` | `collected_data` (jsonb) | Dados coletados (ex.: produto, quantidade, prazo, endereço) |
| `conversations` | `labels` (text[]) | Etiquetas (dúvida, orçamento, reclamação, arte, recompra) |
| `conversations` | `last_inbound_at`, `ad_window_until` | Janela de atendimento: 24 h desde a última mensagem do cliente, ou 72 h quando a conversa veio de anúncio |
| `conversations` | `last_referral`; `contacts.first_referral` | Origem do anúncio (id, título, URL) |

**Responder só se**: `agent.enabled = true`, dentro do horário, `conversations.ai_handled = true` e janela aberta. Fora da janela só é permitido template aprovado.

## Eventos
- **Mensagem recebida**: a função `whatsapp-webhook` grava em `messages` (`direction = 'in'`). O agente deve assinar `postgres_changes` (INSERT em `messages`, `direction = 'in'`) ou usar um Database Webhook do Supabase.
- **Dono assumiu ou devolveu**: UPDATE em `conversations.ai_handled`. O agente para de responder quando vira `false`.
- **Pausa geral**: UPDATE em `app_settings` (`key = 'agent'`).
- **PARAR**: o webhook já marca `contacts.marketing_consent = 'opted_out'` e confirma. O agente não envia promoções para quem não está `opted_in`.

## O que o agente escreve
1. **Resposta**: enviar pela API da Meta (ou por uma função própria `agent-send` com service role) e gravar em `messages` (`direction = 'out'`, `status = 'sent'`), como faz `whatsapp-send`. Texto livre só dentro da janela; fora dela, template (`templates_cache`, status `APPROVED`).
2. **Pedido**: inserir em `orders` (`contact_id`, `conversation_id`, `title`; a origem do anúncio vem de `contacts.first_referral`) e em `order_items` (`code`, `description`, `qty`, `unit_cost`, `unit_price` copiados de `products_priced`/`kits`). Etapas: `novo`, `cotando`, `aguardando_pagamento`... A IA pode mover até `aguardando_pagamento`; as regras de banco impedem `pago` sem pagamento e `producao` sem arte aprovada.
3. **Log obrigatório**: toda ação vira uma linha em `agent_logs` (`conversation_id`, `actor = 'ia'`, `action`, `detail` jsonb, `result`). Aparece em Configurações > Agente de IA.
4. **Transferência para pessoa**: `conversations.ai_handled = false`, `needs_human = true`, `attendant_change_reason`, enviar `handoff_message` e registrar em `agent_logs`.

## Endpoints existentes
| Função | Uso pelo agente |
|---|---|
| `whatsapp-send` | Exige JWT do dono. O agente deve usar a API da Meta direto (ou uma função nova com service role) e seguir as mesmas regras de janela e de consentimento |
| `whatsapp-media` | Baixa mídia recebida (imagem, áudio, documento) |
| `meta-ads-sync` | Sincroniza gasto dos anúncios (uso do CRM) |

## Checklist antes de ligar
1. Ler `agent.enabled`, horário e `ai_handled`.
2. Conferir janela (`last_inbound_at` + 24 h ou `ad_window_until`).
3. Preços só de `products_priced` e `kits`.
4. Gravar `agent_logs`.
5. Na dúvida, reclamação ou pedido de desconto acima do limite: transferir para uma pessoa.
