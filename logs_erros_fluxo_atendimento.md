# Auditoria de erros técnicos, falhas de fluxo e automações de follow-up/recuperação

Extraído do banco (Supabase, projeto `bhlosshvwmlyzhbghsrc`) e do n8n (`n8n.bauerlab.com.br`) em 20/11/2026, cobrindo os últimos 60 dias (desde ~22/09/2026, mas a operação real começou em outubro — a maior parte do volume é de novembro). Este arquivo é complementar a `dossie_operacao_sua_grafica_bh.md` (visão geral) e `transcricoes_conversas_laura.md` (40 conversas reais completas) e usa a mesma máscara de identidade: quando o contato aparece entre os 40 do arquivo de transcrições, uso o mesmo rótulo **Lead #NN**; quando o caso envolve um contato que não está nos 40 selecionados, crio um rótulo novo e consistente **Contato extra #NN** (nome e telefone não aparecem neste arquivo).

**Nota de método importante:** o histórico de execuções do n8n tem retenção curta — ao consultar a workflow `GBH | WF1 | Entrada e roteamento`, só havia 195 execuções guardadas no total, todas dentro de ~1 dia (19–20/11/2026). Ou seja, **não é possível auditar diretamente 60 dias de execuções brutas do n8n** — isso só é possível para o banco (`erros_operacao`, `agent_logs`, `alertas`, `agente_execucoes`, `followup_fila`, etc., que têm histórico completo). Os números de falha de workflow abaixo vêm, portanto, do lado do banco (que registra o erro via `alerta_criar`/`erros_operacao` quando o n8n avisa) e da pequena janela recente em que o n8n ainda guardava a execução — isso é dito explicitamente em cada item para não passar a falsa impressão de que os 60 dias de n8n foram 100% cobertos.

**Contatos fora da amostra de 40 (aparecem só neste arquivo):**

| Rótulo | Conversa (uuid) |
|---|---|
| Contato extra #01 | `691be972-8985-4909-ae33-8485ac19ee56` |
| Contato extra #02 | `33d1d8d4-8e93-4515-8c5e-859cf17ded5b` |
| Contato extra #03 | `65024deb-30c4-4437-a42a-bf9c9526fcaf` |
| Contato extra #04 | `9ae5c572-f02c-4153-bd2f-533dff6b0ef8` |
| Contato extra #05 | `fbfc3c7a-2fa6-4d33-a8f9-31e7715a66fc` |

---

## 1. Erros no Supabase e no n8n

### 1.1 `webhook_eventos` (fila de entrada da Meta)
Tabela vazia (0 linhas) no momento da extração, com 0 pendentes e 0 com `ultimo_erro` nos últimos 60 dias. A fila não acumula atraso: tudo que chega da Meta é processado. Não há como provar retroativamente que nunca houve um erro aqui, porque a tabela não guarda histórico de linhas já processadas com sucesso — só o estado atual. Isso por si só é um ponto de atenção para quem for auditar: **não existe log duradouro de "webhook recebido e processado" fora do processamento imediato.**

### 1.2 `erros_operacao` (últimos 60 dias) — 145 linhas

| Tipo | Ocorrências | Observação |
|---|---|---|
| `divergencia_pagamento` | 108 | "Pagamento e pedido SG-XXXX não conferem." Concentrado em **4 lotes** (não 108 eventos independentes no tempo): 2026-11-03 04:05 (3), 2026-11-03 12:05 (3 na amostra, provavelmente mais no lote completo), 2026-11-11 19:05 (2 na amostra). O padrão de timestamp idêntico até o milissegundo dentro de cada lote indica uma rotina de conferência rodando em lote (não encontrei a função de origem no schema `private`/`public` via `pg_get_functiondef` — o texto pode estar embutido em uma Edge Function ou no n8n, não em uma function SQL). **Recomendo ao consultor pedir ao time que identifique exatamente qual processo dispara essa mensagem**, porque 108 ocorrências em 60 dias é o erro mais frequente do sistema e ainda não tem causa raiz documentada nesta auditoria.
| `outro` | 36 | Quase todas "The service was not able to process your request" — erro genérico de indisponibilidade/timeout de serviço externo (Gemini ou Mercado Pago sob carga). `pedido_id` sempre nulo. Pelo menos 5 dessas datam de 19/11 entre 21:50 e 22:03 e **coincidem no minuto** com execuções `error` registradas no próprio n8n (ver 1.4) — ou seja, dá para correlacionar diretamente este tipo de erro com falhas pontuais do workflow `GBH \| WF6 \| Follow-ups` e `GBH \| WF7 \| Pós-venda e recompra`.
| `mudar_status` | 1 | "The connection was aborted, perhaps the server is offline." |

### 1.3 Falhas de RPC/ferramenta da Laura (`agent_logs`, 60 dias)

| Ferramenta | Chamadas | Falhas (texto "erro"/"fal"/"bloque" no `result`) |
|---|---|---|
| (sem ferramenta — passos de raciocínio/registro do agente) | 1.322 | 52 |
| `buscar_produto` | 675 | 22 |
| `salvar_contato` | 271 | 0 |
| `buscar_conhecimento` | 217 | 3 |
| `enviar_foto_produto` | 66 | 0 |
| `montar_orcamento` | 53 | 0 |
| `agendar_followup` | 35 | 0 |
| `chamar_dono` | 32 | 0 |
| `gerar_pdf_orcamento` | 22 | 0 |
| `verificar_frete` | 18 | 1 |
| `gerar_link_pagamento` | 16 | 0 |
| `oferecer_condicao_especial` | 5 | 0 |
| `arte_receber` | 3 | 0 |

Exemplos reais de falha (com duração — quando falha, falha devagar, perto do timeout):

| Lead/Contato | Ferramenta | Duração | Quando |
|---|---|---|---|
| Lead #05 | `buscar_produto` | 55.735 ms | 19/11 22:02:59 |
| Lead #10 | `buscar_produto` | 50.347 ms | 19/11 21:16:26 |
| Lead #26 | `buscar_produto` | 20.531 ms | 14/11 13:54:13 |
| Lead #31 (interno/teste) | `buscar_produto` | 2.758 ms | 04/11 16:39:28 |
| Lead #40 | `buscar_conhecimento` | 2.485 ms | 01/11 18:51:42 |
| Lead #40 | `verificar_frete` | 2.688 ms | 01/11 18:51:30 |
| Lead #40 | `buscar_conhecimento` | 2.426 ms / 4.000 ms | 01/11 18:50:21–18:50:28 |

### 1.4 Execuções do n8n com erro (dentro da janela de retenção disponível)

| Workflow | Execuções com erro encontradas | Quando |
|---|---|---|
| `GBH \| WF6 \| Follow-ups` | 3 | 19/11 21:54, 22:00, 22:03 |
| `GBH \| WF7 \| Pós-venda e recompra` | 2 | 19/11 21:50, 22:00 |
| `GBH \| WF1 \| Entrada e roteamento` | 0 encontradas (195 execuções totais guardadas, todas de sucesso) | — |
| `GBH \| WF2 \| Agente`, `GBH \| FERRAMENTA \| despachar`, `GBH \| WF5 \| Pagamento e alertas`, `GBH \| WF8 \| Status do pedido`, `GBH \| WF9 \| Erros e observabilidade`, `GBH \| FERRAMENTA \| montar_orcamento` | 0 encontradas na janela disponível | — |

Os horários de WF6/WF7 coincidem com os 5 registros de `erros_operacao` tipo `outro` do mesmo dia — é o mesmo incidente visto por dois ângulos (n8n e banco).

### 1.5 Alertas de erro/falha já capturados pelo próprio sistema (`alertas`, 60 dias)

O CRM já tem um mecanismo de observabilidade (`alerta_criar`, `GBH \| WF9 \| Erros e observabilidade`) que grava no banco quando algo falha. Resumo por tipo relevante a erro/falha (228 alertas no total em 60 dias; tabela abaixo só os tipos de erro/falha, não os operacionais como "pedido pago"):

| Tipo | Ocorrências | Exemplo real |
|---|---|---|
| `erro_workflow` | 20 | "Erro (outro) no workflow GBH \| WF1, nó Contexto enxuto da conversa: Bad request - please check your parameters." |
| `falha_ferramenta` | 6 | "Falha da ferramenta buscar_produto. O agente seguiu sem inventar valores e avisou o cliente que vai confirmar." |
| `saida_bloqueada` | 9 | Trava de saída bloqueou: `preco_nao_verificado` (3x), `promessa:desconto_fora_da_funcao` (2x), `vazamento:endereco` (2x), `promessa:data_que_a_ferramenta_nao_deu` (1x), `vazamento:custo` (1x) — **isto é a trava de segurança funcionando como projetado**, não um bug; mas a frequência (9 vezes em 60 dias) mostra que o modelo tenta "vazar" informação proibida ou prometer algo fora da régua com alguma regularidade, e é bom o dono saber disso. |
| `agente_falhou` | 2 | "O agente não conseguiu responder (modelo ou ferramenta com erro). **Nenhuma mensagem foi enviada ao cliente.**" — esta é a falha silenciosa mais literal do sistema (ver seção 3). |
| `erro_followup` | 5 | "Follow-up PAG_1H não foi enviado depois de 3 tentativas" (2x), "Follow-up PAG_6H não foi enviado depois de 3 tentativas" (2x), "Follow-up PAG_24H não foi enviado depois de 3 tentativas" (1x). |
| `origem_sessao_expirada` | 3 | "A sessão logada no site do fornecedor caiu. Abra o navegador da VPS e entre de novo para a Laura voltar a conferir preço e tamanho ao vivo." — fragilidade operacional do scraping autenticado (depende de login manual na VPS). |
| `bling_falha` | 1 | "Pedido 417 não foi para o Bling: contato: O contato não pode ser salvo... (O CPF já está cadastrado no contato [Lead #12 — interno/teste])" — pedido interno/teste, mas mostra que a integração Bling pode falhar por duplicidade de CPF. |
| `teto_tokens` | 1 | "Teto de tokens da conversa atingido; o agente parou de responder esta conversa por hoje." |
| `pedido_fora_das_regras` | 6 | Pedidos pagos com item sem SKU no catálogo (SG-0417, SG-0220, SG-0295, SG-0411, SG-0294, SG-0023) — pagamento foi mantido, mas o pedido ficou fora das regras de catálogo. |
| `janela_fechada_orcamento` | 1 | "Orçamento SG-0599 pronto, mas a janela de 24h está fechada." |

---

## 2. Falhas de integração externa

### 2.1 WhatsApp Cloud API (Meta)

**Erros de entrega registrados em `messages.error` (60 dias):**

| Lead/Contato | Tipo | Código | Mensagem | Quando |
|---|---|---|---|---|
| Lead #12 (interno/teste) | text | 131047 | "Re-engagement message" (janela de 24h fechada — mensagem de confirmação de pagamento tentou sair fora da janela) | 18/11 19:17 |
| Contato extra #01 | audio | 131053 | "Media upload error" | 04/11 19:17 e 19:19 (2x, mesma conversa, ~2,5 min de intervalo) |

**Mídia ainda aparecendo como placeholder não processado (`[imagem recebida]`, `[documento recebido]`, `[áudio recebido]`):** 85 mensagens recebidas em 60 dias com esse padrão — 33 imagens, 30 documentos, 7 áudios, e algumas variações com legenda anexada (ex.: "[imagem recebida] Vocês fazem esse tipo de caneca?"). Isso é esperado como *fallback* quando a mídia não é lida por um modelo (a documentação do projeto já descreve isso como limite da Fase 1 para áudio), mas a presença de 33 imagens e 30 documentos nesse estado em 60 dias — bem depois da Fase 1 — sugere que uma parte relevante da mídia recebida **não está sendo processada por IA mesmo nos fluxos mais recentes** (cobertura de orçamento concorrente, aprovação de arte). Vale o consultor confirmar com o time se isso é intencional (só processa imagem/PDF em contexto de pagamento/cobertura) ou uma lacuna.

### 2.2 Mercado Pago

**`pagamentos` por status (60 dias):** pendente 23, aprovado 12, invalidado 5, expirado 3, recusado 1.

**`pagamentos_alertas` (alertas de problema de pagamento, histórico completo — tabela só tem 1 linha desde que existe):**

| Lead | Pedido | Mensagem | Criado em | Resolvido em |
|---|---|---|---|---|
| Lead #28 | SG-0296 | "Pagamento recusado no pedido SG-0296 (cc_rejected_card_type_not_allowed). O cliente pode tentar de novo pelo mesmo link." | 12/11 19:50 | **nunca (`resolvido_em` nulo)** |

Esse é o único alerta de pagamento recusado que o sistema já gerou, e ele nunca foi marcado como resolvido — mesmo o pedido SG-0296 tendo sido pago depois (há um registro de "Pedido SG-0296 pago por [Lead #28]: R$ 145,90" em `alertas`). Ou seja, **o campo `resolvido_em` de `pagamentos_alertas` parece não ser atualizado automaticamente quando o pagamento se resolve por outro caminho** — é um gap de "faxina" do dado, não um problema para o cliente.

**`eventos_pagamento` por tipo (60 dias) e `processado_em`:**

| Tipo | Ocorrências | Sem `processado_em` |
|---|---|---|
| `link_criado` | 36 | 36 (100%) |
| `pagamento_confirmado` | 12 | 0 |
| `pagamento_pendente` | 8 | 8 (100%) |
| `pagamento_expirado` | 3 | 3 (100%) |
| `pagamento_recusado` | 1 | 1 (100%) |

Isso não é uma falha: pela leitura do schema, `processado_em` só é preenchido no caminho de confirmação de pagamento (`private.confirmar_pagamento`) — os outros tipos são só log/auditoria e nunca deveriam ter `processado_em` preenchido. Registro aqui só para o consultor não interpretar esse "100% não processado" como bug sem contexto.

**Divergência pagamento x pedido:** ver item 1.2 (108 ocorrências de `divergencia_pagamento`, causa raiz não identificada nesta auditoria).

### 2.3 SuperFrete (frete nacional)

`frete_cotacoes` tem apenas **4 linhas na vida da tabela** — duas cotações completas (PAC + SEDEX) para dois CEPs distintos, ambas com sucesso (nenhuma falha registrada). O volume é baixo demais para tirar conclusão sobre taxa de erro. O código da função (`loja-frete/index.ts`) deixa explícito que, sem `SUPERFRETE_TOKEN` configurado, o frete nacional vira "a confirmar pelo WhatsApp" (nunca inventa valor) — **não há como confirmar pelo banco se o token está configurado neste momento**, porque segredos de Edge Function não aparecem em nenhuma tabela consultável por SQL. Recomendo ao consultor pedir para alguém com acesso ao painel do Supabase confirmar diretamente.

### 2.4 Meta Conversions API (CAPI)

**Achado relevante:** a fila `meta_eventos` tem **299 eventos, 100% com status `pendente`, 0 com erro registrado**, nos últimos 60 dias. Lendo o código de `meta-conversions-api/index.ts`:

```
const pixel = Deno.env.get('META_PIXEL_ID')
const token = Deno.env.get('META_CAPI_TOKEN')
if (!pixel || !token) return json({ ok: true, configurado: false })
```

A função **retorna sucesso silencioso** (`ok: true, configurado: false`) quando os segredos `META_PIXEL_ID`/`META_CAPI_TOKEN` não estão configurados, sem nunca tentar enviar nem gravar erro. O padrão observado (toda a fila pendente, zero erro, nenhum evento jamais marcado como enviado) é exatamente o que essa função produziria se os segredos não estiverem configurados neste ambiente. **Isso é uma falha silenciosa real e de alto impacto para o negócio**: o evento de Purchase (que nasce automaticamentte quando o pedido é pago) nunca chega à Meta por esse caminho, o que piora a otimização de campanhas pagas (o próprio dossiê principal já mostra ROAS baixo na amostra de tráfego pago — isso pode ser parte da causa, já que a Meta otimiza melhor campanhas com sinal de conversão via CAPI). **Recomendo fortemente que o consultor confirme com o time se `META_PIXEL_ID`/`META_CAPI_TOKEN` estão de fato configurados nas Secrets das Edge Functions** — não há como eu confirmar isso por SQL.

---

## 3. Falhas silenciosas de atendimento

### 3.1 Leads que mandaram mensagem e não receberam resposta

Metodologia: para cada conversa com mensagem recebida nos últimos 60 dias, comparei o horário da última mensagem recebida (`last_inbound_at`) com o horário da última mensagem enviada pela Sua Gráfica BH antes dela, procurando casos em que a última mensagem do cliente ficou mais de 10 minutos sem nenhuma resposta depois.

**Resultado: 1 caso encontrado em 60 dias — e é a conversa interna/teste (Lead #12, número do próprio dono/BauerLab), não um cliente real.** Nela, a última mensagem do cliente (10/11 19:46) ficou sem resposta por mais de 24h (a última saída tinha sido em 09/11 11:00). Como é conversa de teste, não afeta cliente real, mas é um ponto que vale confirmar manualmente (pode ser sinal de que o monitor de silêncio não cobre 100% dos casos, ou simplesmente que ninguém prioriza responder a própria conversa de teste).

**Zero casos reais de cliente verdadeiro sem nenhuma resposta em 60 dias** por esse critério — é um resultado positivo para o `agente_silencio_vigiar` (cron de 1 em 1 minuto) e `agente_retomar_travadas` (cron de 3 em 3 minutos). Ressalva de método: esse teste só pega a ÚLTIMA mensagem de cada conversa; não captura um gap no MEIO de uma conversa longa (ex.: cliente manda 2 mensagens, só a segunda é respondida, mas a conversa segue depois).

### 3.2 Mensagens duplicadas enviadas pela Laura (loop de resposta)

Busquei pares de mensagens de saída, na mesma conversa, com o mesmo texto, enviadas com menos de 3 minutos de diferença.

**Caso mais grave — loop real:** **Contato extra #02** recebeu a mesma mensagem **"Oi, tudo bem? Aqui é a Laura da Sua Gráfica BH!" seis vezes em 4 minutos e 21 segundos** (11/11, entre 18:08:47 e 18:13:13 UTC — os 6 envios caem em um padrão de "cada nova rodada repete a mensagem inteira de novo", não um reenvio isolado). Isso é consistente com um bug de loop/reprocessamento do WF1 ou de disparo duplicado do webhook da Meta para a mesma mensagem de entrada, não com uma decisão do agente.

**Outros duplicados, todos com intervalo muito curto (0,5 a 14,6 segundos) — padrão compatível com corrida/duplicação de execução (a mesma mensagem de entrada disparando o workflow duas vezes), não com decisão do agente:**

| Lead/Contato | Mensagem repetida | Intervalo |
|---|---|---|
| Lead #11 | Nome de arquivo PDF ecoado de volta ("CARTAO_PROJETO_VIVENCIAR...") | 39,8 s |
| Lead #39 | "Um de nossos consultores humanos acabou de assumir este atendimento..." | 0,5 s |
| Lead #22 | "Oi! Tudo bem? Aqui é da Sua Gráfica BH. Como posso te ajudar hoje?" | 2,6 s |
| Contato extra #01 | Link do Google Drive ecoado de volta | 14,7 s |
| Lead #40 | "[foto] Outro exemplo ilustrativo." | 1,1 s |

**Impacto direto no cliente:** no caso do Contato extra #02 (6x), o cliente recebe a mesma saudação repetidamente em menos de 5 minutos — ruído visível e pouco profissional, mesmo sem causar dano comercial. Nos outros casos (duplicação em menos de 15 segundos), o impacto prático é pequeno (quase imperceptível para o cliente), mas indica a mesma causa técnica: **possível disparo duplicado de execução do workflow de entrada para a mesma mensagem.**

### 3.3 Buscas de SKU/preço/frete que retornaram vazio ou erro

Já detalhado na tabela da seção 1.3: 22 falhas de `buscar_produto` (3,3% de 675 chamadas), 3 de `buscar_conhecimento` (1,4% de 217) e 1 de `verificar_frete` (5,6% de 18) em 60 dias. Quando falha, `buscar_produto` leva até 55,7 segundos para falhar — ou seja, o cliente fica quase um minuto esperando uma única resposta antes do agente seguir adiante avisando que vai confirmar.

Casos de SKU não encontrado no catálogo que exigiram intervenção humana (`alertas` tipo `agente_chamado`, 60 dias): crachá PVC (2 casos: Contato extra #04 e outro cliente), impressão 3D de foto para homenagem (2 casos), "boneca de jornal" fora do padrão de catálogo (múltiplos casos do mesmo cliente, Lead #25, ao longo de vários dias — sinal de que esse produto específico não está bem mapeado no catálogo e gera atrito repetido).

### 3.4 Falhas no transbordo humano

- **67 alertas `nova_mensagem_humano` (gravidade alta)** em 60 dias — disparados sempre que chega mensagem nova de cliente numa conversa já em atendimento humano, para avisar o dono/atendente.
- **0 ocorrências** do alerta de "atendimento humano parado mais de 90 minutos sem responder" (`lead_humano_parado`, implementado em `private.followup_orcamentos_abertos`) nos 60 dias — bom indício de que, quando a Laura passa a conversa para humano, alguém responde dentro da janela esperada.
- **2 ocorrências de `agente_falhou`** — "O agente não conseguiu responder (modelo ou ferramenta com erro). Nenhuma mensagem foi enviada ao cliente." Esta é a falha silenciosa mais direta do sistema: nesses 2 casos, o cliente mandou mensagem e literalmente não houve nenhuma resposta automática nem transbordo — só o alerta interno ao dono. Datas: entre 05/11 e 10/11 (mesma janela dos 2 status `erro` de `agente_execucoes` vistos na seção 1).
- **Pedidos duplicados criados pela própria Laura, corrigidos manualmente** (`pedidos_auditoria`, histórico completo): 3 casos em novembro —
  - Contato extra #03: orçamento SG-0574 "duplicado da Laura, corrigido em 19/11" (pedido 421 excluído).
  - Lead #11: dois orçamentos recriados ("o mesmo pedido foi refeito") em 19/11 — SG-0586→SG-0588 e depois substituído de novo.
  Não é uma falha de mensageria, mas é uma falha de fluxo: a Laura gerou mais de um orçamento para o mesmo pedido do mesmo cliente em sequência, e um humano precisou limpar manualmente.

---

## 4. Workflows de follow-up e recuperação

**Existe sim um fluxo ativo de follow-up/recuperação — é o mais importante do sistema e cobre tanto "lead sumiu" quanto "orçamento sem resposta" quanto "pagamento pendente".** Mecanismo: o cron do Postgres `followup-orcamentos-abertos` (`pg_cron`, a cada 10 minutos, chama `private.followup_orcamentos_abertos()`) varre orçamentos enviados e conversas paradas, e popula a tabela `followup_fila` de acordo com as 17 regras em `followup_regras`. O envio de fato é feito por `GBH \| WF6 \| Follow-ups` (a cada 15 minutos) e `GBH \| FERRAMENTA \| enviar_proativo`, por dois canais: `livre` (texto dentro da janela de 24h, via `agente-enviar`) ou `template` (template aprovado da Meta, quando a janela está fechada).

### 4.1 Regras ativas (`followup_regras`)

| Código | Gatilho | Atraso | Ativa | Mensagem/template |
|---|---|---|---|---|
| F1 | Orçamento enviado, sem resposta | 10 min | sim | Mensagem livre, sem desconto (texto montado pelo n8n, não um template fixo) |
| F2 | Orçamento enviado, sem resposta | 20h | sim | Template `orcamento_vence_hoje`: *"Oi, {{1}}! Seu orçamento {{2}} vale até {{3}}. Dá para fechar hoje e garantir a entrega no prazo. Quer que eu reenvie o link de pagamento?"* |
| F3 | Orçamento enviado, 2 lembretes sem resposta | 2 dias | sim | Desconto relâmpago de 3% (gatilho `RELAMPAGO`), template `condicao_especial_orcamento`: *"Oi, {{1}}! Consegui uma condição especial no seu orçamento {{2}}: {{3}}. Vale até {{4}}. Quer que eu envie o link de pagamento atualizado?"* |
| F4 | Última chance | 5 dias | sim | Degrau 3 (gatilho `G3`) ou template `ultima_chance_orcamento`: *"Oi, {{1}}, passando para saber se ainda faz sentido seguir com o seu pedido de {{2}}..."* |
| PAG_1H | Link de pagamento sem pagar | 1h | **não** (desligada em 18/11, substituída pela PAG_20M) | — |
| PAG_20M | Link de pagamento sem pagar | 20 min | sim | Template `pagamento_pendente`: *"Oi, {{1}}! Seu orçamento {{2}} está aguardando o pagamento. O link é {{3}}..."* |
| PAG_6H | Link de pagamento sem pagar | 6h | sim | mesmo template `pagamento_pendente` |
| PAG_24H | Link de pagamento sem pagar | 24h | sim | mesmo template `pagamento_pendente` |
| PAG_CHK | Checkout aberto, 15 min sem pagar | 15 min | sim | mesmo template `pagamento_pendente` |
| POS_ENTREGA | Pedido entregue | 1 dia | sim (revisar=true) | Template `pos_venda_avaliacao`: agradecimento + link de avaliação no Google + aviso de novidades |
| Q1 | Conversa parada (cliente quente) | 10 min | sim | Mensagem livre |
| Q1_ANUNCIO | Lead de anúncio só mandou a mensagem padrão | 5 min | sim | Opções e preços do produto do anúncio |
| Q2 | Conversa parada antes do orçamento | 20h | sim | Último lembrete livre antes de fechar a janela |
| Q2_RECUSA | Cliente respondeu frio ao preço | 1 min | sim | Tiragens menores do mesmo produto |
| RECOMPRA_ADESIVO | Pedido entregue (adesivo) | 45 dias | sim (revisar=true) | Template `recompra_lembrete` |
| RECOMPRA_CARTAO | Pedido entregue (cartão de visita) | 60 dias | sim (revisar=true) | Template `recompra_lembrete` |
| RECOMPRA_PANFLETO | Pedido entregue (panfleto) | 30 dias | sim (revisar=true) | Template `recompra_lembrete` |

### 4.2 Volume e taxa de erro real da fila (`followup_fila`, 60 dias, 323 linhas)

| Status | Total | Observação |
|---|---|---|
| `enviado` | 76 | Entregues com sucesso (69 via `livre`, 7 via `template`) |
| `cancelado` | 133 | Cancelado porque o cliente respondeu antes, pagou antes, ou a condição deixou de valer — comportamento esperado, não falha |
| `pendente` | 41 | Na fila aguardando a hora agendada |
| `pulado` | 34 | Pulado por regra de negócio (ex.: fora do horário comercial, regra desativada) |

**Taxa de erro real do envio:** não há status `erro` na tabela `followup_fila` em si (as tentativas que falham 3x viram alerta, não um status na fila) — os **5 `erro_followup` da seção 1.5** (PAG_1H x2, PAG_6H x2, PAG_24H x1) são as falhas de entrega reais identificadas: follow-ups que tentaram enviar e falharam 3 vezes seguidas. Isso dá uma taxa de falha de entrega de aproximadamente **5 em 323 (1,5%)** sobre o volume total da fila nos 60 dias — baixa, mas real.

### 4.3 Recuperação de checkout/Pix abandonado

Cobertura pelas regras `PAG_20M`, `PAG_6H`, `PAG_24H` e `PAG_CHK` acima — ou seja, **existe sim recuperação ativa de link de pagamento/Pix não pago**, com lembrete em 15–20 minutos, 6 horas e 24 horas. `estrategia_recuperacao` (19 linhas) é uma tabela de política/roteiro — não um gatilho automático — que orienta a ordem de argumentos por motivo da objeção (ex.: motivo `abandonou_checkout` → passos `ajudar_checkout` → `pix` → `parcelar_2x`; motivo `preco` → `esclarecer` → `alternativa_real` → `pix` → `parcelar_2x` → `condicao_especial`). Ela parece ser consumida pela Laura/n8n como guia de conversa, não como um job agendado — não encontrei nenhum cron ou workflow que leia essa tabela diretamente como gatilho.

### 4.4 Carrinho abandonado da loja (e-commerce) — GAP REAL, sinalizado explicitamente

A tabela `carrinhos_abandonados` existe no schema (campos `avisado_em`, `status`), mas:

- Só tem **4 linhas na vida inteira da tabela** (9 e 15/11/2026).
- **100% com `status = 'aberto'` e `avisado_em = null`** — nenhum dos 4 carrinhos abandonados recebeu qualquer tentativa de recuperação.
- **Não existe nenhum job de `pg_cron` nem workflow do n8n dedicado a processar essa tabela** — revisei a lista completa de `cron.job` ativos e nenhum menciona `carrinho` ou `abandonado`.

**Conclusão explícita pedida: não existe, hoje, nenhuma automação ativa de recuperação de carrinho abandonado do site/e-commerce.** A infraestrutura de dados para isso já existe (a tabela e os campos), mas falta o job que leia `carrinhos_abandonados` e dispare um contato. É diferente do fluxo de "orçamento enviado pela Laura no WhatsApp", que tem recuperação completa (seção 4.1–4.3); o gap é especificamente o carrinho montado no site antes de chegar a uma conversa de WhatsApp.

---

## 5. Resumo agrupado por tipo de erro

| Tipo de erro | Ocorrências (60 dias) | Impacto direto no cliente | Exemplo/Lead |
|---|---|---|---|
| Divergência pagamento x pedido (`divergencia_pagamento`) | 108 | Nenhum visível ao cliente (checagem interna); causa raiz não identificada nesta auditoria | "Pagamento e pedido SG-0260 não conferem" |
| Erro genérico de serviço externo (timeout Gemini/MP) (`outro`) | 36 | Pode atrasar resposta/follow-up naquele minuto | "The service was not able to process your request" |
| Falha de `buscar_produto`/`buscar_conhecimento`/`verificar_frete` | 26 | Cliente espera até 55,7s por uma resposta que vira "vou confirmar" | Lead #05, Lead #10, Lead #40 |
| Erro de workflow n8n (`erro_workflow`) | 20 | Indireto — segue sem travar o atendimento ("nada foi refeito sozinho") | WF1, WF6, WF7, WF8, WF5, montar_orcamento |
| Trava de saída bloqueando conteúdo proibido (`saida_bloqueada`) | 9 | Positivo — cliente recebeu frase neutra em vez de informação indevida | preço não verificado, vazamento de endereço/custo |
| Falha de entrega de follow-up após 3 tentativas (`erro_followup`) | 5 | Cliente não recebe o lembrete esperado (PAG_1H/6H/24H) | — |
| Mensagem duplicada/loop da Laura | 6 casos distintos (1 grave: 6x) | Visível ao cliente, ruído, sem dano comercial | Contato extra #02 (6x em 4min21s) |
| Falha de ferramenta explícita (`falha_ferramenta`) | 6 | Baixo — agente avisa que vai confirmar em vez de inventar | buscar_produto, verificar_frete, buscar_conhecimento |
| Pedido pago fora das regras de catálogo (`pedido_fora_das_regras`) | 6 | Nenhum (pagamento mantido), mas item sem SKU no catálogo | SG-0417, SG-0220, SG-0295, SG-0411, SG-0294, SG-0023 |
| Erro de mídia no WhatsApp (131053) | 2 | Áudio enviado pela Laura não chegou ao cliente | Contato extra #01 |
| Pedido duplicado criado pela Laura, corrigido manualmente | 3 | Nenhum dano ao cliente, mas retrabalho manual do dono | Contato extra #03, Lead #11 |
| Agente falhou sem enviar nada (`agente_falhou`) | 2 | **Alto — cliente mandou mensagem e não recebeu nenhuma resposta automática** | entre 05/11 e 10/11 |
| Erro de janela de 24h bloqueando envio | 2 (1 mensagem de confirmação de pagamento + 1 orçamento pronto) | Cliente não recebe a mensagem na hora; precisa de template ou nova mensagem do cliente | Lead #12 (interno), SG-0599 |
| Sessão de scraping do fornecedor caída | 3 | Indireto — Laura para de conferir preço/tamanho ao vivo até alguém logar de novo na VPS | — |
| Pagamento recusado sem resolução marcada | 1 (histórico completo) | Nenhum ao cliente (foi pago depois por outro caminho); gap de dado interno | Lead #28, SG-0296 |
| Falha no Bling por CPF duplicado | 1 | Nenhum ao cliente; pedido não sincronizou com o Bling | Pedido interno 417 |
| Meta CAPI nunca consumindo a fila (inferido do código) | 299 eventos parados, 0 enviados | Nenhum direto ao cliente; impacto indireto na otimização de campanhas pagas | Fila `meta_eventos` completa |
| Carrinho abandonado sem recuperação (gap de automação) | 4 (histórico completo), 100% sem aviso | Cliente que abandonou o carrinho no site nunca é procurado de volta | — |
