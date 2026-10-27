# CRM Sua Gráfica BH

CRM de atendimento via WhatsApp (API oficial WhatsApp Cloud / Meta) para a Sua Gráfica BH. Interface 100% em português do Brasil.

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
```

### Banco
`profiles`, `contacts`, `conversations` (uma por contato, `unique(contact_id)`), `messages`, `templates_cache`. RLS ativo em todas; acesso só para quem existe em `profiles` (`private.is_staff()` / `private.is_admin()`, schema `private` para não expor via RPC). `messages` e `templates_cache` são somente leitura para o front; a escrita é feita pelas Edge Functions (service role). Mensagens recebidas entram por `public.ingest_inbound_message` (atômica, idempotente por `wa_message_id`, executável só por `service_role`). Realtime habilitado em `messages` e `conversations`.

Consentimento de promoções: `contacts.marketing_consent` (`none` | `opted_in` | `opted_out`) com `marketing_consent_at` e `marketing_consent_source`. O webhook marca `opted_out` quando o cliente responde PARAR (ver `isOptOutMessage` em `_shared/parse.ts`) e `whatsapp-send` recusa templates de categoria MARKETING para quem não está `opted_in` (templates de utilidade seguem livres). Ao receber PARAR, o webhook também envia uma confirmação (`_shared/optout.ts`). `marketing_suppressions` guarda o telefone de quem pediu para parar e foi excluído (admin exclui pelo painel do contato). `templates_cache.has_opt_out_button` indica template de marketing com botão de resposta rápida "Parar promoções".

Pedidos: `orders` (etapa, pagamento, arte, entrega), `order_items`, `order_events` (histórico), `order_files` (bucket privado `order-files`) e a view `order_financials` (total, custo, impostos, taxa e lucro líquido calculados no banco). Triggers bloqueiam mover para Pago sem pagamento confirmado e para Produção sem arte aprovada. `app_settings` guarda os parâmetros de preço (`pricing`), limites por etapa (`kanban`) e o e-mail do dono (`owner`), que `private.is_staff()` exige. Origem do anúncio: `contacts.first_referral` e `conversations.last_referral`, gravados pelo webhook.

Parte 2: `conversations` ganhou `needs_human`, `summary`, `collected_data`, `labels`, `ad_window_until` (72 h para anúncio) e usa `ai_handled` como chave IA/humano; `conversation_notes` (notas internas), `quick_replies`, `tasks`, `products` + view `products_priced` (piso, desconto máximo e lucro estimado calculados no banco), `kits`/`kit_items`, `ad_entities`/`ad_daily`/`ad_manual_spend` + função `ad_performance(from, to)` (cruza gasto da Meta com `origin_ad_id` dos pedidos e `first_referral` dos contatos), `agent_logs`, view `contact_stats`. Integração do agente de IA em `docs/agente-ia.md`.

Extras além do pedido original: `conversations.last_message_preview` (prévia na lista) e a função `admin-create-agent` (admin cria atendentes, já que o cadastro público é desativado).

### Edge Functions
| Função | JWT | O que faz |
|---|---|---|
| `whatsapp-webhook` | não (assinatura HMAC) | GET: verificação da Meta. POST: valida `X-Hub-Signature-256` e grava mensagens/status |
| `whatsapp-send` | sim + existir em `profiles` | texto (janela 24h) ou template |
| `whatsapp-sync-templates` | sim + `profiles` | sincroniza `templates_cache` com a Meta |
| `admin-create-agent` | sim + role admin | cria usuário Auth + profile |
| `whatsapp-media` | sim + `profiles` | entrega imagem, áudio ou documento recebido (o token fica no servidor) |
| `meta-ads-sync` | sim + `profiles` | puxa campanhas, anúncios e gasto diário da conta de anúncios (segredos `META_ADS_TOKEN` e `META_AD_ACCOUNT_ID`) |

## Convenções
- **Sigilo do fornecedor (regra do dono): nunca escrever o nome do fornecedor em lugar nenhum** (código, textos de tela, mensagens e templates do WhatsApp, documentação, comentários, testes, exemplos, commits e PRs). Usar sempre "fornecedor". O front é público e o repositório não pode ser público. `npm test` falha se o nome aparecer no repositório.
- UI, mensagens de erro e commits em português do Brasil; código (identificadores) em inglês.
- Nada de segredos no front, no repositório ou em logs. Logs de função não incluem conteúdo de mensagens.
- Erros das functions voltam como `{ "error": "mensagem clara" }`; o front lê via `invokeFunction` (`src/lib/api.ts`).
- Alterações de banco = nova migration em `supabase/migrations/` (nunca editar uma já aplicada). Depois rodar os advisors de segurança.
- Commits pequenos, uma mudança por commit.

## Segredos necessários (somente nomes)
Edge Functions (painel Supabase › Edge Functions › Secrets): `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_WABA_ID`, `META_APP_SECRET`, `WHATSAPP_VERIFY_TOKEN`; para campanhas: `META_ADS_TOKEN` (token com permissão `ads_read`) e `META_AD_ACCOUNT_ID` (1783199576217713, conta CA SUA GRÁFICA BH).
(`SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` já são injetados pelo Supabase.)
Front (`.env`, ignorado pelo git): `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (chave publicável; nunca a service role).

## Rodar local
```bash
npm install
cp .env.example .env     # preencha VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY
npm run dev              # http://localhost:5173
npm run typecheck && npm run build
npm test                 # webhook (HMAC + parsing) e regras (preço, kanban, login)
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
supabase db push        # migrations
```
(`supabase/config.toml` já fixa `verify_jwt` de cada função.) O deploy também pode ser feito pelo conector do Supabase.

## Limites conhecidos (Fase 1)
Só texto e templates. Mídia recebida aparece como "[imagem recebida]" etc., com `media_id` salvo. Templates com variáveis só no corpo (`{{n}}`); cabeçalho/botões dinâmicos não são suportados.
