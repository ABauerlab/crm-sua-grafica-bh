# Runbook da Laura (agente de WhatsApp): estado de 11/11/2026

Documento de passagem de bastão. Descreve como o agente funciona hoje, o que foi corrigido na estabilização de 11/11/2026, como testar e o que ainda é risco. Os workflows exportados ficam em `n8n/` (sem credenciais); a instância n8n continua sendo a fonte da verdade em produção, o repositório é a cópia de segurança.

## Caminho de uma mensagem
1. `whatsapp-webhook` (Edge Function) grava a mensagem e avisa o WF1 (`GBH | WF1 | Entrada e roteamento`).
2. WF1: `agente_entrada` decide se responde, debounce de 8 s, trava por conversa (`agente_iniciar`; se ocupada espera 30 s e tenta de novo), trata áudio (Groq), imagem e documento, junta o texto (normaliza `50 por 50`, `50×50` para `50x50` e `400 uni` para `400 unidades`), carrega `agente_contexto` e chama o WF2.
3. WF2 (`GBH | WF2 | Agente`): nó "Adaptar contexto" converte o contexto do banco para o formato do prompt (histórico, orçamento aberto, pedido ativo, data e hora de São Paulo, sem o campo `cerebro`), o AI Agent (Gemini) chama as ferramentas via `GBH | FERRAMENTA | despachar`, a trava de saída (`agente_saida_segura`) revisa a resposta.
4. WF1 divide a resposta em até 3 mensagens curtas e envia por `agente-enviar`, reconferindo modo humano e pagamento antes de cada parte.

## O que foi corrigido em 11/11/2026
- **Perda de memória:** o WF2 não recebia o histórico no formato esperado. O nó "Adaptar contexto" resolveu (mantém imagem, áudio e documento mesmo sem texto, últimas 20 mensagens, descarta mensagem de entrada final repetida).
- **Respostas vazias ou "Calling tools:":** o Gemini às vezes devolve vazio ou o texto da chamada de ferramenta. O WF2 tem um laço de repetição (até 2 vezes): "Resposta vazia ou vazou ferramenta?" > "Zerar contadores da rodada" (PATCH em `agente_execucoes.ferramentas = {}`, senão a repetição herda o limite estourado) > "Repetir a chamada ao agente". Sem resposta, sai a "Resposta neutra" (`Deixa eu confirmar isso certinho aqui e já te respondo, tá?`), nunca silêncio.
- **WF1:** "Dividir em mensagens curtas" aceita `texto`, `output` e `text`; o envio não engole falha; mensagem de mídia sem texto não some do grupo.
- **Cobertura de preço e abreviações:** regras 1 a 21 no `systemMessage` do WF2 (cobertura com `oferecer_condicao_especial` G2 só com comprovante, quantidades abreviadas, dono chamado só quando há motivo real).
- **Trava de saída (banco):** sobrecargas ambíguas renomeadas (`agente_saida_base_execucao`, `agente_promessas_indevidas_execucao`); a trava não barra mais recusa de desconto ("não consigo dar desconto...") nem "brindes" como item. Migrations `20261111170000` a `20261111182000`.
- **`chamar_dono`:** envia `p_tipo: "agente_chamado"` (evita sobrecarga ambígua).
- **Timeout:** trava do WF2 com timeout de 30 s e 4 tentativas; agente com 3 tentativas.

## Como testar
- Cenários em `testes_conversa` (`e5-01` a `e5-21`, `mvp-A1/A2`, `mvp-B*`, `mvp-C*`). Rodar um: POST no webhook de teste do WF1 (caminho em `docs/n8n-mapa.md`) com `{ "caso_id": "<id>", "limpar": true }`; o resultado fica em `testes_conversa.ultimo_status` e `ultimo_resultado`. Em teste, PDF, foto, link e arte são simulados no despachante (link `https://exemplo.com.br/pagar/teste`).
- Não rode os 21 de uma vez sem pausa: o avaliador estoura o tempo do banco sob carga e o resultado fica falso. Leia o resultado só depois da rodada terminar (`agente_execucoes.status`).
- `npm run test:agente` testa só o gancho do webhook (assinatura e disparo do WF1). Não cobre os cenários e5.
- Link de pagamento só sai com `pdf_enviado_em` e uma mensagem do cliente depois do PDF com palavra de aprovação (`preparar_link_pagamento`).

## Riscos conhecidos
- Gemini não determinístico; `gemini-flash-latest` (alias) para padrão, forte e resumo em `agente_config`: considerar fixar uma versão.
- Caminho do link do Mercado Pago pelo agente foi validado em teste simulado, não com pedido real de ponta a ponta.
- Picos de carga no banco podem estourar a trava (há tentativas e resposta neutra).
- Workflows ainda fora do repositório: `buscar_conhecimento`, `buscar_produto`, `salvar_contato`, `verificar_frete`, `agendar_followup`, o clone do WF2 e o `despachar` pode estar defasado em relação à instância. Reexportar pelo MCP do n8n (`get_workflow_details`) quando for mexer neles.

## Como reexportar um workflow
`get_workflow_details` no MCP do n8n, manter só `name`, `nodes`, `connections`, `settings` e `tags`, remover `webhookId` e qualquer credencial, gravar em `n8n/` com indentação de 2 espaços. Conferir que não há chave, token ou JWT no arquivo antes do commit.
