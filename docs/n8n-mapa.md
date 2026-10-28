# Mapa do n8n: Sua Gráfica BH

Instância: n8n.bauerlab.com.br (projeto pessoal do dono). Pasta **Sua Gráfica BH**, tag `gbh`. Todos os workflows `GBH |` nascem **desativados**; a ativação é da Etapa 8, depois da auditoria e da autorização do dono. Nenhum workflow de outro projeto foi lido ou alterado.

JSONs exportados (sem credenciais) em `n8n/`. Para importar em outra instância: n8n > Workflows > Importar de arquivo, depois selecionar as credenciais nos nós HTTP.

## Workflows (Etapa 3)

| Workflow | ID no n8n | Arquivo | Gatilho | Estado |
|---|---|---|---|---|
| `GBH \| FERRAMENTA \| pesquisar_preco_mercado` | `V1Bx2NRuPgJxj139` | `n8n/GBH-FERRAMENTA-pesquisar_preco_mercado.json` | Execute Workflow (entradas `sku`, `especificacao`) | Desativado, 32 nós |
| `GBH \| FERRAMENTA \| condicao_especial` | `cxGW9NH43uhINq2h` | `n8n/GBH-FERRAMENTA-condicao_especial.json` | Execute Workflow (entradas `orcamento_id`, `gatilho`) | Desativado, 13 nós |
| `GBH \| WF4 \| Aprendizado de preços` | `qDMVB2BVqdR2qsdm` | `n8n/GBH-WF4-Aprendizado-de-precos.json` | Agenda: segunda 03:30 (America/Sao_Paulo) | Desativado, 8 nós |
| `GBH \| WF4 \| Aquecer cache de madrugada` (opcional) | `bGjqgxT7EJuViM79` | `n8n/GBH-WF4-Aquecer-cache-de-madrugada.json` | Agenda: todo dia 03:00; só age se `parametros_comerciais.aquecer_cache_ligado = true` | Desativado, 5 nós |

Links: `https://n8n.bauerlab.com.br/workflow/<ID>`.

### pesquisar_preco_mercado
Cache de 14 dias no banco (`consultar_cache_preco_mercado`) > se vencido, 3 buscas (SearXNG por padrão; Tavily ou Serper por configuração) > um domínio por vez com robots, termos e intervalo (`reservar_acesso_dominio`) > leitura direta ou com navegador (Playwright ou Firecrawl) > extração por regras (quantidade, papel, gramatura, tamanho e acabamento têm de bater; o primeiro preço depois da quantidade) > modelo pequeno só se nenhuma regra achou (texto truncado em 3.500 caracteres, preço precisa aparecer literalmente) > `registrar_pesquisa_mercado` (outliers, mediana, confiança). Limite de cerca de 45 s; falha ou estouro devolve `sem_dado`. Configuração (fonte de busca, URLs internas, leitor de JavaScript, páginas por pesquisa) na caixa **Início e configuração**. Infraestrutura em `docs/agente/infra-busca.md`.

### condicao_especial
`oferecer_condicao_especial` no banco decide e registra (a função do banco é a única que calcula) > se houver benefício e pedido ligado, `mp-criar-link` com `forcar_novo` e validade restante da condição (24 h) > `condicao_registrar_link`. Devolve `{tipo, texto_curto, valor, valida_ate}` mais `link_pagamento` e `orcamento_id`. Sem condição: devolve só `sem_condicao` e uma orientação (nunca o motivo interno: margem, piso ou caçador). **Gancho de PDF** do orçamento atualizado marcado para a Etapa 4. Gatilhos: G1 pelo agente (WF2, Etapa 5), G2 e G3 pelos follow-ups (Etapa 7).

### Aprendizado de preços
Cinco chamadas ao banco, sem modelo de IA: expirar condições e orçamentos vencidos, ajustar o fator por grupo, detectar padrões de desconto, relatório das condições, resumo semanal (alertas de baixa gravidade). Em paralelo, o banco também expira condições sozinho a cada 10 minutos (`pg_cron`).

## Credenciais necessárias (criar no n8n, nunca no repositório)

| Nome exato | Tipo | Onde é usada | Obrigatória? |
|---|---|---|---|
| `GBH Supabase (service role)` | Supabase API (host `https://bhlosshvwmlyzhbghsrc.supabase.co` + Service Role Secret) | todos os nós HTTP que falam com o banco e com `mp-criar-link` | **Sim** |
| `Google Gemini(PaLM) Api account` | já existe na instância | modelo pequeno de último recurso (pesquisa de preço) | Sim, para o último recurso |
| `GBH Tavily` | Autenticação personalizada: cabeçalho `Authorization: Bearer chave` | busca, se `fonte_busca = tavily` | Não |
| `GBH Serper` | Autenticação personalizada: cabeçalho `X-API-KEY` | busca, se `fonte_busca = serper` | Não |
| `GBH Firecrawl` | Autenticação personalizada: cabeçalho `Authorization: Bearer chave` | leitura com JavaScript, se `leitura_js = firecrawl` | Não |
| `GBH Renderer` (opcional) | cabeçalho `x-token` | só se `RENDERER_TOKEN` foi definido no Coolify | Não |

Os nós HTTP foram criados sem credencial atribuída (limitação de importação do MCP): abra cada workflow e escolha a credencial. Passo a passo em `docs/agente/infra-busca.md`.

## Ferramentas do agente (Etapa 5 liga ao WF2)

| Ferramenta | Workflow ou função | Retorno ao agente |
|---|---|---|
| `buscar_produto`, `buscar_conhecimento`, `agente_preco` | funções do banco (Etapa 2) | sem custo nem piso |
| `oferecer_condicao_especial(orcamento_id, gatilho)` | `GBH \| FERRAMENTA \| condicao_especial` | `{tipo, texto_curto, valor, valida_ate}` |
| `pesquisar_preco_mercado` | **não é ferramenta do agente**: roda dentro da montagem do orçamento (WF3/WF4) antes de `calcular_preco` | interno |
| `aplicar_desconto` | **removida** (função e ferramenta); nada a migrar, nunca existiu dado | - |

## Regras ao criar workflows

- Pasta `Sua Gráfica BH`, tag `gbh`, nome `GBH | <WF ou FERRAMENTA> | ...`, nota (sticky) com objetivo, entradas, saídas e dependências, nós com nomes em português.
- Criar e alterar **somente pelo MCP do n8n**, validar antes de salvar, testar com dados simulados e exportar o JSON sem credenciais para `n8n/`.
- Segredos só em credenciais do n8n. Usar o único webhook da Meta que já existe; nunca criar outro.
- Retentativas com espera nas chamadas externas, tempos limite definidos, idempotência em tudo que vem de webhook.
- Pendente de etapas futuras: `GBH | WF9 | Erros` (workflow global de erros ligado a todos os outros), WF1, WF2, WF3 (PDF), WF5 a WF8.
