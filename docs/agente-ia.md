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
- **Palavras proibidas na saída:** função `agente_saida_segura` (nova migration, nunca editar a antiga; hoje a `agente_saida_segura` envolve a `agente_saida_base`).
- **Ligar e desligar:** `agente_config.ia_ligada` e o botão do topo do CRM. Modo humano por conversa continua sendo o botão da conversa.

### Registro
Cada rodada é uma linha em `agente_execucoes` (status, modelo, tokens, custo, ferramentas e quantas vezes) e cada passo uma linha em `agent_logs` (`ferramenta`, `modelo`, `tokens_entrada`, `tokens_saida`, `custo_estimado`, `duracao_ms`, sem conteúdo de mensagem). **Tokens e custo do modelo são estimativas** (o n8n não expõe o uso real do Gemini ao workflow); a transcrição entra com custo fixo por áudio.

### Tabelas e funções novas (migration `20261101000001`)
`agente_execucoes` (migrations `20261101000001` a `03`); colunas novas em `agente_config` (`precos_modelo`, `modelo_resumo`, `max_ferramenta_por_rodada`, `max_chamadas_por_rodada`); funções (todas só para a service role): `agente_bloqueio`, `agente_entrada`, `agente_debounce`, `agente_iniciar`, `agente_contexto`, `agente_primeiro_contato`, `agente_registrar_midia`, `agente_gravar_transcricao`, `agente_log`, `agente_tool_inicio`, `agente_tool_fim`, `agente_saida_segura`, `agente_pode_enviar`, `agente_finalizar`, `agente_resumo_precisa`, `agente_gravar_resumo`, `agente_salvar_contato`, `agente_chamar_dono`, `agente_agendar_followup`, `agente_teste_preparar`, `agente_teste_registrar_saida`, `agente_teste_avaliar`, `agente_teste_limpar`; 21 cenários `e5-*` em `testes_conversa`.

### Edge Functions desta etapa
`agente-enviar` (nova, só service role: confere IA, modo humano, pagamento e janela, envia texto e grava a mensagem), `whatsapp-webhook` (avisa o WF1 com o id da mensagem; sem `N8N_WF1_URL` e `N8N_WF1_TOKEN` não faz nada) e `whatsapp-media` (agora também aceita a service role, para o WF1 baixar o áudio).

## Etapa 7: follow-ups, pós-venda, status do pedido e observabilidade

Regra de ouro mantida: o modelo de IA não participa de nada desta etapa. Quem recebe, quando, por qual canal, com qual texto e com qual condição especial é decidido por funções do banco; o n8n só orquestra e a Edge Function `proativo-enviar` só envia. Migration `20261102000001` (cópia em `docs/agente/aplicar-etapa7.sql`), testes `supabase/tests/followup_etapa7.sql` (96 casos, relógio acelerado) e `npm run test:proativo`.

### Cobrança de templates e janela do anúncio (Passo 0, conferido em 01/11/2026 na documentação oficial da Meta)
Fonte: [Pricing on the WhatsApp Business Platform](https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing.md).
- **Janela de atendimento (24 h)**: abre quando o cliente escreve e renova a cada mensagem dele. Só dentro dela vale texto livre; fora dela, só template aprovado.
- **Entrada por anúncio (Free Entry Point)**: se o cliente chegou por um anúncio de clique para o WhatsApp (Android ou iOS) e a empresa responde dentro das 24 h, essa resposta não é cobrada e abre a janela do anúncio. Enquanto ela estiver aberta, a Meta não cobra mensagens de marketing, utilidade, autenticação nem serviço, **inclusive templates**. A página atual fala em até 7 dias de duração (o CRM guarda 72 h em `conversations.ad_window_until`, que é o lado conservador). A janela do anúncio **não** libera texto livre depois das 24 h: só barateia template.
- **Mudança de 1º/10/2026**: voltaram a ser cobradas por mensagem as de serviço (texto livre dentro das 24 h) acima das primeiras 1.000 por mês por número, e as de utilidade enviadas dentro da janela de 24 h. Continuam grátis: mensagens do cliente, a janela do anúncio e as 1.000 primeiras de serviço do mês.
- **Efeito no desenho**: F1 e F2 saem como texto livre (dentro das 24 h, na maior parte do tempo grátis pela franquia de 1.000). F3 e F4 (dia 2 e dia 5) saem por template de marketing, pagos, exceto se a janela do anúncio ainda estiver aberta. O painel estima o custo de templates do mês (`app_settings.observabilidade`: R$ 0,35 por marketing e R$ 0,04 por utilidade, estimativas para você revisar com a fatura). Templates enviados dentro de `ad_window_until` entram como R$ 0.
- **Correção para a Etapa 8**: `agente-enviar` (Etapa 5) usa `ad_window_until` para liberar texto livre, o que a Meta não aceita depois das 24 h. `proativo-enviar` já usa só as 24 h; ajustar o `agente-enviar` na auditoria.

### WF6 `GBH | WF6 | Follow-ups` (a cada 15 minutos)
Fila `followup_fila` (regras em `followup_regras`, editáveis em Configurações > Follow-ups). Passos: `expirar_condicoes_e_orcamentos` > `followup_agendar` (cria F1 a F4 de orçamentos enviados e PAG de links ativos, idempotente por `chave`) > `followup_reservar('cadencia')` > por item, o sub-workflow `GBH | FERRAMENTA | enviar_proativo`.
- F1 (2 h) e F2 (20 h): texto livre sem condição; F2 cita validade e data de pronto (template `orcamento_vence_hoje` se a janela fechou).
- F3 (dia 2, G2) e F4 (dia 5, G3): o sub-workflow chama `GBH | FERRAMENTA | condicao_especial` (`oferecer_condicao_especial`, que cria o orçamento atualizado e o link novo de 24 h). Com condição: texto livre (se a janela está aberta) ou `condicao_especial_orcamento`. Sem condição: `orcamento_vence_hoje` (F3) ou `ultima_chance_orcamento` (F4). Depois do F4 enviado, o contato vira `frio` e a cadência para.
- Pagamento pendente: PAG_1H, PAG_6H e PAG_24H (`pagamento_pendente` fora da janela). Se houver condição vigente, o último lembrete (texto livre) avisa a hora em que ela expira.
- Guardas em SQL (`followup_reservar`): cancela se `optout`, pago (orçamento, pedido ou qualquer pedido pago do contato depois do orçamento), orçamento encerrado ou vencido, link inativo, recompra já feita; pula em modo humano; adia (continua pendente) com IA pausada, fora de 8h às 20h e acima de 1 mensagem proativa por dia por contato. Caçador de desconto e "usou condição nos últimos 30 dias" são decididos por `calcular_condicao_especial`: sem condição, só o lembrete simples.
- Resposta do cliente cancela os pendentes (gatilho da Etapa 5). Para "vou pensar", o agente reabre a linha com `agendar_followup` (`agente_agendar_followup` agora reabre uma linha cancelada por resposta).
- Expiração: ao passar `valida_ate`, a condição vira `expirada`, o link é desativado, o orçamento atualizado vence e o pedido volta ao preço normal; a condição não se repete (`ja_houve_condicao_neste_orcamento`).
- Registro: `followup_resultado` grava o envio em `followup_fila` e o passo e o canal em `condicoes_especiais` e `precos_praticados` (base do aprendizado e do relatório semanal da Etapa 3).
- Contatos com a tag `teste` nunca vão à Meta: o resultado é registrado como `simulado`.

### WF7 `GBH | WF7 | Pós-venda e recompra` (a cada 10 minutos)
Ao entrar em "Entregue" (por qualquer caminho, inclusive arrastar no kanban) o gatilho `orders_entregue_agenda` cria `POS_ENTREGA` (dia seguinte, com um upsell relevante por produto) e `RECOMPRA_CARTAO` (60 dias), `RECOMPRA_ADESIVO` (45) ou `RECOMPRA_PANFLETO` (30), só do produto comprado, uma vez por ciclo, pulando quem já recomprou ou pediu para parar. Prazos editáveis. Configurações > Follow-ups > Recompra lista os ciclos e o botão "Disparar agora" reagenda a linha (o envio sai pelo WF7).

### WF8 `GBH | WF8 | Status do pedido` (a cada minuto)
O card em Produção ganha `subestatus_pedido` (`em_producao`, `pronto_retirada`, `saiu_entrega`) com botões no cartão e no detalhe (aba Entrega). `pedido_definir_subestatus` valida (Produção, pedido pago, retirada x entrega) e cria um registro único em `pedido_avisos` (por pedido e tipo: nunca duas vezes o mesmo aviso). O WF8 reserva, monta e envia: `pedido_pronto_retirada` (ou texto livre) com endereço, horário e próximo horário de atendimento se estiver fora do expediente; `pedido_saiu_entrega` com rastreio ou "o entregador já está a caminho". O resultado aparece no cartão ("Aviso de pronto: enviado ✓"), no detalhe e no histórico do pedido; falha gera alerta alto ao dono. `pedido_marcar_entregue` move para Entregue e agenda satisfação e recompra.

### WF9 `GBH | WF9 | Erros e observabilidade`
Error Trigger: `agente_erro_registrar` grava em `agent_logs`, cria alerta de gravidade alta (um por workflow a cada 30 minutos) e libera envios reservados e travados (reprocesso seguro), e `alertas-enviar` entrega na hora. Agenda de hora em hora: `observabilidade_checar` alerta se o custo estimado da IA no dia passar do teto (`app_settings.observabilidade.teto_custo_dia_brl`, padrão R$ 15, editável em Configurações > Follow-ups). Agenda de 30 minutos: `followup_liberar_travados`.
**Ligação aos outros workflows:** o n8n só aceita como fluxo de erro um workflow publicado. Como nada pode ser ativado antes da Etapa 8, a ligação (`settings.errorWorkflow`) fica para a ativação: publicar o WF9 e ligá-lo aos 27 workflows `GBH |`.

### CRM
- **Pedidos** (`/pedidos`): tabela com as abas Aguardando arte, Em produção, Prontos para retirada, Entregas do dia, Atrasados (em vermelho), Pagos hoje e Todos; filtros, busca por cliente, número e SKU, ordenação pela data prevista, resumo no topo, lista para o fornecedor (SKUs somados, copiar e marcar como enviado à fábrica), ações em lote e CSV. Lê os mesmos dados do kanban e atualiza em tempo real. Lucro só aparece para o dono.
- **Painel > Agente**: conversas atendidas, orçamentos, conversão por etapa, pagos do agente, custo médio e tokens por conversa, custo do dia contra o teto, custo estimado de templates no mês, tempo de resposta, chamadas ao dono, erros recentes, condições especiais (concedidas, convertidas, desconto médio sobre o lucro) e margem líquida real. O botão Pausar IA (global) também está no topo.
- **Configurações > Follow-ups**: prazos e janelas de cada passo, limite diário, exigência de consentimento de promoções, teto de custo, recompra e fila com o motivo de cada envio.

### Decisões de negócio desta etapa
1. **Validade do orçamento sobe de 48 h para 168 h (7 dias)**: a cadência precisa do orçamento vivo no dia 2 e no dia 5, e a ferramenta de condição recusa orçamento vencido. Só mudou porque estava no padrão; revisável.
2. **Templates de marketing só para quem aceitou promoções (`opted_in`)**: protege a qualidade do número, que é o único canal de vendas. Custo: F3 e F4 fora das 24 h raramente saem para quem veio de anúncio e nunca aceitou. Mitigação sugerida: pedir o aceite na primeira conversa. Chave: `app_settings.followup.exigir_optin_marketing`.
3. **Uma condição por orçamento (regra 7B)**: se o F3 oferecer algo, o F4 vira "última chance" sem benefício. Se o F3 não tiver condição, o F4 ainda pode oferecer o degrau 3.
4. **1 mensagem proativa por dia e 8h às 20h**, aplicadas em SQL. "Pausar IA" também segura os follow-ups.
5. **Avisos de status são transacionais**: seguem para quem pediu PARAR (só promoções são bloqueadas), com template de utilidade.


## Etapa 7C: conhecimento v2, personas e setor de arte
- **Personas:** Laura (vendas) e João Victor (pós-pagamento) são só nomes de um assistente virtual. Nomes em `app_settings.personas`; fase decidida por `private.agente_fase` (pedido pago em andamento). `agente_contexto` e `agente_entrada` devolvem `persona.nome` e `fase`: o prompt do WF1/WF2 deve usar esses campos no lugar de `nome_atendente`.
- **Depois do pagamento** o agente continua (`personas.pos_pagamento_automatico = true`) e só para em `aguardando_dono` (setor de arte ou dono). Desligar a chave volta ao comportamento antigo (`pedido_pago`).
- **Setor de arte:** ferramentas novas do agente (service role): `arte_receber(conversation, tipo, qualidade, detalhe)` quando o cliente manda arquivo ou briefing depois de pagar (card vai para Arte, tarefa, alerta alto com resumo, conversa em setor arte) e `arte_baixa_ok(conversation)` quando o cliente topa seguir com baixa qualidade. O dono usa a tela Fila da arte e `arte_aprovar` (exige a confirmação do cliente; registra data, hora e aceite; prazo conta dali; produção automática; automação volta).
- **Conhecimento:** 83 trechos v2 (`docs/agente/conhecimento_v2.json`); variáveis `{{persona_vendas}} {{persona_pos_pagamento}} {{cupom_percentual}} {{cupom_teto}} {{cupom_validade_dias}} {{troca_prazo}}` além das 5 antigas. Preço e prazo nunca vêm do conhecimento.
- **Política:** `public.politica_texto('resumo_pdf' | 'descricao_link' | 'aceite_arte')`. Reembolso e estorno só pelo dono.
