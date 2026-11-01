# Mapa do n8n: Sua Gráfica BH

Instância: n8n.bauerlab.com.br (projeto pessoal do dono). Pasta **Sua Gráfica BH**, tag `gbh`. Todos os workflows `GBH |` nascem **desativados**; a ativação é da Etapa 8, depois da auditoria e da autorização do dono. Nenhum workflow de outro projeto foi lido ou alterado.

JSONs exportados (sem credenciais) em `n8n/` (os 9 workflows da Etapa 5 ainda não foram exportados: ver `docs/agente/progresso.md`). Para importar em outra instância: n8n > Workflows > Importar de arquivo, depois selecionar as credenciais nos nós HTTP.

## Workflows (Etapas 3 e 4)

| Workflow | ID no n8n | Arquivo | Gatilho | Estado |
|---|---|---|---|---|
| `GBH \| FERRAMENTA \| pesquisar_preco_mercado` | `V1Bx2NRuPgJxj139` | `n8n/GBH-FERRAMENTA-pesquisar_preco_mercado.json` | Execute Workflow (entradas `sku`, `especificacao`) | Desativado, 32 nós |
| `GBH \| FERRAMENTA \| condicao_especial` | `cxGW9NH43uhINq2h` | `n8n/GBH-FERRAMENTA-condicao_especial.json` | Execute Workflow (entradas `orcamento_id`, `gatilho`) | Desativado, 13 nós |
| `GBH \| WF4 \| Aprendizado de preços` | `qDMVB2BVqdR2qsdm` | `n8n/GBH-WF4-Aprendizado-de-precos.json` | Agenda: segunda 03:30 (America/Sao_Paulo) | Desativado, 8 nós |
| `GBH \| WF4 \| Aquecer cache de madrugada` (opcional) | `bGjqgxT7EJuViM79` | `n8n/GBH-WF4-Aquecer-cache-de-madrugada.json` | Agenda: todo dia 03:00; só age se `parametros_comerciais.aquecer_cache_ligado = true` | Desativado, 5 nós |

| `GBH \| FERRAMENTA \| montar_orcamento` | `fYgrHTafKgpEDlFi` | `n8n/GBH-FERRAMENTA-montar_orcamento.json` | Execute Workflow (`contact_id`, `itens`, `opcoes`) | Desativado, 8 nós |
| `GBH \| FERRAMENTA \| gerar_pdf_orcamento` | `qdIwxubm5jAXCSc2` | `n8n/GBH-FERRAMENTA-gerar_pdf_orcamento.json` | Execute Workflow (`orcamento_id`, `texto`, `acao`) | Desativado, 6 nós |
| `GBH \| FERRAMENTA \| gerar_link_pagamento` | `KsXAvkkMOLZtVMDF` | `n8n/GBH-FERRAMENTA-gerar_link_pagamento.json` | Execute Workflow (`orcamento_id`) | Desativado, 11 nós |
| `GBH \| WF3 \| Orçamento PDF` | `nNh7E3H7Ckl5oV37` | `n8n/GBH-WF3-Orcamento-PDF.json` | Execute Workflow (`contact_id`, `itens`, `opcoes`, `texto`, `com_link`) | Desativado, 9 nós |

| `GBH \| FERRAMENTA \| enviar_foto_produto` | `ybnd6LjGjUO8dgTI` | `n8n/GBH-FERRAMENTA-enviar_foto_produto.json` | Execute Workflow (`termo_ou_sku`, `quantidade_fotos`, `conversation_id`) | Desativado, 6 nós |
| `GBH \| WF4 \| Aquecer fotos de madrugada` (opcional) | `MYEmz3rCIfhMhxxF` | `n8n/GBH-WF4-Aquecer-fotos-de-madrugada.json` | Agenda: todo dia 03:20; só age se `app_settings.fotos.aquecer_ligado = true` | Desativado, 7 nós |

| `GBH \| WF4 \| Mapear fotos da origem` | `iLpTZUm9VLqNLXX1` | `n8n/GBH-WF4-Mapear-fotos-da-origem.json` | Manual ou mensal (dia 1, 02:00); varre o menu da origem e grava `produto_fotos_mapa` | Desativado, credencial já atribuída |

Links: `https://n8n.bauerlab.com.br/workflow/<ID>`. Os quatro workflows de orçamento da sessão interrompida (IDs `p00SlnRlDJMZnyN4`, `2PTqcwVF6FHRfqFy`, `ty3YiJSrHBY9Rg79`, `mOlYxUZ0FHpJyv8W`: webhooks públicos que chamavam funções sem autenticação) foram **arquivados** no n8n (reversível) e substituídos pelos acima.

### Etapa 4: orçamento em PDF
Detalhes em `docs/orcamento-pdf.md`.
* **montar_orcamento:** para cada SKU distinto chama `pesquisar_preco_mercado` (cache de 14 dias; se falhar segue com a fórmula de custo) e depois a função `montar_orcamento` do banco. Devolve JSON mínimo, sem SKU, custo, piso nem margem.
* **gerar_pdf_orcamento:** chama a Edge Function `orcamento-pdf` (Gotenberg, Storage privado, envio no WhatsApp). Devolve `{ok, orcamento_id, numero, enviado, ja_enviado, renovado}`; se o orçamento venceu, o `orcamento_id` devolvido é o do novo.
* **gerar_link_pagamento:** `preparar_link_pagamento` (roda `validar_margem`) > `mp-criar-link` (Mercado Pago já integrado) > `orcamento_registrar_link`. Devolve `{ok, link, valida_ate, texto_curto}` ou `{ok:false, motivo, alternativa}`.
* **WF3:** montar > gerar e enviar PDF > (opcional) link de pagamento.
* **condicao_especial:** o gancho de PDF da Etapa 3 virou a chamada real a `gerar_pdf_orcamento` (acao `gerar`) para o orçamento atualizado; o envio ao cliente é do agente.

### Etapa 4B: fotos de produto
Detalhes em `docs/fotos-de-produto.md`. **enviar_foto_produto** chama a Edge Function `produto-fotos` (limites, cache de 30 dias, processamento, verificação de marca e envio) e devolve só `{enviadas, legenda_sugerida}`; sem foto devolve `{enviadas: 0, sem_foto: true, orientacao}`. **Aquecer fotos de madrugada** pede ao banco até 5 grupos (lista vazia se o aquecimento estiver desligado) e chama a função um grupo por vez com pausa de 5 s.

### pesquisar_preco_mercado
Cache de 14 dias no banco (`consultar_cache_preco_mercado`) > se vencido, 3 buscas (SearXNG por padrão; Tavily ou Serper por configuração) > um domínio por vez com robots, termos e intervalo (`reservar_acesso_dominio`) > leitura direta ou com navegador (Playwright ou Firecrawl) > extração por regras (quantidade, papel, gramatura, tamanho e acabamento têm de bater; o primeiro preço depois da quantidade) > modelo pequeno só se nenhuma regra achou (texto truncado em 3.500 caracteres, preço precisa aparecer literalmente) > `registrar_pesquisa_mercado` (outliers, mediana, confiança). Limite de cerca de 45 s; falha ou estouro devolve `sem_dado`. Configuração (fonte de busca, URLs internas, leitor de JavaScript, páginas por pesquisa) na caixa **Início e configuração**. Infraestrutura em `docs/agente/infra-busca.md`.

### condicao_especial
`oferecer_condicao_especial` no banco decide e registra (a função do banco é a única que calcula) > se houver benefício e pedido ligado, `mp-criar-link` com `forcar_novo` e validade restante da condição (24 h) > `condicao_registrar_link`. Devolve `{tipo, texto_curto, valor, valida_ate}` mais `link_pagamento` e `orcamento_id`. Sem condição: devolve só `sem_condicao` e uma orientação (nunca o motivo interno: margem, piso ou caçador). **Gancho de PDF** do orçamento atualizado marcado para a Etapa 4. Gatilhos: G1 pelo agente (WF2, Etapa 5), G2 e G3 pelos follow-ups (Etapa 7).

### Aprendizado de preços
Cinco chamadas ao banco, sem modelo de IA: expirar condições e orçamentos vencidos, ajustar o fator por grupo, detectar padrões de desconto, relatório das condições, resumo semanal (alertas de baixa gravidade). Em paralelo, o banco também expira condições sozinho a cada 10 minutos (`pg_cron`).

## Credenciais necessárias (criar no n8n, nunca no repositório)

| Nome exato | Tipo | Onde é usada | Obrigatória? |
|---|---|---|---|
| `GBH Supabase (service role)` | Supabase API (host `https://bhlosshvwmlyzhbghsrc.supabase.co` + Service Role Secret) | todos os nós HTTP que falam com o banco, com `mp-criar-link`, `orcamento-pdf` e `produto-fotos` | **Sim** |
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
| `montar_orcamento(contact_id, itens, opcoes)` | `GBH | FERRAMENTA | montar_orcamento` | número SG, itens, subtotal, arte, frete, total, data prevista, validade, upsell (sem SKU, custo, piso, margem) |
| `gerar_pdf_orcamento(orcamento_id, texto)` | `GBH | FERRAMENTA | gerar_pdf_orcamento` | `{ok, orcamento_id, numero, enviado}` |
| `gerar_link_pagamento(orcamento_id)` | `GBH | FERRAMENTA | gerar_link_pagamento` | `{ok, link, valida_ate, texto_curto}` |
| `oferecer_condicao_especial(orcamento_id, gatilho)` | `GBH \| FERRAMENTA \| condicao_especial` | `{tipo, texto_curto, valor, valida_ate}` |
| `pesquisar_preco_mercado` | **não é ferramenta do agente**: roda dentro da montagem do orçamento (WF3/WF4) antes de `calcular_preco` | interno |
| `enviar_foto_produto(termo_ou_sku, quantidade_fotos, conversation_id)` | `GBH \| FERRAMENTA \| enviar_foto_produto` | `{enviadas, legenda_sugerida}` (sem URL, origem nem SKU) |
| `aplicar_desconto` | **removida** (função e ferramenta); nada a migrar, nunca existiu dado | - |

## Regras ao criar workflows

- Pasta `Sua Gráfica BH`, tag `gbh`, nome `GBH | <WF ou FERRAMENTA> | ...`, nota (sticky) com objetivo, entradas, saídas e dependências, nós com nomes em português.
- Criar e alterar **somente pelo MCP do n8n**, validar antes de salvar, testar com dados simulados e exportar o JSON sem credenciais para `n8n/`.
- Segredos só em credenciais do n8n. Usar o único webhook da Meta que já existe; nunca criar outro.
- Retentativas com espera nas chamadas externas, tempos limite definidos, idempotência em tudo que vem de webhook.
- Pendente de etapas futuras: `GBH | WF9 | Erros` (workflow global de erros ligado a todos os outros), WF5 a WF8.

## Workflows da Etapa 5 (agente de atendimento)

| Workflow | ID no n8n | Gatilho | Estado |
|---|---|---|---|
| `GBH \| WF1 \| Entrada e roteamento` | `DO8wiALq6q1jZbYN` | Webhook POST `/webhook/gbh-wf1-entrada-7f3a9c2e41b8d605` (chamado pelo `whatsapp-webhook`) e Webhook de teste `/webhook/gbh-wf1-teste-3d81e07a95c2b4f6` (corpo `{caso_id, limpar}`) | Desativado, 61 nós |
| `GBH \| WF2 \| Agente` | `NKN7RgAJmRWZXRIT` | Execute Workflow (chamado pelo WF1) | Desativado, 26 nós (AI Agent Gemini, 11 ferramentas) |
| `GBH \| FERRAMENTA \| despachar` | `1rm82046svIE1TLl` | Execute Workflow (chamado pelas 11 ferramentas do WF2) | Desativado, 32 nós |
| `GBH \| FERRAMENTA \| buscar_conhecimento` | `MJLl5aJkBA2t9jfS` | Execute Workflow (`pergunta`, `conversation_id`) | Desativado |
| `GBH \| FERRAMENTA \| buscar_produto` | `2BkgUaqxkS198jmA` | Execute Workflow (`termo`, `quantidade`, `filtros`) | Desativado |
| `GBH \| FERRAMENTA \| salvar_contato` | `JDjfx586IeN9YaWN` | Execute Workflow (`contact_id` e campos) | Desativado |
| `GBH \| FERRAMENTA \| verificar_frete` | `JQp5BTgu2Hum8PfE` | Execute Workflow (`cep_ou_bairro`, `itens`) | Desativado |
| `GBH \| FERRAMENTA \| agendar_followup` | `GVyk2nZPlf5QNWti` | Execute Workflow (`conversation_id`, `tipo`, `quando`) | Desativado |
| `GBH \| FERRAMENTA \| chamar_dono` | `TwvgUc15htbWkyDu` | Execute Workflow (`conversation_id`, `motivo`, `gravidade`) | Desativado |

Pasta Sua Gráfica BH, tag `gbh`, nota (sticky) em todos. As ferramentas das Etapas 3, 4 e 4B (`montar_orcamento`, `gerar_pdf_orcamento`, `gerar_link_pagamento`, `condicao_especial`, `enviar_foto_produto`) continuam as mesmas e agora são chamadas pelo despachante. Arquitetura, regras e como editar em `docs/agente-ia.md` (seção Etapa 5).

**Credenciais usadas (já existem na instância):** `Supabase account` (service role, em todos os nós HTTP), `Google Gemini(PaLM) Api account` (modelos do WF2 e do resumo) e `Groq account` (transcrição de áudio, `whisper-large-v3-turbo`). Foram atribuídas aos nós pelo MCP; confira ao abrir cada workflow.

**Segredos novos nas Edge Functions (não ficam no n8n):** `N8N_WF1_URL` (URL de produção do webhook do WF1) e `N8N_WF1_TOKEN` (qualquer texto longo; o webhook confere só que o cabeçalho `x-gbh-token` veio, porque o n8n não lê variáveis de ambiente nos nós. Para validar o valor, ligue uma credencial Header Auth ao nó "Mensagem de entrada" do WF1 com o mesmo valor).

**Testes pelo MCP:** `test_workflow` com os nós de rede fixados (despachante, WF1 e WF2). Os cenários com o modelo real estão em `docs/agente/etapa5-testes.md`.

**Pendente de etapas futuras:** `GBH | WF9 | Erros`, WF5 a WF8.
