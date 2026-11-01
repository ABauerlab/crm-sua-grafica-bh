# Etapa 5: relatório de testes do agente (WF1 e WF2)

## Resultado final dos 21 cenários com o modelo real (01/11/2026)

**21 de 21 passam** nos critérios automáticos (`agente_teste_avaliar`), com a migration aplicada em produção (migrations 01 a 03, autorizadas), modelo padrão `gemini-3-flash-preview`, modelo forte `gemini-3.1-pro-preview` e os 13 sub-workflows publicados só durante o teste (desfeitos no fim; WF1 e WF2 nunca ficaram ativos). Ferramentas externas (PDF, foto, link) e o envio ao WhatsApp são simulados em modo de teste; o resto (banco, preço, prazo, frete, condição especial, conhecimento, contato, alerta) rodou de verdade e os dados de teste foram apagados.

| Cenário | Ferramentas usadas | Tokens (estim.) | Custo (R$, estim.) |
|---|---|---|---|
| 01 cartão do anúncio | conhecimento, produto, contato, dono | 8.789 | 0,018 |
| 02 kit | conhecimento, produto, contato, dono | 13.530 | 0,026 |
| 03 indeciso (G1) | condição especial, PDF | 6.552 | 0,014 |
| 04 desconto sem gordura | condição especial, PDF, contato, dono | 3.240 | 0,007 |
| 05 caçador de desconto | condição especial, contato | 4.865 | 0,010 |
| 06 sem arte | conhecimento, produto, frete, contato, dono | 18.955 | 0,037 |
| 07 escritório antes de pagar | conhecimento, PDF, contato, dono | 8.355 | 0,018 |
| 08 item raro | conhecimento, produto, contato, dono | 8.916 | 0,019 |
| 09 "você é robô?" | contato | 3.067 | 0,007 |
| 10 várias mensagens | conhecimento, produto, contato | 6.771 | 0,013 |
| 11 áudio | produto, contato | 4.904 | 0,010 |
| 12 injeção de regras | contato | 3.102 | 0,007 |
| 13 fora do catálogo | conhecimento, produto, contato, dono | 8.655 | 0,018 |
| 14 quantidade sem SKU | produto, contato | 7.084 | 0,014 |
| 15 bairro central | conhecimento, produto, frete, contato, dono | 10.905 | 0,022 |
| 16 banner fora da região | conhecimento, produto, frete, contato, dono | 10.826 | 0,022 |
| 17 mercado abaixo do piso | condição especial, dono | 4.770 | 0,009 |
| 18 falha de ferramenta | conhecimento, produto, frete, contato, dono (e alerta automático) | 10.981 | 0,022 |
| 19 condição expirada | condição especial, PDF | 4.942 | 0,010 |
| 20 pedido de foto | conhecimento, produto, foto, contato, dono | 6.509 | 0,013 |
| 21 pagamento confirmado | nenhuma (ignorada por `pedido_pago`) | 0 | 0,000 |

**Custo médio medido (estimado por caracteres): R$ 0,016 por cenário (cerca de 7.800 tokens), mínimo R$ 0,007 e máximo R$ 0,037; o cenário 21 custa zero.** Cada cenário é uma rodada; uma conversa real de 6 a 8 rodadas fica em cerca de R$ 0,10 a R$ 0,30 (no teto de R$ 0,30 por conversa usado no piso). Estimativa: o n8n não entrega o uso real do Gemini ao workflow; confira na fatura do Google AI Studio.

### O que a leitura das respostas achou (e foi corrigido)
- **Texto cru de chamada de ferramenta como resposta** (cenários 17 e 20: `Calling tools: chamar_dono`, `control_token:default_api...`): artefato do Gemini 3. Os critérios automáticos não pegavam, a leitura sim. A trava de saída agora bloqueia esse texto (sai a frase neutra e o dono recebe alerta alto). Migration 03.
- **Trava bloqueava valor correto do orçamento aberto** (cenário 19): o valor vinha do contexto, não de ferramenta. Agora a trava aceita os valores do orçamento aberto da conversa. Migration 02.
- **Resposta vazia do modelo** (cenário 07): o limite de 700 tokens de saída era consumido pelo raciocínio interno. Subi para 2.048 e, se vier vazio, sai a frase neutra em vez de silêncio.
- **Modelos:** `gemini-2.5-flash` e `gemini-3-pro-preview` dão 404 na conta; valem `gemini-3-flash-preview` e `gemini-3.1-pro-preview`. Esses são modelos "preview": confirme se quer fixar versões estáveis quando existirem.
- Picos de concorrência (muitos cenários ao mesmo tempo) fizeram alguns terminarem sem resposta; repetidos sozinhos, passaram.

### Pontos de atenção que ficam (não bloqueiam)
- O agente chama `chamar_dono` com frequência (em 8 dos 21 cenários) para itens em que talvez nem precisasse. Se o volume de alertas incomodar, afinar o prompt do WF2.
- Nos cenários 15 e 16 o agente disse que ia "confirmar" frete e valor em vez de informar, mesmo tendo a resposta da ferramenta. Vale um ajuste fino no prompt depois dos primeiros dias reais.
- A trava de saída não confere fatos numéricos soltos (por exemplo "a partir de 100 unidades").
- "Acabei de te mandar o PDF" aparece nas respostas; em produção o PDF é enviado de verdade pela ferramenta, em teste foi simulado.

## O que foi testado de verdade

| Camada | Como | Resultado |
|---|---|---|
| Banco (roteamento, debounce, trava por conversa, contexto, trava de saída, loop, tetos, ferramentas simples, follow-up, modo de teste) | `supabase/tests/agente_etapa5.sql` em Postgres 16 local (bloco que desfaz tudo) | **96 testes passam** |
| Regressão das etapas 1 a 4B contra o schema novo | os 5 arquivos de teste anteriores | 54, 82, 67, 55 e 38 passam |
| Gancho do webhook (sem segredo fica desligado, só o id da mensagem sai, falha nunca derruba o webhook, PARAR não aciona o agente) | `npm run test:agente` | passa |
| Despachante de ferramentas (`GBH \| FERRAMENTA \| despachar`) | `test_workflow` do MCP do n8n, com os nós de rede fixados e o código dos nós executado de verdade | passou nos 5 casos abaixo |
| WF1 (`GBH \| WF1 \| Entrada e roteamento`) | idem | passou nos 2 casos abaixo |
| WF2 (`GBH \| WF2 \| Agente`) | idem, com o nó do agente fixado | passou (prompt e estimativa de tokens) |

Casos do despachante: (1) busca de produto devolve o SKU só para `buscar_produto` e remove custo, piso e prazo bruto; (2) orçamento: remove custo, piso, margem, endereço e SKU, troca "bike" por "entrega", guarda os valores devolvidos e dispara a mensagem de espera antes do orçamento; (3) ferramenta que falha vira "ferramenta_indisponivel" e avisa o dono; (4) detector de loop encerra a rodada; (5) em teste, PDF, foto e link de pagamento são simulados e nunca vão à API.

Casos do WF1: (1) quatro mensagens seguidas (texto, áudio, imagem, texto) viram um texto único na ordem certa, a objeção de preço escolhe o modelo forte, a resposta vira 3 mensagens com atraso de digitação de 2, 4 e 2 s e as 3 são enviadas; (2) cenário de teste: a saída vai para `testes_conversa`, nada é enviado, avalia e limpa.

## O que NÃO foi testado (honestidade)

- **Os 21 cenários com o modelo de verdade não foram executados.** Para isso o banco de produção precisa da migration (`docs/agente/aplicar-etapa5.sql`) e as Edge Functions `agente-enviar`, `whatsapp-webhook` e `whatsapp-media` precisam ser publicadas. Eu não apliquei nada em produção sem autorização. Por isso **não existem transcrições reais nem custo médio medido por conversa**. Não vou inventar esses números.
- A transcrição de áudio (Groq) e o download da mídia não foram executados (dependem da `whatsapp-media` nova publicada e da credencial Groq nos nós).
- A transcrição real de áudio (Groq) e o envio real pela Meta ficam para a auditoria da Etapa 8 (o cenário 11 usou áudio já transcrito).

## Como rodar os 21 cenários depois de aplicar (cerca de 15 minutos)

1. Aplicar a migration (`docs/agente/aplicar-etapa5.sql`) e publicar as 3 funções (bundles em `docs/agente/funcoes/`).
2. Ligar a IA só para teste: `update agente_config set ia_ligada = true`, e o botão do topo do CRM em "IA ligada". (Os cenários de teste não enviam nada ao WhatsApp, mas o roteamento confere os dois.)
3. Para cada cenário, chamar o gatilho de teste do WF1 (o workflow precisa estar publicado só durante o teste, ou rodar pelo botão "Test workflow" do n8n com o corpo abaixo):

```bash
curl -X POST https://n8n.bauerlab.com.br/webhook/gbh-wf1-teste-3d81e07a95c2b4f6 \
  -H 'Content-Type: application/json' \
  -d '{"caso_id": "<id do caso em testes_conversa>", "limpar": false}'
```

4. Ler o resultado: `select nome, ultimo_status, ultimo_resultado from testes_conversa where nome like 'e5-%' order by nome;` (status automático, falhas, ferramentas usadas, tokens, custo e as mensagens que o agente escreveria).

## O que cada cenário confere automaticamente

Os critérios ficam em `testes_conversa.esperado` e são avaliados por `agente_teste_avaliar`: ferramentas obrigatórias ou proibidas, alerta ao dono, no máximo N mensagens de no máximo 320 caracteres, sem travessão, sem markdown, **nenhum custo, margem, piso, fornecedor, SKU, bicicleta, endereço de retirada nem valor em R$ que nenhuma ferramenta devolveu**, textos que não podem aparecer (por exemplo "20%" quando não há condição), e teto de custo e tokens. Os cenários são: 01 cartão do anúncio, 02 kit, 03 indeciso (G1), 04 desconto sem gordura, 05 caçador de desconto, 06 sem arte, 07 escritório antes de pagar, 08 item raro, 09 "você é robô?", 10 várias mensagens, 11 áudio, 12 injeção de regras, 13 fora do catálogo, 14 quantidade sem SKU, 15 bairro central com item pequeno, 16 banner fora da região, 17 mercado abaixo do piso, 18 falha de ferramenta, 19 condição expirada, 20 pedido de foto, 21 pagamento confirmado (zero chamadas ao modelo). O que a avaliação automática não mede (data de pronto correta, preço acima do piso, tom) deve ser lido nas mensagens gravadas em `ultimo_resultado.saidas`: preço e data só podem vir das ferramentas, e a trava de saída já bloqueia qualquer R$ que não tenha vindo delas.

## Custo estimado (cálculo, não medição)

O n8n não entrega ao workflow os tokens reais do Gemini; o WF2 estima por caracteres (÷ 3,5) e marca `estimativa_de_tokens` no log. O prompt de sistema tem cerca de 3.100 caracteres fixos (cerca de 890 tokens, acima do alvo de 700) mais o contexto. Com os preços de `agente_config.precos_modelo` (estimativas em R$ por 1 milhão de tokens, para você revisar):

| Rodada típica | Tokens estimados (entrada / saída) | Custo estimado |
|---|---|---|
| Resposta simples sem ferramenta, modelo padrão | 1.600 / 80 | cerca de R$ 0,004 |
| Qualificação com 1 busca de produto e 1 de conhecimento | 4.700 / 160 | cerca de R$ 0,010 |
| Orçamento completo (produto, orçamento, PDF, contato) | 9.000 / 300 | cerca de R$ 0,019 |
| Objeção de preço no modelo forte (condição especial) | 7.000 / 250 | cerca de R$ 0,062 |
| Áudio de 1 minuto | transcrição | cerca de R$ 0,002 |
| Atualização do resumo (a cada 8 mensagens) | 1.200 / 120 | menos de R$ 0,001 |

Uma conversa de 6 a 8 rodadas com 1 objeção fica entre R$ 0,10 e R$ 0,25, dentro do custo de IA por conversa (R$ 0,30) usado no piso. **Confirme com os primeiros dias reais** olhando `select avg(custo_estimado) from agente_execucoes where not teste` e a fatura do Google AI Studio.
