# Protocolo de execução por retratos (sem chave de serviço)

Use quando quem roda o teste só tem o MCP do Supabase e acesso ao webhook de teste do n8n (por exemplo, uma sessão de agente). O resultado é o mesmo do `npm run e2e`: um arquivo JSON por conversa, avaliado depois por `tests/e2e/avaliar.ts`.

Nada vai ao WhatsApp: o webhook de teste do WF1 roda o agente com o modelo real, as ferramentas reais do banco (preço, prazo, frete, condição especial, conhecimento) e grava a saída em `testes_conversa`; PDF, foto e link de pagamento são simulados no modo de teste.

## Para cada tarefa do lote (um cenário, uma formulação)

Leia o plano (`lote-N.json`). Para cada turno `n` da tarefa, em ordem:

1. **Criar o caso** (SQL no projeto `bhlosshvwmlyzhbghsrc`):
   `select public.e2e_criar_caso('<nome_caso>', '<entradas como JSON>'::jsonb) id;`
   Use `entradas` exatamente como está no plano. No turno 1 não há `continuar_conversation`. A partir do turno 2, troque `__CONVERSA__` pelo `conversation_id` devolvido no retrato do turno 1.
   Aspas simples dentro do JSON viram duas aspas simples (`''`) no SQL; use `$json$ ... $json$` para não errar.
2. **Disparar** (Bash, uma vez só por caso):
   `curl -sS -m 60 -o /dev/null -w "%{http_code}\n" -X POST "$URL_TESTE" -H 'content-type: application/json' -d '{"caso_id":"<id>","limpar":false}'`
   (resposta 200 sem corpo é normal: o n8n processa em segundo plano). Nunca repita o disparo do mesmo caso.
3. **Aguardar e coletar** (SQL): `select public.e2e_aguardar('<id>'::uuid, 45) snap;`
   O retrato traz `status`, `saidas` (o que o agente "enviaria"), `ferramentas`, `valores_vistos`, `links_vistos`, `links_orcamento`, `alerta`, `violacao_lucro`, `tokens`, `custo`, `conversation_id` e `contact_id`.
   Se `status` vier nulo, o turno estourou o tempo: espere mais uma vez com o mesmo comando; o limite da ferramenta MCP é 60 s por chamada, então use 45 e repita o mesmo comando até 3 vezes; se continuar nulo, registre assim mesmo (o avaliador marca erro) e siga para a próxima tarefa.

## Arquivo de saída

Grave `<pasta de retratos>/<cenario>.f<formulacao>.json`:

```json
{ "cenario": "...", "formulacao": 1,
  "turnos": [ { "n": 1, "cliente": ["texto enviado"], "snapshot": { ...retrato exato do e2e_aguardar... } } ] }
```

`cliente` é a lista `cliente` do plano. `snapshot` é o objeto do retrato sem alterações (sem o campo `ok`, se preferir).

## Regras

- Não interprete nem avalie as respostas: só execute e registre. O juiz é outro agente.
- Não altere nenhuma outra tabela, workflow ou função. Não apague nada além do que o protocolo manda.
- Nunca imprima segredos. O URL do webhook de teste vem no prompt da tarefa.
- No fim, `select public.e2e_apagar_casos('<rodada>');` remove os casos da rodada (a limpeza dos contatos de teste é feita por quem coordena).
