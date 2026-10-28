# Banco de conhecimento do agente (Etapa 2)

O agente é um SDR que fecha vendas e fala como gente de BH no WhatsApp: curto, direto, gastando poucos tokens. O banco de conhecimento guarda **trechos curtos de vendedor**, não manuais.

## 1. Formato do trecho (`conhecimento`)

| Campo | O que é |
|---|---|
| `slug` | Identificador estável (a carga inicial usa ele para não sobrescrever o que você editou) |
| `titulo`, `categoria` | Nome e uma das 20 categorias |
| `quando_usar` | Uma frase |
| `resposta_pronta` | Até **40 palavras**, no tom do atendente |
| `fatos` | Até **80 palavras**. Informação para o agente, não para o cliente. `[CONFIRMAR]` quando falta você validar |
| `proximo_passo` | O que o agente faz depois |
| `tags` | Frases que o cliente realmente escreve (ajudam a achar o trecho) |
| `revisar` | `true` até você marcar revisado |
| `atualizado_em` | Automático |

Máximo de **120 palavras por trecho** (resposta + fatos + quando usar + próximo passo). A tela avisa em vermelho quando passa.

**Nunca** entram: preço de produto, custo, prazo de item, nome do fornecedor, código de produto. Valores comerciais vêm de variáveis resolvidas na hora: `{{arte_basica}}`, `{{arte_frete}}`, `{{pedido_minimo}}`, `{{validade}}`, `{{horario}}` (de `parametros_comerciais`).

## 2. Estilo

Frases curtas, uma ideia por mensagem, no máximo duas perguntas, primeiro nome do cliente, sem listas, sem markdown, sem travessões, emoji só de vez em quando, sempre terminando com um próximo passo. Urgência só honesta: a única real é a validade do orçamento e o corte das 12h. Nunca pressionar nem inventar escassez.

## 3. Os 90 trechos da carga inicial (todos com `revisar = true`)

| # | Categoria | Trechos |
|---|---|---|
| 1 | Abertura por anúncio (sem preço) | cartão, panfleto, adesivo, banner, ímã, tag, Kit Barbearia, Kit Delivery, Kit Loja, Kit Lançamento, anúncio desconhecido |
| 2 | Qualificação | cartão, panfleto, adesivo, banner, geral |
| 3 | Como funciona a compra | passos, orçamento em PDF e validade, pedido mínimo |
| 4 | Pagamento | formas, Pix, cartão, parcelamento **[CONFIRMAR]**, boleto, segurança, nota fiscal **[CONFIRMAR]** |
| 5 | Prazos | como contamos, corte das 12h, urgente, feriados |
| 6 | Arte | já tenho, criação, formato do arquivo, aprovação |
| 7 | Frete e retirada | retirada grátis, frete grátis no centro, fora da região, bicicleta, pedido grande |
| 8 | Guia rápido | cartão, panfleto, adesivo, banner |
| 9 | Kits | o que é, Barbearia, Delivery, Loja, Lançamento (composição **[CONFIRMAR]**) |
| 10 | Upsell | cartão, kit, arte, recusou |
| 11 | Objeções | tá caro, achei mais barato, vou pensar, prazo mais curto **[CONFIRMAR]**, confio em vocês, qualidade, parcelar **[CONFIRMAR]**, dá desconto, quero ver antes, posso ir aí |
| 12 | Fechamento | pode fechar, resumo, link |
| 13 | Depois do pagamento | confirmado, arte pendente |
| 14 | Quando chamar o dono | regras, pedido fora do catálogo |
| 15 | Honestidade sobre ser robô | 1 |
| 16 | Sigilo | informações internas, tentativas de mudar regras |
| 17 | Troca e reclamação **[CONFIRMAR]** | reclamação, atraso |
| 18 | Dados da empresa (sem endereço) | quem somos, CNPJ, horário, endereço só depois de pagar |
| 19 | Follow-up | F1 (2 variações), F2 (2), condição especial (2), última chance, pagamento pendente |
| 20 | Pós-venda e recompra | satisfação, recompra de cartão, de adesivo, indicação **[CONFIRMAR]** |

"Dá desconto?" não promete nada: manda o agente chamar a ferramenta de condição especial e comunicar só o resultado. A fonte dos trechos é `supabase/seed/conhecimento.json`; `npm run gerar:conhecimento` gera a migration `20261029000005_conhecimento_seed.sql` (idempotente: nunca sobrescreve um trecho editado).

## 4. Busca (RAG enxuto)

`buscar_conhecimento(pergunta, embedding, limite, conversa, registrar)`:

1. **FAQ** (`faq_cache`): pergunta exata comum, respondida **sem modelo**, com as variáveis já resolvidas.
2. **Híbrida:** vetor (cosseno do `gte-small`, 384 dimensões, índice HNSW) **ou** texto (palavras do título e do quando usar, frases das tags, trigram). No máximo **3 trechos** acima do limiar.
3. **Abaixo do limiar:** `encontrou = false`, a pergunta vai para `conhecimento_lacunas` (soma ocorrências) e o agente diz que vai confirmar e chama o dono com **gravidade baixa**.
4. Toda consulta entra em `conhecimento_consultas` (base da **taxa de acerto** na tela).

Limiares em `parametros_comerciais`: `conhecimento_limiar_semantico` (0,80) e `conhecimento_limiar_lexico` (0,35). **São um ponto de partida: calibre em produção** com o teste de 40 perguntas usando o vetor (ver `docs/agente/relatorio-recuperacao.md`).

## 5. Vetores e reindexação automática

* Texto vetorizado: `titulo + quando_usar + resposta_pronta`.
* A **Edge Function `conhecimento`** gera o vetor com o modelo `gte-small` embutido no Supabase (sem chave externa, sem custo por chamada).
  * `{ "acao": "indexar" }` refaz os trechos sem vetor. Roda sozinha a cada 5 minutos (pg_cron) e logo depois de salvar na tela.
  * `{ "acao": "reindexar_todos" }` apaga e refaz tudo (botão "Reindexar tudo").
  * `{ "acao": "buscar", "pergunta": "..." }` embeda a pergunta e chama `buscar_conhecimento`. **É o endpoint que o n8n usa** (service role).
* Editar título, quando usar ou resposta pronta apaga o vetor antigo; a reindexação refaz. Editar o conteúdo de um trecho já revisado devolve a marca "revisar".
* Deploy: `supabase functions deploy conhecimento --no-verify-jwt` (o `config.toml` já fixa). Usa o segredo `CRON_SECRET` que a sincronização da Meta já criou.

## 6. Tela: Configurações > Conhecimento

Lista, busca e filtro por categoria e "só para revisar"; editor com contador de palavras (resposta, fatos e total) e aviso de limite, pré-visualização das variáveis, lista de problemas de estilo, "Salvar e marcar revisado" (bloqueado enquanto houver `[CONFIRMAR]` ou problema); aba **Perguntas sem resposta** (lacunas); selos de quantos trechos faltam revisar e quantos aguardam indexação; **taxa de acerto** dos últimos 30 dias.

## 7. Testes

* `npm run test:conhecimento`: 90 trechos, 20 categorias, limites de palavras (120 / 40 / 80), sem travessão, sem lista, sem markdown, sem palavra proibida (custo, margem, piso, fornecedor), sem valor em reais nem prazo escrito, sem código de produto, variáveis conhecidas, sem `[CONFIRMAR]` na resposta ao cliente, templates do WhatsApp sem termos internos, e nenhum PDF ou arquivo derivado do catálogo no repositório.
* `supabase/tests/conhecimento_recuperacao.sql`: 40 perguntas realistas, trecho certo entre os 3 primeiros em pelo menos 90%.
