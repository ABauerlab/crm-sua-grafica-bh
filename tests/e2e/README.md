# Teste ponta a ponta do atendimento (Etapa 8B)

Prova, com conversas simuladas, que o atendimento da Laura e do João Victor está bom e seguro. Serve como teste de regressão antes de qualquer mudança no prompt, nas ferramentas, no conhecimento ou nas regras.

## Como funciona

1. **Cenários** (`cenarios.ts`): conversas de vários turnos, cada fala com 3 formulações, por categoria (anúncio, funil, objeção, produto, entrega, pagamento, arte, exceção, técnico). `critico: true` marca os que podem gerar falha crítica.
2. **Personas** (`personas.ts`): apressado, indeciso, pechincheiro, desconfiado, grosseiro, empresário, idosa, estudante, mensagens picadas, gírias, áudio, imagem, arte ruim, estrangeiro, malicioso, menor.
3. **Execução contra o fluxo real**: o webhook de teste do WF1 roda o agente com o modelo real e as ferramentas reais do banco (busca, preço, prazo, frete, condição especial, conhecimento). **Nada vai ao WhatsApp**: a saída é gravada em `testes_conversa`/`e2e_mensagens`. PDF, foto e link de pagamento são simulados no modo de teste do n8n. Mercado Pago nunca é chamado.
4. **Verificações determinísticas** (`verificacoes.ts`, `executor.ts`): regex e consultas ao banco para cada falha crítica (vazamento, preço inventado, preço abaixo da trava, endereço antes do pagamento, promessa de reembolso, negar ser virtual, link sem validação, promoção a quem pediu PARAR, resposta duplicada) e para as regras de tom (travessão, markdown, mais de 3 linhas, mais de uma pergunta, prazo sem data).
5. **Juiz independente** (`juiz.ts`): um segundo modelo que não viu a construção recebe só o diálogo e as regras públicas e devolve nota 0 a 10 nos 7 critérios, as falhas e a frase exata que errou.
6. **Aprovação da rodada** (`relatorio.ts`): zero falhas críticas, média geral de 9 ou mais e nenhum critério com média abaixo de 8. Duas rodadas completas seguidas.

## Segurança do teste

- Contatos `TESTE_` com `contacts.is_teste = true`. A limpeza (`select public.e2e_limpar()`) só apaga o que tem a flag, inclusive orçamentos e preços praticados do teste (que não podem poluir o aprendizado de preços).
- Teto de tokens (`E2E_TETO_TOKENS`, padrão 600000) com aviso aos 80% e parada ao atingir.
- Intervalo mínimo entre chamadas ao n8n (`E2E_INTERVALO_MS`, padrão 1100 ms). O modo de teste não consulta o site de fotos.
- Nenhum segredo vai a log ou relatório.

## Rodar

```bash
npm run test:e2e                                   # autoteste offline (entra no npm test)

export E2E_SUPABASE_URL=https://<projeto>.supabase.co
export E2E_SERVICE_KEY=...                         # chave de serviço, só na sua máquina
export E2E_N8N_TESTE_URL=https://<n8n>/webhook/<caminho do webhook de teste do WF1>
export ANTHROPIC_API_KEY=...                       # juiz

npm run e2e                                        # tudo, 3 formulações por cenário
npm run e2e -- --critico                           # só o que pode gerar falha crítica
npm run e2e -- --categoria=objecao,pagamento
npm run e2e -- --cenario=excecao-e-robo --formulacao=1
npm run e2e -- --sem-juiz                          # só verificações determinísticas
npm run e2e -- --exportar-juiz                     # grava os prompts do juiz para outro agente julgar
npm run e2e -- --importar-juiz=DIR                 # lê vereditos JSON em vez de chamar a API
npm run e2e -- --limpar                            # só limpa os contatos de teste
```

Resultados em `tests/e2e/resultados/<rodada>/` (ignorado pelo git): um JSON por conversa, `resumo.json` e `matriz.md`.

### Sem chave de serviço (sessão de agente com MCP)

Veja `PROTOCOLO-RETRATOS.md`: `plano.ts` gera os lotes, cada turno roda com `e2e_criar_caso` e `e2e_aguardar` e `avaliar.ts` aplica as mesmas verificações e consolida.

### Executor dentro do banco (Etapa 8C, sem chave de serviço)

Roda a rodada inteira no Supabase com `pg_cron` + `pg_net`, contra o clone de teste do WF2 (`GBH | TESTE | Entrada de teste (clone)`), que só aceita `teste = true` e não tem nó de envio ao WhatsApp.

1. Guarde em `e2e_config` (nunca no repositório): `url_teste` (webhook de produção da entrada de teste), `token_export` (texto aleatório) e `teto_custo` (padrão 15).
2. Enfileire: `select e2e_enfileirar('c3', '<json de plano.ts: [{cenario, formulacao, persona, turnos:[entradas]}]>'::jsonb);` (ou copie linhas de outra rodada com `insert ... select`).
3. Ligue: `select cron.schedule('e2e-c3', '10 seconds', $$select public.e2e_avancar('c3', 8, 240, 0)$$);` e acompanhe com `select e2e_andamento('c3');`. Ao terminar, `select cron.unschedule('e2e-c3');`.
4. Baixe os retratos: `E2E_SUPABASE_URL=... E2E_ANON_KEY=<publicável> E2E_EXPORT_TOKEN=... node tests/e2e/exportar.ts --rodada=c3 --saida=DIR`, depois `avaliar.ts` e o juiz (`PROTOCOLO-JUIZ.md`).

## Cenários só de banco

`sql/tecnicos.sql` cobre o que não depende do modelo: webhook duplicado, mensagens fora de ordem, janela de 24 h fechada, opt-out, modo humano e concorrência de gravação. Os follow-ups com relógio acelerado (F1 a F4, pagamento pendente, limite de 1 por dia entre 8h e 20h) estão em `supabase/tests/followup_etapa7.sql`.

## Como acrescentar um cenário

Inclua um objeto em `cenarios.ts` com 3 formulações por fala e rode `npm run test:e2e` (ele confere que todo cenário tem 3 formulações e id único). Se a falha encontrada for de conhecimento, o ajuste vai em `conhecimento` (e em `docs/agente/conhecimento_v2.json`), não no teste.
