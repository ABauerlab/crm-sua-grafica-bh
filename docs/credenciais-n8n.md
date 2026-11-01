# Credenciais do n8n (workflows `GBH |`)

Regra: segredos só em credenciais do n8n, nunca no repositório, no front nem em log. O agente de IA nunca vê o valor de nenhuma credencial.

## Situação verificada pelo MCP do n8n (01/11/2026)
A instância tem 7 credenciais: `Google Drive account`, `Postgres account`, `Google Gemini(PaLM) Api account`, `Groq account`, `Supabase account`, `Header Auth account` e `Header Auth account 2`. Só as GBH usam: `Supabase account`, `Google Gemini(PaLM) Api account` e `Groq account`. As demais são de outros projetos e não devem ser tocadas.

A credencial citada em documentos antigos como "GBH Supabase (service role)" **não existe com esse nome**: era só uma referência. A credencial real é `Supabase account` (tipo Supabase API, id `g3WlIOkLdfsc4XIJ`). Os nós HTTP já usam essa. Conferido: `montar_orcamento` e o nó novo do WF9 têm a credencial atribuída; os workflows das Etapas 5 a 7 foram criados com ela. Os demais (Etapas 3 e 4) devem ser abertos uma vez no editor para confirmar (veja "Como conferir").

## Como criar de verdade a credencial do Supabase (se for recriar)
1. n8n > Credenciais > Criar > **Supabase API**.
2. Nome: `Supabase account` (ou `GBH Supabase service role`, e depois reatribua nos nós).
3. Host: `https://bhlosshvwmlyzhbghsrc.supabase.co`.
4. Service Role Secret: Supabase > Project Settings > API Keys > **secret** (service_role). Nunca a chave publicável.
5. Salvar e testar. Depois atribua em cada nó HTTP da lista abaixo.

## Credenciais por tipo
| Nome | Tipo | Onde gerar o valor | Onde é usada |
|---|---|---|---|
| `Supabase account` | Supabase API | Supabase > Project Settings > API Keys > secret | todos os nós HTTP que chamam `/rest/v1/rpc/...` e as Edge Functions: WF1, WF2, despachante, as 13 ferramentas, WF3, WF4 (aprendizado, aquecer cache, aquecer fotos, mapear fotos), WF5, WF6, WF7, WF8, WF9 |
| `Google Gemini(PaLM) Api account` | Google Gemini API | aistudio.google.com > Get API key | modelo do AI Agent no WF2, resumo de conversa no WF1, último recurso da pesquisa de preço (`pesquisar_preco_mercado`), WF11 (futuro) |
| `Groq account` | Groq API | console.groq.com > API Keys | transcrição de áudio no WF1 (`whisper-large-v3-turbo`) |
| `GBH Tavily` (opcional) | Header Auth `Authorization: Bearer ...` | app.tavily.com | busca, só se `fonte_busca = tavily` |
| `GBH Serper` (opcional) | Header Auth `X-API-KEY` | serper.dev | busca, só se `fonte_busca = serper` |
| `GBH Firecrawl` (opcional) | Header Auth `Authorization: Bearer ...` | firecrawl.dev | leitura com JavaScript, só se `leitura_js = firecrawl` |
| `GBH Renderer` (opcional) | Header Auth `x-token` | valor de `RENDERER_TOKEN` no Coolify | leitor Playwright, só se o token foi definido |
| `GBH Fornecedor login` (Bloco C, só se for necessário) | Header Auth ou credencial própria | login do dono no site do fornecedor | `consultar_preco_dimensao`; ver `docs/agente/preco-por-dimensao.md` |

## Nós HTTP que precisam da credencial `Supabase account`
Todo nó HTTP Request cujo URL começa com `https://bhlosshvwmlyzhbghsrc.supabase.co/` (rpc e functions). Por workflow:
- WF1 Entrada e roteamento; WF2 Agente; despachante; buscar_conhecimento, buscar_produto, salvar_contato, verificar_frete, agendar_followup, chamar_dono.
- montar_orcamento, gerar_pdf_orcamento, gerar_link_pagamento, condicao_especial, pesquisar_preco_mercado, enviar_foto_produto, enviar_proativo.
- WF3, WF4 (4 workflows), WF5, WF6, WF7, WF8, WF9 (inclui o nó novo "Conferir divergência entre pagamento e pedido").

## Como conferir (sem abrir um por um)
1. No n8n, filtre pela tag `gbh`. Abra cada workflow e veja se algum nó HTTP está com a faixa vermelha "Credencial não selecionada".
2. Ou peça à IA: "liste os nós sem credencial nos workflows GBH" (usa `get_workflow_details`). O Bloco A deixou isso registrado em `docs/agente/progresso.md`.

## Que cuidados tomar
- A service role ignora a RLS: use só no n8n e nas Edge Functions.
- Rotacione a chave se ela vazar: Supabase > API Keys > rotate, e atualize a credencial no n8n.
