# CRM Sua Gráfica BH

CRM de atendimento via WhatsApp (API oficial WhatsApp Cloud / Meta) para a Sua Gráfica BH. Interface 100% em português do Brasil.

## Regras do agente de IA (ler antes de qualquer tarefa)
Antes de qualquer tarefa, leia `docs/agente/00-contexto.md`, `docs/agente/progresso.md` e `docs/agente/mapa-crm.md`. Mais detalhes em `AGENTS.md`.

Antes de qualquer tarefa, leia `docs/agente/00-contexto.md`, `docs/agente/progresso.md` e `docs/agente/mapa-crm.md`.

### Regras fixas
- O preço que vale é o de `calcular_preco`, com pesquisa de mercado mais trava de lucro.
- Nunca vender abaixo do piso nem com prejuízo.
- O modelo de IA nunca calcula preço, prazo, frete nem desconto.
- Segredos nunca ficam no repositório, no front nem em logs.
- A tabela e o custo do fornecedor nunca vão ao repositório nem ficam visíveis ao cliente.
- O SKU do fornecedor é interno.
- O endereço de retirada só é informado depois do pagamento.
- Workflows do n8n sempre são criados pelo MCP do n8n, na pasta `Sua Gráfica BH`, com nome `GBH | ...`, e ficam DESATIVADOS até a Etapa 8.

### Fluxo de trabalho
- Uma branch e um PR por etapa. Nunca faça commit direto na `main`, porque cada merge publica o CRM em produção.
- Migrations devem ser aditivas e idempotentes.
- Rode os testes antes do PR.
- Ao terminar, atualize `docs/agente/progresso.md` e `docs/agente/mapa-crm.md`.
- Depois pare sem avançar para a próxima etapa.

### Passagem de bastão
Se a sessão acabar no meio de uma etapa, registre em `docs/agente/progresso.md`, na seção `Em andamento`, o que foi feito, o que falta, a branch e os arquivos tocados, e faça commit na branch.

## Arquitetura

- **Front** (`src/`): Vite + React + TypeScript + Tailwind v3 + componentes estilo shadcn/ui (`src/components/ui`) + React Router + TanStack Query.
- **Backend**: Supabase (Auth, Postgres, Realtime, Edge Functions Deno). Projeto ref `bhlosshvwmlyzhbghsrc`.
- O front só fala com o Supabase (chave publicável + JWT do atendente, protegido por RLS). **Toda chamada à API do WhatsApp acontece apenas nas Edge Functions.**

```
src/
  auth/        AuthProvider (sessão + profile)
  components/  Layout, componentes ui/ (button, input, select, switch...)
  features/inbox/  ConversationList, ChatPanel, ContactPanel, TemplatePicker
  hooks/queries.ts queries + useRealtimeSync (postgres_changes -> invalida cache)
  lib/         supabase.ts, api.ts (invoke de functions), format.ts, types.ts
  pages/       Login, ResetPassword, Dashboard (Painel), Kanban, Inbox, Contacts, Templates, Settings, Team, Legal (/privacidade, /termos, /exclusao-de-dados)
supabase/
  migrations/  SQL versionado (ordem pelo prefixo de data)
  functions/   whatsapp-webhook, whatsapp-send, whatsapp-sync-templates, admin-create-agent, _shared/
scripts/test-webhook.ts   testes de assinatura/parsing (Node)
scripts/test-rules.ts     testes de regras de preço, transições do kanban e bloqueio de login (Node)
scripts/screenshots.cjs   gera docs/telas com o Supabase simulado (Playwright)
n8n/                      workflows GBH exportados do MCP do n8n, sem credenciais (ver docs/n8n-mapa.md)
infra/                    SearXNG e leitor Playwright para a pesquisa de preço (ver docs/agente/infra-busca.md)
```

### Banco
`profiles`, `contacts`, `conversations` (uma por contato, `unique(contact_id)`), `messages`, `templates_cache`. RLS ativo em todas; acesso só para quem existe em `profiles` (`private.is_staff()` / `private.is_admin()`, schema `private` para não expor via RPC). `messages` e `templates_cache` são somente leitura para o front; a escrita é feita pelas Edge Functions (service role). Mensagens recebidas entram por `public.ingest_inbound_message` (atômica, idempotente por `wa_message_id`, executável só por `service_role`). Realtime habilitado em `messages` e `conversations`.

Consentimento de promoções: `contacts.marketing_consent` (`none` | `opted_in` | `opted_out`) com `marketing_consent_at` e `marketing_consent_source`. O webhook marca `opted_out` quando o cliente responde PARAR (ver `isOptOutMessage` em `_shared/parse.ts`) e `whatsapp-send` recusa templates de categoria MARKETING para quem não está `opted_in` (templates de utilidade seguem livres). Ao receber PARAR, o webhook também envia uma confirmação (`_shared/optout.ts`). `marketing_suppressions` guarda o telefone de quem pediu para parar e foi excluído (admin exclui pelo painel do contato). `templates_cache.has_opt_out_button` indica template de marketing com botão de resposta rápida "Parar promoções".

Pedidos: `orders` (etapa, pagamento, arte, entrega), `order_items`, `order_events` (histórico), `order_files` (bucket privado `order-files`) e a view `order_financials` (total, custo, impostos, taxa e lucro líquido calculados no banco). Triggers bloqueiam mover para Pago sem pagamento confirmado e para Produção sem arte aprovada. `app_settings` guarda os parâmetros de preço (`pricing`), limites por etapa (`kanban`) e o e-mail do dono (`owner`), que `private.is_staff()` exige. Origem do anúncio: `contacts.first_referral` e `conversations.last_referral`, gravados pelo webhook.

Parte 2: `conversations` ganhou `needs_human`, `summary`, `collected_data`, `labels`, `ad_window_until` (72 h para anúncio) e usa `ai_handled` como chave IA/humano; `conversation_notes` (notas internas), `quick_replies`, `tasks`, `catalogo` (antiga `products`; `products` e `products_priced` seguem como visões de compatibilidade) com SKU, status de venda, piso e flags por linha, `kits`/`kit_items`, `ad_entities`/`ad_daily`/`ad_manual_spend` + função `ad_performance(from, to)` (cruza gasto da Meta com `origin_ad_id` dos pedidos e `first_referral` dos contatos), `agent_logs`, view `contact_stats`. Integração do agente de IA em `docs/agente-ia.md`.

Mercado Pago: `pagamentos` (links e tentativas), `eventos_pagamento` (contrato com o agente), `pagamentos_alertas`, `orders.teste`. Um só caminho para marcar pago (`private.confirmar_pagamento`, usado pelo webhook e por `confirmar_pagamento_manual`). Detalhes em `docs/pagamento-mercadopago.md`.

Extras além do pedido original: `conversations.last_message_preview` (prévia na lista) e a função `admin-create-agent` (admin cria atendentes, já que o cadastro público é desativado).

### Edge Functions
| Função | JWT | O que faz |
|---|---|---|
| `whatsapp-webhook` | não (assinatura HMAC) | GET: verificação da Meta. POST: valida `X-Hub-Signature-256` e grava mensagens/status |
| `whatsapp-send` | sim + existir em `profiles` | texto (janela 24h) ou template |
| `whatsapp-sync-templates` | sim + `profiles` | sincroniza `templates_cache` com a Meta |
| `admin-create-agent` | sim + role admin | cria usuário Auth + profile |
| `whatsapp-media` | sim + `profiles` | entrega imagem, áudio ou documento recebido (o token fica no servidor) |
| `mp-criar-link` | não (confere dono ou service role) | cria ou devolve o link do Checkout Pro do pedido (valor vem do banco) |
| `mp-webhook` | não (assinatura `x-signature`) | valida o aviso, consulta o pagamento no Mercado Pago e confirma o pedido pelo banco |
| `mp-conferir` | não (dono, service role ou `x-cron-secret`) | consulta o Mercado Pago pelos pagamentos do pedido e grava pelo mesmo caminho do webhook (botão "Conferir agora" e agendamento de 10 min) |
| `conhecimento` | não (dono, service role ou `x-cron-secret`) | gera vetores `gte-small` do banco de conhecimento, reindexa e busca trechos para o agente |
| `orcamento-pdf` | não (dono, service role) | gera o PDF do orçamento no Gotenberg, guarda no bucket privado `orcamentos`, envia como documento no WhatsApp (idempotente; vencido gera novo; trava de lucro antes de enviar) |
| `produto-fotos` | não (dono, service role) | busca, processa (JPEG até 150 KB, teto 300 KB), confere marca e envia fotos de produto no WhatsApp; cache de 30 dias por grupo; resposta ao agente sem origem |
| `agente-enviar` | não (só service role) | envio de texto do agente (n8n): confere IA ligada, modo IA, pedido não pago e janela de 24 h antes de enviar |
| `alertas-enviar` | não (service role para `processar`; dono logado para `teste` e `chave_publica`) | entrega os alertas ao dono: popup (Web Push, VAPID) e WhatsApp (texto livre na janela de 24 h, senão template); tentativas, resumo e aviso pelo outro canal |
| `cliente-pago-avisar` | não (só service role) | WF5: UMA mensagem ao cliente depois do pagamento confirmado (livre na janela, senão `pedido_pago_confirmacao`), reserva atômica e 3 tentativas |
| `produto-opcoes` | não (dono ou service role) | uma mensagem por opção com foto e ficha traduzida (legenda montada no servidor), chamada por `enviar_foto_produto` com `opcoes: produto; quantidade` |
| `meta-ads-sync` | sim + `profiles` | puxa campanhas, anúncios e gasto diário da conta de anúncios (segredos `META_ADS_TOKEN` e `META_AD_ACCOUNT_ID`) |

### Preço sob demanda e condição especial (Etapa 3)
`calcular_preco` é a única autoridade do preço (mercado pesquisado na hora do orçamento, fator por grupo, âncora de vendas, travas `piso` e `piso_duro`). A pesquisa roda no n8n (`GBH | FERRAMENTA | pesquisar_preco_mercado`), grava em `precos_mercado` (cache de 14 dias) e respeita robots, termos e intervalo por domínio (`fontes_pesquisa`). Desconto só existe como condição especial (`oferecer_condicao_especial`, degraus 1 a 3, validade de 24 h, nunca abaixo do piso); `aplicar_desconto` foi removida. Edição manual de preço no pedido: abaixo do `piso_duro` bloqueia, entre o piso duro e o piso exige confirmação do dono (`precos_manuais_log`). Detalhes em `docs/agente-ia.md`, `docs/agente/etapa3-validacao.md` e `docs/n8n-mapa.md`. Testes SQL: `supabase/tests/preco_etapa3.sql`.

### Orçamento em PDF (Etapa 4)
`montar_orcamento` (banco) monta o orçamento só a partir de SKUs e quantidades, com `calcular_preco`, `calcular_prazo`, `verificar_frete` e `validar_margem`; `orcamento-pdf` gera o PDF (modelo em `supabase/functions/_shared/orcamento-html.ts`, sem custo, margem, piso, fornecedor, SKU nem endereço de retirada) e `preparar_link_pagamento` valida a margem antes do link do Mercado Pago. Detalhes em `docs/orcamento-pdf.md`. Exemplos em `docs/exemplos-orcamento/` (catálogo fictício; a exceção do `.gitignore` vale só para essa pasta). Testes SQL: `supabase/tests/orcamento_etapa4.sql`.

### Fotos de produto (Etapa 4B)
`produto_fotos` (por grupo, não por SKU), `produto_fotos_grupos` (cache de 30 dias) e `produto_fotos_envios` (limites: 3 por pedido, 1 pedido por minuto por conversa, 10 imagens por contato por dia); bucket privado `produto-fotos` com nomes de hash; tela Catálogo > Fotos. A origem das imagens é INTERNA e fica só em `app_settings.fotos.origem_base` (nunca no repositório, nos docs, nos logs, nas legendas nem na resposta ao agente). Detalhes em `docs/fotos-de-produto.md`. Testes: `npm run test:fotos` e `supabase/tests/fotos_etapa4b.sql`.

### Agente de atendimento (Etapa 5)
`whatsapp-webhook` (único receptor da Meta) avisa o WF1 do n8n com o id da mensagem; o WF1 decide (`agente_entrada`), junta mensagens (debounce de 8 s), trata mídia, monta o contexto e chama o WF2 (AI Agent Gemini com 11 ferramentas via `GBH | FERRAMENTA | despachar`); a resposta passa pela trava de saída (`agente_saida_segura`) e sai por `agente-enviar`. O modelo nunca calcula preço, prazo, frete nem desconto; custo, piso, margem, fornecedor, SKU, bicicleta e endereço de retirada são barrados na ferramenta e na saída. Rodadas em `agente_execucoes` e `agent_logs` (tokens e custo são estimativas). Cenários de teste `e5-*` em `testes_conversa`. Detalhes em `docs/agente-ia.md` e `docs/agente/etapa5-testes.md`. Testes: `supabase/tests/agente_etapa5.sql` e `npm run test:agente`.

### Alertas, PWA e pagamento (Etapa 6)
O CRM é um PWA instalável (manifest, `sw.js`, ícones). `alertas` é a única fila de avisos ao dono: `alerta_criar` aplica a regra de 30 minutos, gravidade (alta sai na hora, baixa vira resumo de 2 h), preferências por tipo e silêncio (`app_settings.notificacoes`); `alertas-enviar` entrega por popup e WhatsApp. O WF5 do n8n processa `pagamento_confirmado` (modo humano, follow-ups cancelados, mensagem única ao cliente, alerta ao dono). Chaves VAPID em segredos ou em `app_segredos`, nunca no repositório. Detalhes em `docs/pwa-e-notificacoes.md`. Testes: `npm run test:alertas` e `supabase/tests/alertas_etapa6.sql`.

### Catálogo do fornecedor e SKU (Etapa 2)
A tabela de preços do fornecedor é **privada**: PDF e derivados nunca entram no repositório (original no bucket privado `catalogo-fornecedor`). Só o dono lê `catalogo` e custo; o agente e o front de atendimento usam `buscar_produto`, `agente_preco` e `buscar_conhecimento`, que não devolvem custo. SKU é obrigatório em orçamento e pedido novos e é INTERNO (nunca no PDF nem ao cliente). `preco_base_custo` é só referência; o preço válido vem de `calcular_preco`. Detalhes em `docs/catalogo-e-sku.md` e `docs/conhecimento.md`. Testes SQL locais: `supabase/tests/rodar-local.sh`.

## Convenções
- **Sigilo do fornecedor (regra do dono): nunca escrever o nome do fornecedor em lugar nenhum** (código, textos de tela, mensagens e templates do WhatsApp, documentação, comentários, testes, exemplos, commits e PRs). Usar sempre "fornecedor". O front é público e o repositório não pode ser público. `npm test` falha se o nome aparecer no repositório.
- UI, mensagens de erro e commits em português do Brasil; código (identificadores) em inglês.
- Nada de segredos no front, no repositório ou em logs. Logs de função não incluem conteúdo de mensagens.
- Erros das functions voltam como `{ "error": "mensagem clara" }`; o front lê via `invokeFunction` (`src/lib/api.ts`).
- Alterações de banco = nova migration em `supabase/migrations/` (nunca editar uma já aplicada). Depois rodar os advisors de segurança.
- Commits pequenos, uma mudança por commit.

## Segredos necessários (somente nomes)
Edge Functions (painel Supabase › Edge Functions › Secrets): `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_WABA_ID`, `META_APP_SECRET`, `WHATSAPP_VERIFY_TOKEN`; para campanhas: `META_ADS_TOKEN` (token com permissão `ads_read`) e `META_AD_ACCOUNT_ID` (1783199576217713, conta CA SUA GRÁFICA BH).
Orçamento em PDF: `GOTENBERG_URL`, `GOTENBERG_USER`, `GOTENBERG_PASSWORD`.
Agente (Etapa 5): `N8N_WF1_URL` e `N8N_WF1_TOKEN` (o `whatsapp-webhook` avisa o WF1 do n8n; sem eles o agente fica fora do caminho).
Fotos de produto: `GEMINI_API_KEY` (verificação de marca nas imagens; sem ela nada é aprovado sozinho).
Alertas (Etapa 6, opcionais): `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` (sem eles a função gera e guarda o par em `app_segredos`).
Mercado Pago: `MP_MODO` (`teste`|`producao`), `MP_ACCESS_TOKEN_TESTE`, `MP_WEBHOOK_SECRET_TESTE`, `MP_ACCESS_TOKEN_PRODUCAO`, `MP_WEBHOOK_SECRET_PRODUCAO`.
(`SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` já são injetados pelo Supabase.)
Front (`.env`, ignorado pelo git): `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (chave publicável; nunca a service role).

## Rodar local
```bash
npm install
cp .env.example .env     # preencha VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY
npm run dev              # http://localhost:5173
npm run typecheck && npm run build
npm test                 # webhook (HMAC + parsing), regras (preço, kanban, login) e Mercado Pago
```

## Deploy das funções
Com a CLI do Supabase (`supabase login` e `supabase link --project-ref bhlosshvwmlyzhbghsrc`):
```bash
supabase functions deploy whatsapp-webhook --no-verify-jwt
supabase functions deploy whatsapp-send
supabase functions deploy whatsapp-sync-templates
supabase functions deploy admin-create-agent
supabase functions deploy whatsapp-media
supabase functions deploy meta-ads-sync
supabase functions deploy conhecimento --no-verify-jwt
supabase functions deploy mp-webhook --no-verify-jwt
supabase functions deploy mp-criar-link --no-verify-jwt
supabase functions deploy mp-conferir --no-verify-jwt
supabase functions deploy orcamento-pdf --no-verify-jwt
supabase functions deploy produto-fotos --no-verify-jwt
supabase functions deploy produto-opcoes --no-verify-jwt
supabase functions deploy agente-enviar --no-verify-jwt
supabase functions deploy alertas-enviar --no-verify-jwt
supabase functions deploy cliente-pago-avisar --no-verify-jwt
supabase db push        # migrations
```
(`supabase/config.toml` já fixa `verify_jwt` de cada função.) O deploy também pode ser feito pelo conector do Supabase.

## Limites conhecidos (Fase 1)
Só texto e templates. Mídia recebida aparece como "[imagem recebida]" etc., com `media_id` salvo. Templates com variáveis só no corpo (`{{n}}`); cabeçalho/botões dinâmicos não são suportados.

## Decisões do dono (Etapa 7B, resumo; completo em `docs/agente/decisoes-e-melhorias.md`)
- Pix sempre primeiro (qualquer banco). 2x sem juros só se o cliente perguntar ou hesitar; acima de 2x só por decisão do dono, com juros avisados antes.
- Taxa embutida no preço: o piso usa a pior taxa possível (cartão em 2x) enquanto o método é desconhecido; depois do pagamento vale a taxa REAL do Mercado Pago.
- Pedido manual exige método de pagamento escolhido; dinheiro e transferência sem taxa.
- Prazo oficial nunca muda e conta da aprovação da arte. Atrasado = em produção e fora do prazo útil. Urgência só ordena a fila.
- Pedido pago nunca é apagado (cancelar ou arquivar); exclusão lógica com motivo e auditoria.
- Avaliação no Google sem qualquer benefício em troca. Marketing só para quem consentiu.
- BauerLab (site, marca, anúncios): apresentar uma vez e passar o contato de João Victor.
- Tom humano de vendedor, sem travessão, emoji com moderação; reclamação chama o dono.
