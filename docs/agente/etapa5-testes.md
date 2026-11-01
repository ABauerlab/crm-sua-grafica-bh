# Etapa 5: relatório de testes do agente (WF1 e WF2)

## Atualização: migration aplicada e primeira execução real (01/11/2026)

**Aplicado em produção (autorizado):** migration em 3 partes (24 funções `agente_*`, 21 cenários, permissões: só a service role executa; os advisors não mostram nada novo). IA desligada de novo ao fim; dados de teste apagados.

**O que a execução real mostrou (cenário 01):**
- O fluxo WF1 > WF2 funcionou de ponta a ponta com o modelo real: debounce, contexto, resposta em 3 mensagens curtas, trava de saída, registro, avaliação automática e gravação em `testes_conversa` (o cenário foi marcado "falhou" corretamente por não ter usado `buscar_produto`).
- **`gemini-2.5-flash` devolve 404 na sua conta.** Troquei em `agente_config` para `gemini-3-flash-preview` (funciona). `gemini-3-pro-preview` (modelo forte) **não foi verificado**.
- **As ferramentas falharam: "Workflow is not active".** O nó "Call n8n Workflow Tool" só executa o sub-workflow se ele estiver **publicado**, e o despachante só publica se os 11 sub-workflows (e `pesquisar_preco_mercado`, chamado por `montar_orcamento`) também estiverem. Isso conflita com a regra de manter tudo desativado até a Etapa 8. Você autorizou ativar só o despachante, mas o sistema bloqueou a publicação de 2 dos workflows como "deploy em produção" e eu parei, desfiz as 8 publicações que tinham passado e voltei ao estado desativado. **Os 21 cenários seguem sem rodar.**
- Quando as ferramentas falharam, o agente se comportou bem: não inventou preço, tentou `chamar_dono` e perguntou arte e quantidade. Mas escreveu "Temos opções a partir de 100 unidades", um fato que nenhuma ferramenta devolveu: a trava de saída só confere valores em R$ e vazamentos, não fatos numéricos soltos. Fica como risco conhecido (ver `progresso.md`).
- A estimativa de tokens estava inflada pelas assinaturas internas do Gemini (23.970 estimados contra cerca de 3.500 reais por chamada). Corrigida no nó do WF2 (agora só conta o nome e os argumentos da ferramenta e a resposta dela). O uso real aparece nos dados de execução do n8n (`llm.tokens.in`), mas não é acessível ao workflow.


Data: 01/11/2026. Tudo abaixo foi feito **sem aplicar nada em produção** e com os workflows **desativados**.

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
- Tom, naturalidade e decisão de chamar a ferramenta certa são comportamento do modelo e só aparecem na execução real.

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
