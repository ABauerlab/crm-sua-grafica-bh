# Agente de IA: pontos de integração

O CRM já guarda tudo que o agente precisa. Ele lê e escreve direto no Supabase (chave **service role**, só no servidor do agente, nunca no front) e não exige mudar nenhuma tela.

## Regra de ouro
**O agente nunca calcula preço.** Ele consulta o banco e usa o que vier de lá:
- Produtos: view `products_priced` (`suggested_price`, `floor_price`, `max_discount_price`, `est_net_profit`).
- Kits: tabelas `kits` e `kit_items` (preço do kit em `kits.price`).
- Limites: `app_settings` chave `pricing` (`floor_multiplier`, `max_discount_pct`, `min_net_profit`, `tax_pct`, `payment_fee_pct`).
- Totais e lucro do pedido: view `order_financials` (calculada no banco).

Nunca oferecer abaixo de `floor_price`, nunca dar desconto acima de `max_discount_pct` e nunca fechar pedido com lucro líquido menor que `min_net_profit`. Fora disso, **passar para uma pessoa**. O CRM também alerta e exige justificativa quando o dono ultrapassa esses limites.

## Sigilo do fornecedor
O agente **nunca cita o nome do fornecedor** (nem confirma se existe um) para ninguém. Para o cliente, a Sua Gráfica BH produz e entrega. Se perguntarem de onde vem o produto, responder que é produção própria e parceira, sem nomes, ou transferir para uma pessoa.

## Catálogo (produtos)
Tabela `products` (e view `products_priced`, que soma os preços calculados). Uma linha por variação vendável, com as mesmas colunas da planilha do fornecedor:

| Campo | Planilha | Exemplo |
|---|---|---|
| `code` | Código | `GIFT1515` (único) |
| `category` | Categoria | `ABRIDORES E CHAVEIROS` |
| `description` | Descrição do serviço | `ABRIDORES E CHAVEIROS - IMPRESSÃO UV - 10g` |
| `colors` | Cores | `4X0` |
| `weight` | Peso | `1250` (valor da coluna Peso) |
| `grammage` | Gramatura (extraída da descrição) | `10` (gramas) |
| `qty` | Qtde | `25` |
| `size` | Tam | `57 x 57` |
| `lead_days` | Prazo | `5` (dias) |
| `cost` | Preço R$ | `252.99` (custo, o que a Sua Gráfica paga) |
| `suggested_price`, `floor_price`, `max_discount_price`, `est_net_profit` | calculados | vêm do banco |

O agente filtra por esses campos (ex.: `category`, `qty`, `size`) em vez de interpretar texto. A gramatura é extraída da descrição na importação para `grammage` (nulo quando a descrição não traz o número). O prazo do fornecedor (`lead_days`) é copiado para cada item do pedido (`order_items.lead_days`) e o pedido guarda o maior deles em `orders.lead_days`. Prazo de entrega: conta a partir do pagamento confirmado, em dias úteis, sem sábado, domingo e feriados (tabela `holidays`, editável em Configurações > Prazos e feriados). A data é `orders.due_date` = `add_business_days(dia do pagamento, lead_days + extra_days)`, com `extra_days` em `app_settings` (`key = 'deadline'`, padrão 1). O banco calcula sozinho ao confirmar o pagamento e recalcula se o prazo dos itens mudar, salvo se `due_date_manual = true`. O agente deve ler `due_date` e nunca calcular a data. Para simular uma data antes do pagamento (orçamento), chamar `public.add_business_days(current_date, lead_days + extra_days)`.

## Estado do atendimento
| Onde | Campo | Significado |
|---|---|---|
| `app_settings` (`key = 'agent'`) | `enabled` | Chave geral. `false` = IA pausada em todas as conversas (botão "Pausar IA" no topo do CRM). Ler antes de cada resposta. |
| idem | `hours` (`start`, `end`, `days` 0-6) | Horário de funcionamento da IA |
| idem | `handoff_message` | Texto a enviar ao transferir para uma pessoa |
| `conversations` | `ai_handled` | `true` = a IA responde esta conversa; `false` = humano |
| `conversations` | `needs_human` | A IA marca `true` quando precisa de uma pessoa (aparece como "Atenção" na lista) |
| `conversations` | `attendant_changed_at`, `attendant_change_reason` | Quando e por que a vez mudou |
| `conversations` | `summary` | Resumo curto escrito pela IA (aparece no rodapé do chat) |
| `conversations` | `collected_data` (jsonb) | Dados coletados (ex.: produto, quantidade, prazo, endereço) |
| `conversations` | `labels` (text[]) | Etiquetas (dúvida, orçamento, reclamação, arte, recompra) |
| `conversations` | `last_inbound_at`, `ad_window_until` | Janela de atendimento: 24 h desde a última mensagem do cliente, ou 72 h quando a conversa veio de anúncio |
| `conversations` | `last_referral`; `contacts.first_referral` | Origem do anúncio (id, título, URL) |

**Responder só se**: `agent.enabled = true`, dentro do horário, `conversations.ai_handled = true` e janela aberta. Fora da janela só é permitido template aprovado.

## Eventos
- **Mensagem recebida**: a função `whatsapp-webhook` grava em `messages` (`direction = 'in'`). O agente deve assinar `postgres_changes` (INSERT em `messages`, `direction = 'in'`) ou usar um Database Webhook do Supabase.
- **Dono assumiu ou devolveu**: UPDATE em `conversations.ai_handled`. O agente para de responder quando vira `false`.
- **Pausa geral**: UPDATE em `app_settings` (`key = 'agent'`).
- **PARAR**: o webhook já marca `contacts.marketing_consent = 'opted_out'` e confirma. O agente não envia promoções para quem não está `opted_in`.

## O que o agente escreve
1. **Resposta**: enviar pela API da Meta (ou por uma função própria `agent-send` com service role) e gravar em `messages` (`direction = 'out'`, `status = 'sent'`), como faz `whatsapp-send`. Texto livre só dentro da janela; fora dela, template (`templates_cache`, status `APPROVED`).
2. **Pedido**: inserir em `orders` (`contact_id`, `conversation_id`, `title`; a origem do anúncio vem de `contacts.first_referral`) e em `order_items` (`code`, `description`, `qty`, `unit_cost`, `unit_price` copiados de `products_priced`/`kits`). Etapas: `novo`, `cotando`, `aguardando_pagamento`... A IA pode mover até `aguardando_pagamento`; as regras de banco impedem `pago` sem pagamento e `producao` sem arte aprovada.
3. **Log obrigatório**: toda ação vira uma linha em `agent_logs` (`conversation_id`, `actor = 'ia'`, `action`, `detail` jsonb, `result`). Aparece em Configurações > Agente de IA.
4. **Transferência para pessoa**: `conversations.ai_handled = false`, `needs_human = true`, `attendant_change_reason`, enviar `handoff_message` e registrar em `agent_logs`.

## Endpoints existentes
| Função | Uso pelo agente |
|---|---|
| `whatsapp-send` | Exige JWT do dono. O agente deve usar a API da Meta direto (ou uma função nova com service role) e seguir as mesmas regras de janela e de consentimento |
| `whatsapp-media` | Baixa mídia recebida (imagem, áudio, documento) |
| `meta-ads-sync` | Sincroniza gasto dos anúncios (uso do CRM) |

## Checklist antes de ligar
1. Ler `agent.enabled`, horário e `ai_handled`.
2. Conferir janela (`last_inbound_at` + 24 h ou `ad_window_until`).
3. Preços só de `products_priced` e `kits`.
4. Gravar `agent_logs`.
5. Na dúvida, reclamação ou pedido de desconto acima do limite: transferir para uma pessoa.

## Etapa 1 do agente: fundação (tabelas e funções)

Tudo abaixo vale só para o dono (RLS) e para a service role. O `anon` não tem acesso. Nenhuma função devolve custo.

### Tabelas novas

| Tabela | Para que serve |
|---|---|
| `parametros_comerciais` | Uma linha (`id = 1`). Multiplicadores por faixa, fator competitivo (0,93, entre 0,90 e 0,98), lucro líquido mínimo (R$ 60), imposto (6%), taxas por método (`taxas_pagamento`), arte (R$ 39,90 e R$ 49,90), validade do orçamento, horário de atendimento, corte das 12h, dia de logística, pedido mínimo de frete grátis, custos de entrega, trava de bike (3.000 g e 600 mm), saídas de bike, tetos de tokens, `exigir_sku_pedidos`. `campos_revisar` lista o que é suposição |
| `politica_desconto` | A escada da seção 7B: degrau 1 vantagem sem custo, degrau 2 até 4%, degrau 3 até 8% (teto absoluto de 10% por constraint), `fracao_gordura_max` 0,6, `desconto_max_reais` R$ 80, valor mínimo R$ 5, 30 dias entre condições por contato, validade de 24 h, `max_condicoes_por_orcamento` 1 |
| `zonas_frete_gratis` | Bairros e faixas de CEP com frete grátis. `ativo = false` fica cadastrado mas não vale |
| `agente_config` | IA ligada (nasce falso), horário, `whatsapp_dono`, mensagem de transferência, debounce, histórico |
| `anuncios_produtos` | Anúncio (`ad_id`) ligado a SKU ou kit |
| `orcamentos`, `orcamento_itens` | Orçamento com itens por SKU, totais, validade, regra e confiança do preço, margem e lucro, aprovação do dono |
| `condicoes_especiais` | Condições oferecidas (degrau, gatilho, tipo, valor, validade, resultado) |
| `precos_mercado`, `precos_praticados` | Pesquisa de mercado e aprendizado (preenchidas na Etapa 3) |
| `conhecimento` | Base de conhecimento com `vector(768)` e índice HNSW (preenchida na Etapa 2) |
| `followup_regras`, `followup_fila` | Regras F1 a F4, lembretes de pagamento, pós-venda e recompra; fila com chave de idempotência |
| `alertas` | Alertas ao dono por WhatsApp e push |
| `testes_conversa` | Casos de teste de conversa para a auditoria |

Campos novos: `conversations.modo_atendimento`, `contacts.status_lead/bairro/cep/optout/origem_anuncio`, `orders.subestatus_pedido`, `products.permite_desconto`, colunas de custo em `agent_logs`. Mapa de nomes em `docs/agente/mapa-crm.md`.

### Funções (chamadas pelo n8n com a service role)

| Função | Entrada | Saída |
|---|---|---|
| `calcular_preco(sku, quantidade, contexto)` | `contexto`: `metodo`, `entrega` (`bike`/`uber`), `receita_outros`, `custo_outros` | `preco_unitario`, `preco_total`, `regra` (`mercado`, `custo_x_multiplicador`, `piso`), `confianca`, `margem_liquida_pct`, `lucro_liquido`, `piso`, `piso_duro`, `nao_competitivo`. **`piso`, `piso_duro`, `lucro_liquido` e `margem_liquida_pct` são internos: a ferramenta do agente não repassa** |
| `calcular_prazo(sku, agora, arte_aprovada)` | momento em que pagamento e arte ficariam prontos | `data_pronto`, `data_pronto_texto` ("quinta, dia 6"), `inicio_contagem`, `frase`, horário de retirada |
| `verificar_frete(cep_ou_bairro, itens, valor_pedido, pacote_arte)` | `itens`: `[{sku, quantidade}]` | `frete_gratis`, `motivo`, `regiao_central`, `cabe_na_bike`, `valor_frete_cliente`, `custo_entrega_nosso`, `opcoes` |
| `validar_margem(orcamento)` | id | `status` `ok` ou `bloqueado`, `motivo`, `motivos`, `alternativa` |
| `calcular_condicao_especial(orcamento, gatilho, registrar)` | `G1`, `G2` ou `G3` | `{tipo, texto_curto, valor, valida_ate, degrau}` ou `{tipo: 'sem_condicao', motivo}` |

Regras: a quantidade vendável é a do SKU (cada linha do catálogo é uma opção fechada); `calcular_preco(sku, n)` multiplica por `n` pacotes. Preço termina em ,90 e nunca fica abaixo do piso. O piso é o maior entre custo x 1,5 e a receita que garante R$ 60 de lucro líquido depois de imposto, taxa do método (cartão de crédito quando desconhecido), custo de WhatsApp e IA e entrega nossa. `piso_duro` é a receita com lucro zero. Mercado só vale com 2 ou mais coletas de até 14 dias (3 ou mais = confiança alta). O dia da logística soma só em `calcular_prazo`.

### Travas no banco

- `orcamento_itens`: SKU obrigatório e existente; preço abaixo do piso duro do item é recusado.
- `orcamentos`: ao enviar ou mudar o total, recusa se o total der prejuízo; total sempre igual a itens + arte + frete - desconto.
- `order_items`: preço abaixo do piso duro é recusado; SKU obrigatório quando `exigir_sku_pedidos` estiver ligado.
- `orders`: desconto ou taxas editados à mão que levem a prejuízo são recusados.
- Pagamento confirmado nunca é bloqueado.

### Testes

`supabase/tests/agente_etapa1.sql` é um bloco único que se desfaz sozinho (cole no SQL Editor do Supabase ou rode com `psql "$DATABASE_URL" -f ...`). O resultado sempre aparece como mensagem de erro: "OK: N testes passaram" é sucesso, "TESTES FALHARAM" lista o que falhou. Cobre fim de semana, feriado, antes e depois das 12h, sexta à tarde, bairro central com item pequeno e com banner, fora da região, pedido abaixo do mínimo, pacote de arte, preço abaixo do piso, abaixo do piso duro (falha no banco), desconto acima do teto, gordura zero, desconto abaixo de R$ 5, segunda condição no mesmo orçamento e item sem permissão de desconto. `npm test` valida os 11 templates (regras da Meta para o corpo).


## Etapa 3: preço sob demanda, aprendizado e condição especial

Detalhes de infraestrutura em `docs/agente/infra-busca.md`; validação e tabelas em `docs/agente/etapa3-validacao.md`.

### Pesquisa de mercado (ferramenta `pesquisar_preco_mercado`)
- **Quando roda:** só quando um orçamento precisa e não há mercado válido (cache de `idade_max_pesquisa_dias`, 14). Nunca em massa.
- **Banco:** `consultar_cache_preco_mercado(sku)` devolve o cache ou abre uma consulta e a especificação normalizada **do catálogo** (grupo, descrição, quantidade, gramatura, tamanho); o agente não dita a especificação. `reservar_acesso_dominio(dominio)` aplica robots, termos e intervalo por domínio. `registrar_pesquisa_mercado(consulta, fontes, ...)` descarta outliers (mais de 3 desvios absolutos da mediana, ou fora de 0,5x a 2x), uma fonte vale uma vez, calcula mediana, mínimo, máximo e confiança (3 ou mais fontes = alta, 2 = média, 1 = baixa). Resultado ruim, falha ou estouro de 45 s: `sem_dado` (não repete por 30 minutos) e a fórmula usa o custo com travas.
- **Concorrente prioritário (alfacards.com.br), conferido em 28/10/2026:** `robots.txt` libera tudo; não há página de termos de uso (o dono precisa confirmar); o preço só aparece depois do JavaScript e só para as opções padrão. Registrado em `fontes_pesquisa`.

### `calcular_preco` (autoridade do preço)
Ordem: custo, piso e piso duro, alvo, trava final. Alvo = `mediana x quantidade x fator do grupo` (fator em `fatores_competitivos`, 0,90 a 0,98, padrão 0,93); com 3 ou mais vendas do SKU nos últimos 90 dias entra a média ponderada pela recência como âncora, **limitada pela mediana de mercado** (alvo = média entre os dois); sem mercado mas com a âncora: `historico_vendas`; sem nada: `custo x multiplicador` com confiança baixa. Mercado abaixo do piso: preço = piso, `nao_competitivo = true` e aviso `mercado_abaixo_do_piso`. O preço nunca fica abaixo do piso duro. A resposta traz `regra`, `confianca`, `margem_liquida_pct`, `fontes_mercado`, `mercado_mediana`, `consulta_mercado_id` e `fator_competitivo` para o orçamento gravar. `agente_preco` devolve ao agente só preço e uma orientação ("destaque valor, não reduza") quando não competitivo.

### Condição especial (substitui `aplicar_desconto`, que deixou de existir)
- `oferecer_condicao_especial(orcamento, gatilho)` (service role): decide com `calcular_condicao_especial`, registra, cria o **orçamento atualizado** (filho do original, status enviado, validade = `valida_ate`), confere com `validar_margem` (tudo ou nada) e ajusta o pedido ligado (percentual arredondado para baixo). O n8n pede o link novo de 24 h (`mp-criar-link`, `forcar_novo`) e grava com `condicao_registrar_link`.
- Expiração (`pg_cron` a cada 10 minutos e na rotina semanal): condição vencida vira `expirada`, orçamento atualizado `expirado`, pedido volta ao percentual anterior, link deixa de valer, e a condição não se repete para o orçamento (nem para o contato dentro do intervalo).
- Alertas: `cacador_de_desconto` ao recusar; `padrao_desconto` (3 condições consumidas e nenhuma compra) e `padrao_desconto_recorrente` pelo detector semanal; relatório semanal e resumo ao dono como alerta de baixa gravidade.
- Política (Configurações > Política de desconto): `simular_politica_desconto` mostra o lucro líquido do pior caso em uma amostra do catálogo, três tipos de entrega e quatro níveis de preço; `salvar_politica_desconto` só grava se o pior caso for maior ou igual a zero; um gatilho de banco repete a checagem em alterações diretas.

### Aprendizado
Cada orçamento entra em `precos_praticados` (especificação, quantidade, preço, margem, regra, condição usada e resultado ganho, perdido ou expirado; o orçamento atualizado conta para o original). Semanalmente `aprender_precos_semana` ajusta o fator por grupo com 8 ou mais orçamentos encerrados em 30 dias: conversão abaixo de 15% com margem acima da meta (`meta_margem_liquida_pct`, 20) baixa 0,01; acima de 45% sobe 0,01; limites 0,90 e 0,98; cada ajuste fica em `ajustes_fator_preco`.

### Edição manual de preço
`definir_preco_item_pedido(item, preco, confirmar, motivo, apenas_simular)`: abaixo do piso duro bloqueia para todos; entre o piso duro e o piso exige confirmação do dono e grava em `precos_manuais_log`; acima é livre. Um gatilho recusa reduzir o preço abaixo do piso por qualquer outro caminho do CRM.

## Etapa 5: o agente de atendimento (WF1 e WF2)

Detalhes dos testes em `docs/agente/etapa5-testes.md`. Tudo desativado até a Etapa 8.

### Arquitetura

```
Meta  ->  whatsapp-webhook (único receptor, grava a mensagem)  ->  POST no webhook do WF1 (só o id da mensagem)
WF1 GBH | WF1 | Entrada e roteamento
    agente_entrada (ignora?)  ->  espera 8 s  ->  agente_debounce (sou a última?)  ->  agente_iniciar (trava da conversa)
    ->  mídia (áudio: Groq; imagem e documento: registro no CRM)  ->  agente_primeiro_contato  ->  agente_contexto
    ->  escolhe o modelo por regra  ->  WF2  ->  divide em até 3 mensagens com atraso de 1 a 6 s  ->  agente-enviar
    ->  agente_finalizar  ->  resumo (a cada 8 mensagens novas, modelo pequeno)
WF2 GBH | WF2 | Agente
    prompt  ->  nó AI Agent (Gemini) com 11 ferramentas  ->  estimativa de tokens  ->  agente_saida_segura  ->  agente_log
Ferramentas: o nó AI Agent chama sempre GBH | FERRAMENTA | despachar, que roda o sub-workflow GBH | FERRAMENTA | <nome>
```

### Quando o WF1 ignora (sem chamar o modelo)
IA pausada (`agente_config.ia_ligada` **e** botão do topo `app_settings.agent.enabled`, os dois precisam estar ligados), fora do horário (`atende_24h` e `horario_ia`), contato em `optout`, conversa em modo humano, pedido já pago (etapas Pago, Arte, Prova e Produção), mensagem duplicada (`agente_execucoes.message_id` é único), tipo sem resposta (figurinha, vídeo, localização), teto de tokens da conversa (24 h) ou do dia (`parametros_comerciais.tokens_max_conversa` e `tokens_max_dia`, com alerta). Mensagens de status (entregue, lida) nunca chegam ao WF1: o webhook só aciona o agente para mensagem nova.

Conversa nova nasce em modo humano (padrão do CRM). Com a IA ligada, a IA assume o **primeiro contato** (sem troca de atendente registrada e sem nenhuma mensagem de saída). Se o cliente responde um follow-up (template da fila), a IA retoma, salvo se o dono assumiu ou há pagamento em andamento; os lembretes pendentes são cancelados e lead frio volta a "qualificando".

### Ferramentas (11, todas via despachante)
`buscar_conhecimento`, `buscar_produto`, `montar_orcamento`, `gerar_pdf_orcamento`, `salvar_contato`, `oferecer_condicao_especial` (o gatilho G1 é fixo no despachante), `verificar_frete`, `gerar_link_pagamento`, `agendar_followup` (opções fixas, envio na Etapa 7), `chamar_dono` (grava em `alertas`, status pendente, envio na Etapa 6), `enviar_foto_produto`. `data_atual` não foi criada: a data e a hora (America/Sao_Paulo) já vão no prompt. O despachante: conversa e contato vêm do WF2, nunca do modelo; detector de loop (mais de 3 chamadas da mesma ferramenta ou 12 no total encerra a rodada); remove custo, piso, margem, fornecedor, endereço, bicicleta e SKU (o SKU só passa em `buscar_produto`); guarda SKUs e valores devolvidos; se a ferramenta falha avisa o dono (alerta alto) e manda dizer "vou confirmar"; antes do primeiro `montar_orcamento` da rodada manda uma frase curta de espera.

### Trava de saída (`agente_saida_segura`)
Depois do modelo e antes do envio: troca travessão por vírgula, tira markdown e marcadores, e **bloqueia** a mensagem (o cliente recebe "Deixa eu confirmar isso certinho aqui e já te respondo, tá?" e o dono recebe alerta alto) se aparecer custo, margem, piso, fornecedor, "sku", bicicleta ou bike, o endereço do escritório, um SKU que uma ferramenta devolveu, ou um valor em R$ que nenhuma ferramenta devolveu (fora R$ 39,90, R$ 49,90 e o pedido mínimo). Antes de enviar cada parte, `agente_pode_enviar` confere de novo (o dono assumiu ou o pagamento entrou enquanto o modelo escrevia).

### Como editar
- **Regras e prompt:** nó "Montar prompt" do WF2 (texto fixo no código do nó, seção 12 do contexto). Editar lá e republicar. Nome do atendente: `agente_config.nome_atendente` (padrão "Bia", revise).
- **Modelos:** `agente_config.modelo_padrao`, `modelo_forte`, `modelo_resumo` (nomes de modelos Gemini). A regra de objeção (palavras) está no nó "Escolher o modelo (regra por palavras)" do WF1.
- **Debounce, histórico, limites por ferramenta:** `agente_config.debounce_segundos`, `historico_mensagens`, `max_ferramenta_por_rodada`, `max_chamadas_por_rodada`. Tetos de tokens em `parametros_comerciais`.
- **Preço por modelo (custo estimado):** `agente_config.precos_modelo`.
- **Palavras proibidas na saída:** função `agente_saida_segura` (nova migration, nunca editar a antiga).
- **Ligar e desligar:** `agente_config.ia_ligada` e o botão do topo do CRM. Modo humano por conversa continua sendo o botão da conversa.

### Registro
Cada rodada é uma linha em `agente_execucoes` (status, modelo, tokens, custo, ferramentas e quantas vezes) e cada passo uma linha em `agent_logs` (`ferramenta`, `modelo`, `tokens_entrada`, `tokens_saida`, `custo_estimado`, `duracao_ms`, sem conteúdo de mensagem). **Tokens e custo do modelo são estimativas** (o n8n não expõe o uso real do Gemini ao workflow); a transcrição entra com custo fixo por áudio.

### Tabelas e funções novas (migration `20261101000001`)
`agente_execucoes`; colunas novas em `agente_config` (`precos_modelo`, `modelo_resumo`, `max_ferramenta_por_rodada`, `max_chamadas_por_rodada`); funções (todas só para a service role): `agente_bloqueio`, `agente_entrada`, `agente_debounce`, `agente_iniciar`, `agente_contexto`, `agente_primeiro_contato`, `agente_registrar_midia`, `agente_gravar_transcricao`, `agente_log`, `agente_tool_inicio`, `agente_tool_fim`, `agente_saida_segura`, `agente_pode_enviar`, `agente_finalizar`, `agente_resumo_precisa`, `agente_gravar_resumo`, `agente_salvar_contato`, `agente_chamar_dono`, `agente_agendar_followup`, `agente_teste_preparar`, `agente_teste_registrar_saida`, `agente_teste_avaliar`, `agente_teste_limpar`; 21 cenários `e5-*` em `testes_conversa`.

### Edge Functions desta etapa
`agente-enviar` (nova, só service role: confere IA, modo humano, pagamento e janela, envia texto e grava a mensagem), `whatsapp-webhook` (avisa o WF1 com o id da mensagem; sem `N8N_WF1_URL` e `N8N_WF1_TOKEN` não faz nada) e `whatsapp-media` (agora também aceita a service role, para o WF1 baixar o áudio).
