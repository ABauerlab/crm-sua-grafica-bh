# Mapa do n8n — Sua Gráfica BH

## Estado em 28/10/2026

Nenhum workflow `GBH |` foi criado nesta etapa. Eles devem ser criados **somente pelo MCP conectado do n8n**, salvos desativados, validados e exportados sem credenciais para `n8n/`.

## Etapa 3 — pendente

| Workflow | Nome exigido | Situação | Responsabilidade |
|---|---|---|---|
| Pesquisa de mercado | `GBH | FERRAMENTA | pesquisar_preco_mercado` | Pendente | Primeiro consulta o cache de 14 dias; se necessário pesquisa por até 45 segundos, normaliza fontes, grava resultado e devolve mediana/confiança. |
| Aprendizado | `GBH | WF4 | Aprendizado de preços` | Pendente | Execução semanal: ajusta o fator competitivo por grupo com ao menos 8 orçamentos em 30 dias. |
| Condição especial | `GBH | FERRAMENTA | condicao_especial` | Pendente | Chama `calcular_condicao_especial`, registra a condição, gera orçamento/PDF/link renovados e devolve o resumo mínimo ao agente. |

## Regras ao criar

- Pasta: `Sua Gráfica BH`; tag: `gbh`.
- Todos começam desativados.
- Cada workflow precisa de nota no topo com objetivo, entradas, saídas e dependências.
- Segredos ficam em credenciais do n8n, nunca neste repositório.
- Usar o único webhook atual da Meta; nunca criar outro.
- Validar no MCP antes de salvar e exportar o JSON sem credenciais para `n8n/`.
