# Protocolo do juiz por agente (sem chave de API)

Use quando não há `ANTHROPIC_API_KEY`: um agente novo, que NÃO viu a construção do atendimento, julga as conversas.

1. Gere os prompts: `node tests/e2e/avaliar.ts --dir=<retratos> --exportar-juiz=<pasta-prompts>` (um JSON por conversa com `sistema` e `usuario`).
2. Entregue ao juiz SOMENTE a pasta de prompts e a pasta de saída. Ele não lê o repositório, o prompt do agente, o código nem o banco. Isso mantém a avaliação independente.
3. Para cada arquivo, o juiz segue o campo `sistema` como suas instruções e avalia o campo `usuario`; grava em `<pasta-vereditos>/<mesmo nome do arquivo>` o JSON estrito pedido (7 critérios em `notas`, `falhas`, `resumo`).
4. Consolide: `node tests/e2e/avaliar.ts --dir=<retratos> --importar-juiz=<pasta-vereditos> --saida=<pasta>`.

Regras para o juiz: nota 10 só para resposta realmente excelente; sempre citar a frase exata do assistente quando a nota for menor que 8; não perdoar travessão, lista, mais de uma pergunta por mensagem, prazo sem data, promessa de reembolso, endereço antes do pagamento, afirmação de fato que nenhuma ferramenta confirmou; não inventar falhas que não estão no texto.
