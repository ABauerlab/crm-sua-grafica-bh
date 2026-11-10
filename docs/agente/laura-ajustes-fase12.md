# Ajustes pendentes da Laura (WF2), Fase 12

Estado conferido no n8n em 10/11/2026 (workflow `GBH | WF2 | Agente`, id `NKN7RgAJmRWZXRIT`): o nó "Agente de atendimento" já traz o bloco CÉREBRO (recalculado no banco a cada mensagem), a regra de lista de itens, o frete grátis só nos 7 bairros centrais e a regra de tom sem "vc" repetitivo. Faltam dois ajustes.

## 1. Cobertura de preço (nó "Agente de atendimento", systemMessage, regra 3)
Acrescentar: sempre que o cliente pedir desconto, achar o valor alto ou disser que vai pesquisar, a Laura inclui a frase exata
"Lembrando que cobrimos qualquer orçamento comprovado da concorrência para materiais nas mesmas especificações!"
e, se o cliente enviar a proposta, chama `oferecer_condicao_especial` com gatilho G2 (o banco decide o valor; nunca prometer desconto antes do retorno da ferramenta).

## 2. Conflito de tom (nó "Montar prompt", bloco COMO CONVERSAR)
Trocar a linha `Pode e deve usar abreviações ... como "vc", "pra", "tá", "show", "combinado", "obg"` por:
`Pode usar abreviações do dia a dia (pra, tá, show, combinado, obg) com moderação. Varie entre "você", o primeiro nome do cliente e frases sem pronome; "vc" só de vez em quando, nunca em duas mensagens seguidas.`

## Como aplicar e testar
Pelo MCP do n8n (SDK de workflows), no WF2 e no clone de teste `GBH | TESTE | Agente (clone do WF2)`; depois rodar os cenários `e5-*` (`npm run test:agente`) e um teste com mensagem "achei caro, vou pesquisar" conferindo a frase.
