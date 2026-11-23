# Progresso do agente de IA

## 22/11/2026: indexação do conhecimento a cada 5 minutos
O cron `conhecimento-reindexar` rodava a cada 6 horas (a documentação dizia 5 min), então ficha editada ficava até 6 h sem vetor. Migration `20261222000013` passa para `*/5 * * * *` (a função só processa trechos sem vetor). Também atualizada a ficha `frete_fora` (entrega por aplicativo a combinar) e reindexada.

## 22/11/2026: checkout, entrega que não abria e checkout mais enxuto
- **Causa raiz do "Não conseguimos carregar agora" ao escolher a entrega:** a linha de frete entra no pedido como repasse (custo = valor) e o gatilho `order_items_validar` barrava como "abaixo do piso duro" (valor x (1 - imposto - taxa) < custo). Ou seja, QUALQUER frete pago (Correios ou aplicativo) falhava com P0001 (visto nos logs de `checkout-dados`). Migration `20261222000012`: a trava de piso não se aplica à linha de frete do checkout (`checkout_extra` + descrição "Frete"); continua valendo para produto e arte. A linha agora se chama "Frete Correios ..." para o orçamento PDF ignorá-la, como já fazia.
- **Entrega por aplicativo deixou de ter valor fixo:** `loja-frete` devolve a opção com `a_combinar: true` (valor 0, sem número). No checkout aparece "A combinar" e o texto explica que o valor é calculado na hora da entrega e não entra no pagamento. O pedido guarda a escolha numa linha de frete a R$ 0,00 (fora do orçamento) e registra o evento. A Laura/equipe combina o valor no WhatsApp.
- **Checkout mais curto:** caminho principal = dados (recolhidos se já cadastrados), arte e pagamento. Entrega, quantidade, cupom e "levar mais alguma coisa" (sugestões + busca) viraram linhas recolhidas (`components/pagar/Linha.tsx`) mostrando a escolha atual; numeração dos títulos removida e texto de abertura encurtado.
- Validação: `npm run gate` e typecheck/build da loja verdes; transações com rollback no banco (Correios e aplicativo, como service role). `loja-frete` implantada pelo conector (v16). `checkout-dados` não mudou.

## 22/11/2026: prévia de arte virou mockup real (image-to-image)

O dono testou a prévia e mandou print: a arte saía "a parte" (um cartão de visita chapado ao lado da foto do catálogo), quando o certo é o produto de verdade com a informação do cliente aplicada nele, como se tivesse mandado a peça em branco e pedido "coloca isso aqui". Perguntado, o dono escolheu a abordagem "IA gera a imagem final direto" em vez de overlay fixo por categoria.

- **Geração deixou de ser HTML/texto e virou image-to-image**: o worker (`previa-arte-processar`) agora manda a FOTO REAL do produto (baixada do Storage, em base64) junto com o prompt para o Gemini (`generationConfig.responseModalities: ['IMAGE']`) e recebe de volta a imagem já pronta — o produto, na mesma pose/material/perspectiva da foto, com a arte do cliente aplicada de forma realista. `_shared/previa-arte.ts` trocou `montarPromptArte`/`extrairHtml` por `montarPromptMockup`/`extrairImagemGemini`; `montarPaginaPreview` agora só emoldura a imagem recebida e aplica a marca d'água por código (nunca pelo modelo, como antes).
- **Modelo**: `gemini-3.8-flash-image` (primeira tentativa, mesmo padrão de nome do texto) devolveu 404; `gemini-2.5-flash-image` funcionou e ficou como padrão de `PREVIA_ARTE_MODELO`.
- **Testado**: nova geração de ponta a ponta no token de teste existente — `status = 'pronta'`, sem `erro_detalhe`, `resultado_path` preenchido (o worker só marca `pronta` depois do Gemini devolver imagem e do Gotenberg renderizar o PNG com sucesso; qualquer falha nessas etapas vira `erro`).
- Frontend (`PreviaCliente.tsx`/`ChromeLoja.tsx`) não precisou de nenhuma mudança — já mostrava a foto do produto e o resultado como imagens separadas antes/depois da geração.

**Validação:** `npm run gate` verde; geração real confirmada ponta a ponta (fila → Gemini com foto do produto → Gotenberg → bucket → status `pronta`). Sem cenários `e5-*`/`mvp-*`/`e12-*`/`e17-*` do Gemini de produção.

## 21/11/2026 (correção): SuperFrete (Correio/PAC) também dentro de BH
O fix do item 1 abaixo só adicionava a opção de aplicativo dentro da Grande BH, sem chamar o SuperFrete — o dono pediu as 3 opções sempre disponíveis para pedidos em BH: retirada grátis, aplicativo (valor na hora do envio) e Correio/PAC. `loja-frete` agora chama o SuperFrete em todos os casos (dentro ou fora de BH) e soma as opções em vez de escolher uma ou outra. Testado: CEP de BH (30670020) devolve SEDEX, PAC e aplicativo juntos; Ubatuba (fora de BH) e Centro de BH (frete grátis) continuam corretos.

## 21/11/2026: 4 frentes (frete perdido, prévia de arte, alertas/condição 24h, recompra)

Pedido do dono com 4 itens prioritários.

- **1. Frete não calculava (venda real perdida, atendimento do bairro Castanheira):** causa raiz: `loja-frete` (chamada por `checkout-dados` no `/pagar/<token>`) só cotava pelo SuperFrete fora da "Grande BH"; dentro da Grande BH mas fora dos 7 bairros centrais grátis, devolvia `envio: { opcoes: [] }` sem nenhuma alternativa — o checkout não tinha nada pra mostrar. Corrigido: nesses CEPs, `loja-frete` agora expõe a opção "Entrega por aplicativo" com o valor de referência que `verificar_frete` já calcula (o mesmo valor que a Laura usa manualmente no WhatsApp). Testado com o CEP real da cliente (30670020): `envio.disponivel = true`, `R$ 25,00`. Regressão conferida: bairro central (frete grátis) e CEP fora de BH (SuperFrete PAC/SEDEX) continuam iguais.
- **2. Prévia de arte, 3 bugs reais:**
  - `previa_arte_regenerar` (botão "Tentar de novo") só aceitava `status='pronta'`; depois de qualquer falha do worker (`status='erro'`), o botão existia mas não fazia nada. Corrigido: aceita `erro` também.
  - Causa raiz do "quadrado branco": o modelo gerava CSS decorativo extenso (ribbons, badges) e era cortado pelo limite de tokens ainda dentro do `<head>`, antes do conteúdo da arte. `maxOutputTokens`/`max_tokens` 2000→8192 e prompt reescrito (só `<div id="arte">` com estilo inline, proíbe ornamentos). Validação real do HTML antes de marcar `pronta` (tamanho mínimo, tags balanceadas, não pode terminar truncado). Confirmado com log de diagnóstico temporário (removido depois) e nova geração real de ponta a ponta.
  - Worker disparado imediatamente ao enviar o formulário (`EdgeRuntime.waitUntil`); cron reduzido de 1 para 5 minutos, só como reforço.
  - Página `/previa/<token>` sem cabeçalho/menu/carrinho da loja (`ChromeLoja`); arte renderizada sozinha (sem compor com a foto do catálogo, que agora é mostrada separada, `object-contain`); foto e prévia clicáveis para ampliar; formulário com um único campo de texto (até 500 caracteres) em vez de vários campos; animação de carregamento em etapas.
  - Limpeza automática: `previa_arte_limpar_expiradas`, chamada pelo worker a cada cron, remove do banco e do Storage as prévias com mais de 48h de pedidos não pagos (preserva as de pedidos pagos).
- **3. Alertas recorrentes e condição especial pós-24h:** auditoria dos alertas dos últimos 7 dias não mostrou volume anormal (a fila está saudável desde os ajustes de gravidade de 17-18/11). `alertas-enviar` aparece nos logs a cada minuto só como polling vazio (sem alerta pendente), sem origem em `pg_cron` nem no n8n desta conta — não achei a fonte exata da chamada e não é prejudicial (não gera envio nem custo de API), então não mexi nisso para não arriscar quebrar algo sem causa raiz confirmada. **PAG_24H corrigido de fato:** antes só repetia a cobrança fria; agora, sem uma condição especial já vigente, aciona `oferecer_condicao_especial` (gatilho G1, vantagem operacional) para tentar destravar o fechamento, sempre respeitando piso e piso duro (se a trava de lucro recusar, volta ao texto normal sem nenhuma mudança visível).
- **4. Recompra (30 dias):** `RECOMPRA_CARTAO`/`RECOMPRA_ADESIVO`/`RECOMPRA_PANFLETO` estavam escalonadas (60/45/30 dias) e marcadas `revisar=true`. O mecanismo de agendamento (`trigger orders_entregue_agenda` + `private.fu_agendar_pos`) já funcionava certo, inclusive para pedidos futuros (confirmado com um pedido real já entregue). Padronizado para 30 dias e `revisar=false`; reagendada a linha pendente existente e rodado o backfill para todo pedido já entregue (só havia 1 caso real elegível, já coberto).

**Validação:** `npm run gate` verde; teste real do frete com o CEP da cliente; teste real de geração de prévia de ponta a ponta (2ª causa raiz corrigida depois de diagnóstico com log temporário). Sem cenários `e5-*`/`mvp-*`/`e12-*`/`e17-*` do Gemini de produção.

## 20-21/11/2026 (Fase 2, continuação): segredo cadastrado, prompt liberado e geração real testada

O dono cadastrou `PREVIA_ARTE_API_KEY` (Gemini) e `PREVIA_ARTE_PROVEDOR=gemini` nas Secrets.

- **Worker já reconhecia o provedor**: `previa-arte-processar` já lia `PREVIA_ARTE_PROVEDOR` (padrão `gemini`) e, com Gemini, usava `PREVIA_ARTE_MODELO` ou um modelo padrão. Nenhuma mudança necessária para o reconhecimento em si.
- **Bug real achado no teste**: o modelo padrão (`gemini-2.0-flash`) estava descontinuado e devolvia 404 em toda tentativa de geração (mesmo padrão de descontinuação já visto com `gemini-2.5-flash`/`gemini-2.5-flash-lite` nas notas de 18/11). Corrigido: fallback passa a ser `gemini-3.8-flash`, o mesmo modelo já confirmado funcionando em produção no agente de atendimento (`agente_config.modelo_padrao`). Redeployado.
- **`gerar_link_previa` liberado no prompt**: regra ARTE E AMOSTRA do WF2 (nó "Prompt consolidado (Fase 1)") ganhou a chamada condicional — só para lead qualificado (produto e quantidade já definidos, ou orçamento já aberto) que pede prévia/amostra ou trava por medo de pagar antes de ver a arte; nunca na primeira mensagem nem sem qualificação. Publicado e reexportado para `n8n/GBH-WF2-Agente.json`.
- **Teste de geração real**: criada uma prévia de teste num orçamento real existente (`previa_arte_criar`), aguardado o agendamento de 1 minuto (`previa-arte-processar`, `pg_cron`) processar a fila. Primeira tentativa confirmou o bug do modelo (status `erro`, `gemini: 404`); após a correção e reset do item, a segunda tentativa concluiu com `status = 'pronta'` e `resultado_path` preenchido (PNG de ~350 KB no bucket privado `previas-arte`). Marca d'água é aplicada incondicionalmente pelo código (`montarPaginaPreview`, 48 repetições de "PRÉVIA · SUA GRÁFICA BH" sobre a imagem), não depende do modelo. `previa_arte_status` confirmou o vínculo com o pedido (`order_id`), o caminho de `/previa/<token>` para `/pagar/<token>` depois de "Gostei, quero fechar agora". A trava de saída (`agente_saida_segura`/`agente_saida_base_execucao`) não tem nenhum bloqueio de link por domínio, então o link de `/previa/<token>` passa normalmente. Linha de teste removida do banco depois da validação (o PNG de teste ficou órfão no bucket privado, sem risco: nunca é exposto por URL pública ou assinada sem o token certo).

**Validação**: `npm run gate` verde; geração real confirmada ponta a ponta (fila → Gemini → Gotenberg → bucket → status `pronta`).

## 20/11/2026 (Fase 2): gerador de prévia de arte com marca d'água (`/previa/<token>`)

Implementa a Fase 2 do Plano de Ação (prévia de arte), depois do Passo 1 (blindagem) e dos 6 bugs urgentes já mesclados.

- **Fila e travas no banco**: tabela `previas_arte` com status (`pendente`/`processando`/`pronta`/`erro`/`aguardando_limite`), expiração de 48h e contadores `geracoes` (máx. 2) e `ajustes` (máx. 1, à parte das gerações); depois do limite, o feedback só é salvo (`orcamentos.alternativas`) para a equipe de criação aplicar na arte final pós-pagamento, sem gastar API de novo. `previa_arte_fechar` roda `validar_margem` antes de converter o orçamento em pedido para o botão "Gostei, quero fechar agora". Testado em transação com rollback (criar, reutilizar, 1ª e 2ª geração, 3ª bloqueada, ajuste, 2º ajuste só salva, fechar). Migrations `20261222000006` e `20261222000007` (agendamento).
- **Worker** (`previa-arte-processar`, Edge Function): usa só API oficial configurável por variável de ambiente (Claude ou Gemini, nunca credencial de assinatura pessoal), monta a arte em HTML, sobrepõe à foto real do produto com marca d'água forte e renderiza em PNG no Gotenberg (mesmo serviço do PDF de orçamento). Sem a chave configurada, alerta o dono (gravidade alta) em vez de falhar quieto — mesmo padrão já usado na Meta CAPI. Limite de taxa da API vira `aguardando_limite`, tenta de novo em 5 min, e quando sai dessa situação a Laura avisa o cliente no WhatsApp com o link atualizado.
- **Página `/previa/<token>`** no e-commerce: briefing, upload de até 2 imagens, acompanhamento (polling), resultado com marca d'água e os botões de fechar/gerar de novo/ajustar.
- **Ferramenta nova do despachante**: `gerar_link_previa` (15ª ferramenta; as 14 anteriores do Plano de Ação continuam 100% intactas), recebe `orcamento_id` e devolve o link `/previa/<token>`. **Ainda não está chamada pelo prompt da Laura** (fica para o dono decidir quando ligar essa regra, por ser uma chamada de API paga por geração).
- Achado de passagem corrigido no caminho: o export de `GBH-WF2-Agente.json` no repositório tinha uma duplicação (um `parameters.jsCode` órfão dentro do próprio `parameters`), introduzida por uma edição anterior feita com script em vez de reexportar direto do n8n. Já saneado nos últimos reexports (bugs urgentes e Fase 2).

**Validação**: `npm run gate` e `typecheck` do e-commerce verdes. Sem teste ponta a ponta com chave real de Claude/Gemini (nenhuma foi configurada nesta sessão); o worker foi validado só até o ponto do alerta por falta de segredo.

**Pendências para o dono**: cadastrar `PREVIA_ARTE_API_KEY` (e opcionalmente `PREVIA_ARTE_PROVEDOR`/`PREVIA_ARTE_MODELO`) nas Secrets das Edge Functions do Supabase para o worker funcionar de verdade; decidir se e quando o prompt da Laura deve chamar `gerar_link_previa` sozinha.

## 20/11/2026 (bugs urgentes): 6 bugs reais achados pelo dono em atendimentos do dia

Auditoria de 3 atendimentos reais citados pelo dono, mais 2 pedidos de complemento. Causas raiz e correções:

1. **Mensagem cortada no meio** (+55 31 7183-5487, 12:10): a rodada gastou só 171 tokens de saída com `maxOutputTokens=2048` no nó Gemini — plausível que parte do orçamento de tokens tenha ido para "thinking" interno do modelo, cortando o texto visível no meio de uma medida. `maxOutputTokens` subiu para 4096 e o nó "Resposta vazia ou vazou ferramenta?" ganhou uma nova condição: texto com mais de 30 caracteres que não termina em pontuação final (`. ! ? : ) "` ou reticências) nem em link, repete a chamada automaticamente (mesmo mecanismo já usado para resposta vazia).
2. **Follow-up citando produto errado ("bottons")** (+55 31 7532-6778): `private.fu_assunto` lia as últimas 10 mensagens **de qualquer direção** (inclusive as da própria Laura) com palavras-chave **sem borda de palavra**; a palavra "stamping" (hot stamping, pedido do cliente) bateu no padrão `pins?` pela substring "pin" dentro dela, e como a mensagem da Laura (que repetiu "hot stamping" ao recusar) era mais recente que a do cliente, venceu o assunto errado. Corrigido: todos os padrões agora usam borda de palavra (`\y`) e a função só olha mensagens do cliente (`direction = 'in'`). Preço sem especificar cor/acabamento: reforçada a regra do prompt (toda vez que citar preço, dizer a impressão exata e o papel/acabamento na mesma frase; nunca citar preço de 1x0/1x1 como se fosse o padrão colorido).
3. **"Oi, cliente!"** (+55 31 9434-2736, nome cadastrado só com "."): a regra de identidade já proibia isso, mas o modelo não seguiu numa abertura de anúncio real. Trava determinística nova em `private.saida_travas_extra`: texto que chama o contato de "cliente" como vocativo e contato sem nome válido (`private.fu_nome` nulo) é bloqueado e saneado.
4. **"Pix de qualquer banco" removido de todo o sistema** (decisão do dono): achado em `private.fu_texto_anuncio`, `fu_texto_tiragens_menores`, `followup_montar_base` (PAG_CHK/PAG_20M), `private.cobertura_processar`, na tabela `conhecimento` (base do `buscar_conhecimento`, 4 linhas), em `orcamento-pdf` (texto do link no WhatsApp), no prompt do WF2, na sticky note do `gerar_link_pagamento`, no site (`Resumo.tsx`, `PagamentoPix.tsx`, `CheckoutCliente.tsx`, `ajuda.ts`) e no banner de checkout (`scripts/gerar-banner-checkout.cjs`, banners regerados). Ficou só "Pix" e "cartão em até 2x sem juros". `test-contratos.ts` ganhou um guarda-corpo para não deixar a frase voltar ao prompt do WF2.
5. **Regra Q1_ANUNCIO desligada**: disparava 5 minutos depois da abertura de anúncio com texto antigo (lista com marcadores, "qualquer banco", SKUs ruins como Kraft 1 cor e Hotstamping R$ 453,90) mesmo quando a Laura já tinha dado preço na primeira resposta — a nova regra ABERTURA DE ANÚNCIO da Fase 1 tornou esse follow-up redundante e, nesse caso, prejudicial. `followup_regras.ativo = false` para o código `Q1_ANUNCIO`.
6. **Oferta inicial de cartão de visita**: nova regra no prompt (ABERTURA DE ANÚNCIO) — mostrar primeiro só opções coloridas frente e verso (4x4), variando papel e acabamento, em tiragens de 500 ou 1.000 unidades; nunca kraft, preto e branco (1x0/1x1) ou colorido só frente (4x0) de cara, só se o cliente pedir, reclamar do valor ou comparar com concorrente.

**Achado de passagem corrigido**: o push anterior (Passo 1) tinha regenerado o prompt do WF2 a partir de uma cópia desatualizada e sem querer revogou 2 correções já testadas com Gemini real na Fase 1 (limite de 300 caracteres por mensagem e a proibição de dizer "aprovado"/anunciar o link). Restauradas junto com os fixes de hoje.

**Validação**: `npm run gate` verde (typecheck, testes incluindo `test:contratos` com o novo guarda-corpo, build) e `typecheck` do e-commerce verde. Todas as correções são de banco/infra/prompt, sem gasto de Gemini de produção (regra do dono de 17/11).

## 20/11/2026 (Passo 1): blindagem final da Fase 1 e validação da Meta CAPI

Fecha os 3 itens que a Fase 1 tinha deixado "auditado, não corrigido" (seção abaixo), mais a confirmação de que a fila da Meta CAPI voltou a fluir depois que o dono cadastrou as Secrets.

- **Meta CAPI validada**: com `META_PIXEL_ID` e `META_CAPI_TOKEN` já cadastrados pelo dono, a fila de `meta_eventos` está fluindo (102 `enviado`, 197 `descartado` — 100% são o backlog antigo de antes da correção, fora da janela de 7 dias que a Meta aceita, descarte esperado e correto; nenhum pendente travado). Arquitetura de dedup Pixel×CAPI conferida no código (`ecommerce/lib/meta.ts`, `ecommerce/components/MetaPixel.tsx`, gatilho `private.meta_purchase_do_pedido`): mesmo `event_id` nos dois lados, Purchase só por CAPI (sem pixel de Purchase no navegador, então sem risco de dedup). **Depende do dono**: confirmar que `NEXT_PUBLIC_META_PIXEL_ID=1836813490851540` está nas variáveis de ambiente do site na Hostinger (fora do alcance desta sessão, que só vê o Supabase).
- **Timeout de `buscar_produto`**: reduzido de 20 s/25 s para 12 s/10 s nos dois nós que chamam `buscar_produto` (busca principal e busca de reserva simplificada), eliminando a espera de até 55,7 s que podia deixar o cliente no vácuo antes de `chamar_dono`. Workflow `GBH | FERRAMENTA | buscar_produto` publicado.
- **Loop de saudações duplicadas no WF1 (Contato extra #02)**: causa raiz encontrada. O nó "Trava da conversa" chama `agente_iniciar` com `retryOnFail` (até 3 tentativas, timeout de 20 s). Se a 1ª chamada já travar a rodada no banco (`status = 'rodando'`) mas a resposta HTTP demorar e o n8n desistir por timeout, a 2ª tentativa (mesma mensagem) não se via como bloqueio — o filtro `id <> v_ex.id` da checagem de "ocupado" só olha outras execuções da mesma conversa, nunca a própria. Resultado: a 2ª tentativa também recebia `ok=true` e o WF1 rodava a mensagem inteira de novo (Gemini + envio no WhatsApp), produzindo saudações repetidas. Corrigido em `agente_iniciar` (migration `20261222000005`): reconfere o status da própria execução já dentro da trava da conversa e devolve `ok=false, motivo='ja_processada'` se ela já estiver `rodando` ou `concluida`; o WF1 trata isso do mesmo jeito que "ocupado" (espera e tenta de novo), sem precisar de nenhuma mudança no workflow.
- **Divergência preço-texto × PDF/link (Lead #15)**: `orcamento-pdf` e `preparar_link_pagamento` já recusam orçamento `cancelado`/`pago`/`perdido`/vencido, e `preparar_link_pagamento` já confere que o total do pedido bate com o do orçamento antes de liberar o link (achados confirmados, nenhuma mudança necessária nesses dois). O risco real era de origem (SKU errado passado ao `montar_orcamento`, diferente do que a Laura acabou de citar ao cliente): reforçada a regra de PREÇO E FERRAMENTAS no prompt do WF2 — o SKU passado para `montar_orcamento` tem que ser exatamente o mesmo que `buscar_produto` devolveu para a opção citada nesta rodada, nunca reaproveitado de rodada anterior nem de memória.

**Validação**: `npm run gate` verde. Fix de `agente_iniciar` e do timeout de `buscar_produto` são mudanças de banco/infra puras, sem necessidade de gastar o Gemini de produção (regra do dono de 17/11). O reforço de SKU no prompt do WF2 não foi validado com um teste `e5-*`/`e17-*` real (ficaria acima do limite combinado de 2 testes por mudança já usados na Fase 1); o dono deve observar `/laura` e `agent_logs` nos próximos dias.

## 20/11/2026: Plano de Ação, Fase 1 (branch `claude/brave-noether-sf9eqk`, PR em aberto)

Auditoria completa do funil antes de qualquer mudança (banco, n8n e 60 dias de logs). Achados e correções:

- **Piso de R$ 65 em pedido composto** (regra de negócio do dono, a mais importante do pedido): confirmado que `calcular_preco` aplicava o piso `maior entre (custo x 1,5, custo + R$ 65)` **por item**, isolado. Num pedido de 2+ itens em que ambos ficassem abaixo do próprio piso de R$ 65, o pedido acabava exigindo 2x R$ 65 de lucro bruto em vez de 1x. Corrigido (`calcular_preco` ganhou os parâmetros `piso_sem_lucro_minimo` e `preco_minimo_reais`; `private.montar_orcamento_base` usa o piso relaxado em pedido composto e cobre a diferença numa única linha, a de maior valor, só se o conjunto ainda não chegar a R$ 65). Piso de custo x 1,5 e piso duro continuam cheios, por item, sem nenhuma relaxação. **O catálogo real de hoje já tem lucro bruto ≥ R$ 65 em toda linha (20.390 SKUs), então a correção não muda nenhum preço em produção agora** — é estrutural, para proteger pedidos compostos no futuro. Testado com item temporário em transação com rollback: pedido de 2 itens caiu de R$ 151,80 (comportamento antigo) para R$ 85,80; pedido de 1 item ficou idêntico (R$ 75,90, zero regressão). Migration `20261222000002`.
- **WF2 (prompt da Laura) consolidado**: tinha o `systemMessage` fixo de 37 regras (~15 mil caracteres) mais 9 nós de código encadeados ("Regras adicionais", acumulados desde 17/11), passando de 50 mil caracteres de instrução antes do histórico — causa direta da latência P95 de 85,7 s. Virou um bloco único de ~7,5 mil caracteres, sem contradições, com todas as travas preservadas (detalhes em `docs/n8n-mapa.md`). Novo: nunca chamar de "cliente" sem nome; lead de anúncio com produto identificado mostra 2 a 4 opções com preço já na primeira resposta (revoga a regra antiga que proibia isso); foto enviada na hora quando o cliente pede para ver produto/acabamento; link de pagamento mandado uma vez só; selo de aprovação da arte + reembolso + frete/retirada grátis ao enviar orçamento/link; limite de 1-2 `buscar_produto` por rodada. As 14 ferramentas do despachante continuam 100% intactas. `npm run gate` com `test-contratos.ts` ajustado para checar a substância das regras no texto novo (os rótulos antigos por letra/número deixaram de existir).
- **Fallback "cliente"**: `private.fu_nome` nunca mais devolve a string "cliente" quando o contato não tem nome (devolve `null`; `followup_montar_base`, `fu_texto_q`, `fu_texto_anuncio` e `fu_texto_tiragens_menores` tratam a saudação sem nome). Migration `20261222000003`.
- **"Pagamento do orçamento" → "fechamento do seu pedido"**: caso real localizado e confirmado (contato `08d9b350-6a22-44c1-b136-0dff8616a8f1`, Vanderlei Alves, tel. 5531991044661): o lembrete `PAG_6H` dizia "Só lembrando do pagamento do orçamento SG-0570", o cliente achou que o orçamento (gratuito) estava sendo cobrado e precisou de 4 mensagens para se tranquilizar. Era a única ocorrência ativa da frase (as demais eram em SQL antigo/snapshot). Corrigido na mesma migration.
- **`pagamentos_alertas.resolvido_em`**: nunca era marcado quando o pedido era pago por outro caminho depois de um alerta de recusa (achado real: alerta do pedido SG-0296, nunca resolvido mesmo pago depois). `private.confirmar_pagamento` agora fecha os alertas abertos do pedido ao confirmar o pagamento, qualquer que seja a origem. Migration `20261222000003`.
- **108 linhas órfãs de `erros_operacao` (tipo `divergencia_pagamento`)**: causa raiz encontrada — 100% apontavam para pedidos já inexistentes no banco (não é um bug ativo, a função que gera o alerta já só olha pedidos existentes). Limpas na mesma migration.
- **Meta Conversions API silenciosa**: confirmado no código que, sem `META_PIXEL_ID`/`META_CAPI_TOKEN`, a função devolvia `{ok:true, configurado:false}` sem nunca avisar ninguém (299 eventos de Purchase parados na fila, 100% pendentes, 0 erro). Agora grava um alerta de gravidade alta (deduplicado por dia) com o nome do(s) segredo(s) que faltam. **Depende do dono**: cadastrar `META_PIXEL_ID` e `META_CAPI_TOKEN` nas Secrets das Edge Functions do Supabase (painel do projeto `bhlosshvwmlyzhbghsrc`); depois disso a fila de 299 eventos é consumida sozinha pelo cron existente, sem precisar de mais nada.
- **Carrinho abandonado sem nenhuma automação** (achado real: 4 linhas na vida da tabela, 100% sem aviso, nenhum cron lia `carrinhos_abandonados`): novo cron de 15 em 15 minutos (`private.carrinho_abandonado_varrer`) reaproveita a fila de follow-up e o WF6 que já existem — carrinho parado há 30 min com WhatsApp conhecido e janela de 24h aberta entra em `followup_fila` (regra `CARRINHO_ABANDONADO`, mensagem livre); sem janela aberta (não dá para iniciar conversa sem template aprovado pela Meta), gera alerta de gravidade baixa para contato manual em vez de ficar em silêncio para sempre. Migration `20261222000004`.

**Validação**: `npm run gate` verde (typecheck, todos os testes incluindo `test:contratos`, build). Testes de banco feitos em transação com `ROLLBACK` (piso composto, limpeza de `erros_operacao`, `carrinho_abandonado_varrer`) ou chamada direta à RPC com rollback (`alerta_criar`) — nenhum dado real foi alterado nos testes.

**2 testes com o Gemini real, autorizados pelo dono** (webhook de teste do WF1, `testes_conversa`):
- `e2e-c5-anuncio-cartao-premium-f1-t1` (lead de anúncio de cartão de visita premium): a Laura abriu cumprimentando, citou a Black Friday (arte grátis até 30/11) e mostrou 3 opções reais com preço já na primeira resposta, sem perguntar "o que você quer produzir" — a regra nova funcionou. O teste marcou `ultimo_status = falhou` por `saida_insegura:[repeticao:frase]` (trava de saída achou frase repetida entre as mensagens da resposta); não investigado a fundo (ver abaixo).
- `e17-02-cracha-mais-cordao-composto` (5 crachás + 5 cordões): `montar_orcamento` calculou certo (R$ 94,90 + R$ 101,90 = R$ 196,80, R$ 39,36 por conjunto) — confirma que a correção do piso por pedido composto não quebrou o cálculo do kit. O teste falhou por **dois problemas reais, já corrigidos** sem gastar mais Gemini: (1) `mensagem_longa` — a regra de ESTILO dizia "mensagens curtas" sem número, voltei o limite de 300 caracteres por mensagem; (2) o modelo pediu "APROVADO" e disse que ia mandar o link, contrariando a decisão de 18/11 — reforcei a proibição de forma mais direta ("É TERMINANTEMENTE PROIBIDO escrever a palavra aprovado"). Essas duas correções **não foram validadas de novo com o Gemini** (já no limite de 2 testes); o dono deve acompanhar isso no atendimento real (`/laura`, `agent_logs`).
- `saida_insegura:[repeticao:frase]` apareceu nos dois testes. Pela trava `agente_saida_segura` barrar frase repetida nos últimos 90 minutos da conversa, e os dois testes serem conversas novas, a suspeita é que isso vem do mecanismo de retentativa do próprio WF2 ("Repetir a chamada ao agente") comparando a segunda tentativa com a primeira — não confirmado, não é um problema introduzido pela consolidação do prompt (o mecanismo é anterior). Vale o dono observar se isso aparece também em conversas reais.

### O que ficou de fora desta Fase 1 (auditado, não corrigido — ver razão)
- **Loop de 6 saudações em 4min21s** (Contato extra #02, achado do dossiê de auditoria de 20/11): causa raiz não investigada a fundo (suspeita: retry da trava de conversa ocupada do WF1 reinicia a saudação do zero em vez de checar se já respondeu). Precisa de inspeção direta dos nós de trava/debounce do WF1 antes de mexer, para não arriscar quebrar a idempotência que já funciona bem hoje (zero duplicata por `wa_message_id` em 60 dias).
- **Timeout de `buscar_produto`** (hoje chega a 55,7 s antes de desistir em caso de falha) e **`agente_falhou` silencioso** (2 casos reais): não investigados a fundo nesta rodada; precisam de inspeção do workflow `GBH | FERRAMENTA | buscar_produto` e da cadeia final de erro do WF2.
- **Divergência preço-texto×PDF** ("Lead #15" citado no pedido do dono): não localizado nas transcrições; os dois caminhos (texto da Laura e PDF) já vêm da mesma chamada de `montar_orcamento`, então a causa provável é um reenvio de PDF depois de o orçamento ter sido refeito — não confirmado.
- **Trava anti-duplicidade de orçamento**: já existe desde 19/11 (`private.orcamento_substituir_anteriores`/`private.pedido_substituir`), criada exatamente para o caso citado pelo dono (Lead #11/Contato extra #03); não precisou de mudança nova.
- **Leitura de imagem/PDF do cliente antes da Laura**: já existe parcialmente (Gemini no WF1, cobertura de orçamento e aprovação de arte, 19/11); ampliar para os 85 casos de "[imagem recebida]" ficou fora do escopo desta rodada.
- **Fase 2 do Plano de Ação** (prévia de arte com marca d'água): não iniciada, como o próprio dono pediu ("entregando e validando a Fase 1 primeiro").

## 19/11/2026 (noite): recusa de preço vira escada de tiragens menores
- **Caso (Mariana Bastos, +55 31 8866-0329)**: pediu 1000 cartões de retrovisor, a Laura cotou R$ 654,90 e a cliente respondeu "Ok" e "Obrigada". A Laura só agradeceu e deixou a venda morrer. Erro que não pode acontecer: resposta fria ao preço é recusa.
- **Correção** (migration `20261219000006`, aplicada): regra `Q2_RECUSA` (`followup_regras.referencia = 'recusa_preco'`, 1 min, 7h às 22h). `private.fu_resposta_fria` reconhece "ok", "obrigada", "vou ver", "tá caro"; `private.fu_ultima_cotacao` acha o SKU cotado pelo texto da última cotação; `private.fu_texto_tiragens_menores` lista as quantidades menores do mesmo produto (mesmo papel, cor e tamanho, menor preço por quantidade, sempre de `calcular_preco` com `lucro_ok`); `private.fu_agendar_recusa` agenda; `followup_agendar` e `followup_montar` seguem como invólucros (a versão anterior de `followup_montar` ficou em `private.followup_montar_pre_recusa`). Só em conversa de IA, sem pedido, dentro da janela de 24 h e sem resposta não fria depois da cotação.
- **Mariana**: texto conferido (50, 100, 250 e 500 unidades, de R$ 117,90 a R$ 419,90) e item enfileirado em `followup_fila` (chave `Q2_RECUSA:<conversa>:CRT0005`) para sair agora.
- **Limite conhecido**: a cotação é achada pelo texto ("Para N unidades ... R$ X"). Orçamento em PDF sem esse texto não dispara; próxima melhoria é ler `orcamento_itens`. Teste: `supabase/tests/recusa_preco_tiragens.sql`.
- **Sugestões**: (a) usar também `orcamento_itens` como fonte da cotação; (b) registrar o motivo da recusa em `collected_data`; (c) regra no prompt do WF2 para a Laura oferecer a escada quando o cliente disser "tá caro" na própria conversa (hoje o banco cobre só a resposta fria).

## 19/11/2026 (correção): quantidade exata por soma de lotes e SG-0576 corrigido
- **Regra do dono**: quem pede N unidades recebe N. Se o fornecedor só tem lotes de 1, 5 e 10, 6 crachás = lote de 1 + lote de 5 (soma dos custos), nunca um lote maior. Migrations `20261219000004` e `20261219000005` (aplicadas): `private.orcamento_composicao_lotes` escolhe a combinação exata de menor custo (programação dinâmica); só se o número exato for impossível cobre com o menor excedente e anota a sobra. O orçamento e o PDF mostram uma linha só com as unidades do cliente (`private.orcamento_agrupar_exibicao`); a composição vai para `orcamento_itens.nota_interna` e `orders.notes`.
- **Bug achado de passagem**: a sincronização do orçamento com o pedido (`private.checkout_sincronizar_orcamento` e `pedido_sincronizar_orcamento`) copiava o "Frete Correios" como item e somava o frete duas vezes no total do orçamento (SG-0576 mostrava R$ 256,32 para um pedido de R$ 230,56). Corrigido, e a sincronização agora preserva a especificação pública e reagrupa itens iguais.
- **SG-0576 / pedido #422**: itens corrigidos para 6 crachás (CRCH4001 + CRCH40015) e 6 cordões, nota interna gravada, orçamento e link de pagamento atualizados para **R$ 309,46** (antes R$ 230,56, sem arte; o cliente tinha tirado a arte no checkout). O PDF que o cliente tem ainda está antigo: falta **Reenviar PDF** no CRM e avisar o cliente da diferença.
- Teste com rollback: 6 = 1 + 5, 7 = 2 x 1 + 5, 11 = 1 + 10; 6 crachás + 6 cordões = R$ 283,70 sem frete.

## 19/11/2026 (tarde): unidades do cliente, orçamento único e modelo padrão forte
- **Caso (+55 31 8501-1766)**: pediu 6 crachás com cordão e a Laura cotou "5 crachás + 6 cordões" (lote de 5 do fornecedor) e montou 4 orçamentos (573 a 576), 2 deles enviados com 2 pedidos (#421 e #422). Causa: o item levava o número de pacotes escolhido pelo modelo, e a Laura chamava `montar_orcamento` várias vezes na rodada, sem nada substituir o que já existia.
- **Correção no banco** (migration `20261219000003`, aplicada): `montar_orcamento` aceita `unidades` por item; `private.orcamento_melhor_lote` escolhe o lote mais barato que cobre as unidades (6 crachás viram 1 pacote de 10); o orçamento e o PDF mostram a quantidade do cliente (`orcamento_itens.unidades_cliente`) e o ajuste do fornecedor vai só para `orcamento_itens.nota_interna` e, ao virar pedido, para `orders.notes`. Orçamento novo substitui os anteriores do mesmo cliente com o mesmo tipo de produto (`private.orcamento_substituir_anteriores`): rascunho não enviado é apagado; enviado e seu pedido sem pagamento são cancelados (`private.pedido_substituir`, nunca mexe em pedido pago). Teste com rollback: 6 crachás + 6 cordões = R$ 220,80, nota interna "lote de 10, sobram 4", segundo orçamento apagou o primeiro.
- **n8n**: `despachar` repassa `unidades`; WF2 com regras V (unidades exatas) e U2 (um orçamento por pedido) e a ferramenta `montar_orcamento` pede `unidades`.
- **Limpeza do cliente**: orçamentos 573 e 575 apagados, 574 e o pedido #421 cancelados. Ficou o SG-0576 (pedido #422), que ainda tem 5 crachás; **não corrigi nem reenviei** porque o cliente já recebeu o link. Se quiser, gero o orçamento certo (6 crachás + 6 cordões, R$ 220,80 + arte e frete) e a Laura reenvia.
- **Modelo**: `agente_config.modelo_padrao = gemini-3.8-flash` (igual ao forte); `modelo_resumo` segue `gemini-3.1-flash-lite`. Custo por conversa sobe; acompanhe em `/laura`.
- **Sugestões**: (a) corrigir o SG-0576 e reenviar; (b) mostrar a nota interna do lote também na aba Itens do pedido; (c) alerta quando a Laura chama `montar_orcamento` mais de uma vez na rodada.

## 19/11/2026: conversa destravada, frase de espera única, cobertura de orçamento e lembrete de anúncio
- **Causa da travada (cliente +55 31 9577-7106)**: o Gemini respondeu "Payment required" (crédito esgotado) e o WF2 caiu no nó de erro. Cada retomada automática (a cada 3 min) mandava de novo "Oi! Recebi sua mensagem e já volto..." (3 vezes seguidas, no meio da conversa). Ao devolver a conversa para a IA, nada reprocessava a mensagem que ficou sem resposta, e o aviso `needs_human` e o setor arte/dono continuavam travando.
- **Correções**: (1) WF2: a frase de espera só sai se a Laura ainda não respondeu nada na conversa; (2) banco: ao voltar para a IA (`modo_atendimento = 'ia'`), o gatilho limpa `needs_human`, libera o setor arte/dono quando o motivo é "Devolvido para a IA" e reprocessa a última mensagem do cliente sem resposta (`private.agente_reprocessar_conversa`, log `reprocessar`); (3) prompt rodada 19/11, regra X: pedido de prévia antes do pagamento não trava nem chama o dono, explica a aprovação da arte antes de imprimir e segue fechando.
- **Cobertura de orçamento concorrente**: `public.cobrir_orcamento` (migration `20261219000001`), ferramenta no WF2 e no `despachar`, leitura de imagem e PDF com Gemini no WF1 antes do pagamento. Só BH e região, CNPJ válido e endereço obrigatórios. Detalhes, piso da cobertura e caso real em `docs/agente/cobertura-orcamento.md`. Teste: `supabase/tests/cobertura_orcamento.sql` (rollback).
- **Lembrete de anúncio** (regra `Q1_ANUNCIO`, 5 min): lead que só mandou a mensagem padrão do anúncio recebe opções e preços do produto, do mais em conta ao mais completo, montados pelo banco (`private.fu_texto_anuncio`, preço de `calcular_preco`). Crachá pergunta antes vertical ou horizontal (também no prompt, regra W).
- **Aplicado**: migrations `20261219000001` e `20261219000002` no Supabase; WF1, WF2 e `despachar` no n8n (cópias em `n8n/`). Gate verde.
- **Não rodei cenários e5/mvp/e12/e17** (regra do dono, gastam o crédito do Gemini). A leitura de anexo e a ferramenta nova só foram validadas no banco; o primeiro uso real deve ser acompanhado em `/laura` e `agent_logs`.
- **Atenção**: o lucro líquido da cobertura de R$ 285,99 é ~R$ 17 (a regra do dono é lucro bruto de R$ 65). O exemplo do pedido falava em R$ 285,90, que daria bruto R$ 64,91. O caso de RJ do pedido original é recusado pela regra "só BH e região".
- **Sugestões**: (a) recarregar o crédito do Gemini e criar um alerta de saldo baixo antes de zerar (foi a causa raiz); (b) botão "Destravar conversa" explícito no chat; (c) conferir o CNPJ do concorrente na Receita (BrasilAPI) e a cidade pelo CEP, para fechar de vez a brecha de orçamento falso; (d) painel de `cobertura_log` (quantos coberta, recusada e por quê); (e) mínimo de lucro líquido próprio para a cobertura.

## 19/11/2026: sugestões do checkout variadas por tipo de produto
- **Problema**: o checkout mostrava sempre o mesmo produto (Cartões de Visita PVC Cristal) porque só havia 6 regras de categoria e o resto caía num fallback fixo (pedidos de crachá, canvas e outros).
- **Correção** (migration `20261218000014`, aplicada): tabela `checkout_combinacoes` (origem por tipo de produto, destino, motivo, pontos) com 80 combinações, 5 a 6 sugestões diferentes por pedido, escolha por faixa de preço e variação entre pedidos. Conferido em 8 pedidos reais: crachá recebe cordão, porta-documentos, caneta, botton, agenda; canvas recebe ímã, postal, calendário; adesivo recebe sacola, tags, cartão fidelidade.
- **Sugestão**: tela em Configurações para o admin editar `checkout_combinacoes` sem SQL; medir quais sugestões o cliente mais adiciona (`checkout_eventos` tipo `item_adicionado`).

## 18/11/2026 (noite, 2): melhorias do checkout depois do teste real do Pix
- Pix testado pelo dono e funcionando. Ajustes pedidos: sem banner de cookies em `/pagar`; cartão em até 12x (até 2x sem juros, de 3x a 12x com juros do Mercado Pago); mais upsell (troca de quantidade, até 5 sugestões, até 5 extras); toda mudança atualiza pedido, orçamento, link e Pix pendente; lembrete PAG_CHK (15 min depois de abrir o checkout); atividade do checkout na aba Pagamento do pedido. Migration `20261218000013` (aplicada), funções `checkout-dados` e `checkout-mp-processar` redeployadas. Detalhes em `docs/checkout-proprio.md`.
- Apple Pay e Google Pay: não vão no Payment Brick; Apple Pay precisa de conta Apple Developer (ver doc). Não implementado.
- Verificação feita em transação com rollback sobre um pedido real: pedido, orçamento, itens e valor do link ficaram iguais depois de trocar quantidade e adicionar item; lembrete agendado e texto montado.

## 18/11/2026 (noite): checkout próprio em /pagar/<token> (Pix + cartão 2x sem juros no nosso domínio)
- **Motivo**: o Checkout Pro abria o app do Mercado Pago no celular (Paulo Moreira não conseguiu pagar) e o dono não recebia aviso de falhas que nunca chegavam ao Mercado Pago. Detalhes completos, fluxo, alertas e ordem de publicação em `docs/checkout-proprio.md`.
- **Banco** (migration `20261218000012`, aplicada): `orders.checkout_token`, `order_items.checkout_extra`, `checkout_eventos`, funções `checkout_carregar/status/salvar_dados/definir_arte/adicionar_produto/remover_item/registrar_evento` (só service role) e `private.checkout_sugestoes`. Teste de banco rodado em transação com rollback: `supabase/tests/checkout_proprio.sql`.
- **Edge Functions (no repositório, ainda NÃO deployadas)**: `checkout-dados`, `checkout-mp-processar` (novas) e `mp-criar-link` (devolve o link `/pagar/<token>`; `CHECKOUT_PROPRIO=false` volta ao Checkout Pro). Bundles em `docs/agente/funcoes/`.
- **Loja** (`ecommerce/`): rota `/pagar/[token]`, sem cabeçalho nem rodapé da loja, banners desktop e celular, logo animada no carregamento, upsell de arte, cross-sell, Pix com QR e copia e cola, Payment Brick só de crédito (máx. 2x), confirmação em tempo real. Prints conferidos em 390 px e 1360 px com servidor simulado.
- **Alertas ao dono**: recusa repetida, erro técnico, Pix sem código e parcelamento com juros viram `pagamento_problema` (push e WhatsApp).
- **Falta o dono**: segredo `MP_PUBLIC_KEY_PRODUCAO`; deploy das 3 funções na ordem do doc; ativar 2x sem juros na conta do Mercado Pago; PR e merge (não abri PR).
- **Não testado com dinheiro real**: Pix e cartão ao vivo dependem da chave pública e do deploy.
- **Sugestões**: lembrete automático quando o checkout foi aberto e ficou 15 min sem pagar; mostrar `checkout_eventos` na aba Pagamento do pedido; Pix com desconto pequeno só por decisão do dono; Apple Pay e Google Pay no Brick.

## 18/11/2026 (fechamento): lembrete de pagamento sem conversa
- **Causa**: pedido manual cujo contato não tem conversa de WhatsApp gerava lembretes PAG que falhavam com "conversation_id inválido" (5 casos, 2 pedidos). Migration `20261218000011` (aplicada): `followup_agendar` só agenda PAG quando o contato tem conversa, `followup_montar` pula com motivo `sem_conversa` se chegar algum sem conversa, e as linhas que já tinham falhado viraram `pulado` (`sem_conversa`). Conferido: nenhum erro restante e o agendamento rodou sem criar linha nova para esses pedidos.

## 18/11/2026 (fim do dia): kit sem desconto e lembrete rápido depois do link
- **Decisão do dono**: o foco é lucrar; o kit crachá + cordão é só praticidade de consulta e orçamento. Migration `20261218000010` (aplicada): `kits_agregados.abate_preco` (padrão `false`), então o kit só marca o orçamento (`kit_agregado_id`, `kit_abatimento = 0`) e o preço fica o da planilha. Nenhum orçamento real tinha recebido abatimento. Regra AF do WF2 corrigida (sem falar em desconto de kit). Para religar o abatimento (não recomendado), `update kits_agregados set abate_preco = true`.
- **Lembrete depois do link sem pagamento**: já existiam PAG_1H, PAG_6H e PAG_24H (cancelam quando o cliente responde ou paga). Agora: nova regra `PAG_20M` (20 min, cita Pix de qualquer banco e cartão em até 2x sem juros), PAG_1H desligada (ficava colada), PAG_6H e PAG_24H mantidas, e o F1 (10 min depois do PDF) não cutuca quem já recebeu o link (`coberto_pelo_link`). Horário de envio 8h às 20h, janela fechada usa o template `pagamento_pendente`.
- **Reenvio no CRM**: o botão Reenviar do PDF reenvia também o link (comportamento mantido).
- **Observado, não corrigido**: 5 lembretes PAG com erro `conversation_id inválido` (pedidos manuais sem conversa).

## 18/11/2026 (noite): sem APROVADO, link automático depois do PDF e kit crachá + cordão
- **Decisão do dono**: o link de pagamento não depende mais de APROVADO e sai numa mensagem logo depois do PDF, em todo orçamento (cliente quente). Cartão em até 2x sem juros e Pix de qualquer banco vão na mesma mensagem.
- **Banco** (migration `20261218000009`, aplicada): `preparar_link_pagamento` perdeu a trava `aprovacao_do_cliente_pendente` (a trava de lucro e a conferência do total do pedido continuam). Kit agregado: tabelas `kits_agregados` e `kits_agregados_componentes` (componentes por padrão de descrição, o cordão recebe o ajuste), colunas `orcamentos.kit_agregado_id` e `kit_abatimento`, `private.kit_agregado_aplicar` e `montar_orcamento` como wrapper de `montar_orcamento_pre_kit`. O kit parte dos SKUs e custos reais: o lucro bruto mínimo vale uma vez por pedido, então a linha do cordão abate o excedente em degraus (65, 50, 40, 30, 20, 10), sempre com o novo total da linha terminando em ,90, nunca abaixo de 1,5x o custo nem do piso duro, e só fica se `validar_margem` aprovar. Teste: `supabase/tests/kit_agregado.sql`. Exemplo real (1 crachá lote 10 + cordão lote 12): R$ 236,80 para R$ 206,80, lucro líquido R$ 67,90.
- **Edge Function** `orcamento-pdf` (versão 31, deployada): depois de enviar o PDF, cria o link (`preparar_link_pagamento` + `mp-criar-link`, `orcamento_registrar_link`) e manda o texto com o link 1,5 s depois. Devolve `link_enviado` e `link_motivo`; falha no link nunca derruba o PDF. O PDF não pede mais APROVADO.
- **n8n**: ferramenta `gerar_pdf_orcamento` devolve `link_enviado` e `proximo_passo`; WF2 sem APROVADO (prompt fixo e regras), cartão 2x sempre citado, NF só depois do pagamento, foto só depois do preço. Regras AC (link depois do PDF), AF (kit) atualizadas.
- **CRM**: Catálogo > Kits mostra os kits agregados com chave ligar/desligar (admin).
- **Por que o cliente declinava e o que foi aplicado**: PDF sem link (resolvido), perguntas e fotos antes do preço (regra AE e foto depois do preço), cordão em pacote deixando o conjunto caro (kit), repetição sobre arte (regra AD), orçamento com valor errado no PDF (sincronização da arte).
- **Para conferir**: próximas conversas em `/laura`: PDF, depois o link; `orcamentos.kit_abatimento` preenchido em crachá + cordão; `agent_logs` sem pedir APROVADO.
- **Sugestões**: lembrete automático 2 h depois do link sem pagamento (follow-up já existe, conferir o texto); degraus de kit para outros pares naturais (cartão + adesivo) pela mesma tabela; mostrar `kit_abatimento` no card do orçamento.

## 18/11/2026 (tarde): mensagem citada, PDF da arte, tela branca e rodada de vendas
- **Mensagem citada (Responder do WhatsApp)**: o webhook já gravava `reply_to_wa_id` e o CRM já mostra a citação; faltava a Laura enxergar. Migration `20261218000007` (aplicada): `agente_contexto` ganhou `responde_a` em cada item do `historico` (wrapper sobre `agente_contexto_pre_reply`). O nó "Adaptar contexto" do WF2 escreve `[respondendo a: "..."]` antes da fala do cliente e a regra AH manda responder sobre o assunto citado.
- **PDF com valor antigo**: a arte do orçamento é `arte_modo/arte_valor`, enquanto no pedido é a linha "Criação de arte". `pedido_sincronizar_orcamento` só copiava itens, então tirar a arte deixava o PDF cobrando R$ 39,90. Migration `20261218000008` (aplicada): a sincronização exclui a linha de arte dos itens e acerta `arte_valor/arte_modo` (sem a linha, deixa de cobrar). Orçamento do Vander corrigido (276,70 para 236,80). O PDF novo sai ao reenviar (o hash muda).
- **Piscando e tela branca**: `ErrorBoundary` (erro de tela vira aviso com botão; arquivo de versão antiga recarrega sozinho uma vez), `vite:preloadError`, `AuthProvider` não derruba mais para o login quando a busca do perfil falha por rede (3 tentativas) nem troca a sessão à toa, e as listas de conversas e mensagens mantêm o dado anterior enquanto recarregam.
- **Por que os clientes declinam** (conversas de 15 a 18/11): (1) orçamento em PDF sem link de pagamento, cliente esperando APROVADO (Edson, Patrícia, Vander, Diogo); (2) muitas perguntas e fotos antes do preço; (3) cordão em pacote (R$ 133,90 para 7 crachás, R$ 76,90 para 1) deixa o conjunto caro sem explicação; (4) explicação de arte repetida e fotos de mostruário quando o cliente queria ver com a arte dele.
- **WF2 (publicado e exportado)**: regras AC (orçamento e link juntos, 2x sem juros ao enviar o link, sem exigir APROVADO), AD (amostra é com a arte dele, feita após o pagamento), AE (preço de cara), AF (crachá com cordão na mesma quantidade, alternativas só se reclamar do preço), AG (retirada grátis sempre com frete grátis dos 7 bairros), AH (mensagem citada). Nenhum cenário do Gemini rodado.
- **Pendente / sugestões**: conferir no atendimento real (`/laura`) se o link sai junto do PDF; avaliar kit "crachá + cordão" no catálogo com preço por quantidade pequena (hoje o cordão só vem em pacote); alerta no CRM quando o orçamento enviado ficar mais de 10 min sem link.

## 18/11/2026: botão "Responder com IA" no chat
- Em conversa em modo humano, o botão (faíscas, ao lado de NF e Arte) faz a IA escrever uma sugestão de resposta no campo do chat; o atendente revisa e envia. A IA nunca envia. Voz sempre da Laura (nunca João Victor, que só atende depois do pagamento). No modo rascunho PDF, link, foto, condição especial, lembrete, arte e chamar o dono ficam bloqueados. Detalhes em `docs/agente/ia-responder-botao.md`; migration `20261218000006`, função `ia-rascunho`, gatilho de rascunho no WF1 e regra no WF2. Uma execução real de verificação (46 s, texto correto) na conversa do Thiago.

## 18/11/2026: estudos do dono adaptados ao conhecimento da Laura
- 33 trechos novos em `public.conhecimento` (migration `20261218000004`, fonte `docs/agente/conhecimento_rodada18.json`, gerador `scripts/gerar-conhecimento-rodada18.ts` com lint), todos `revisar = true`; 5 regras novas no WF2 (X a AB, publicado); cinco trechos antigos corrigidos de corte 12h para 10h30. Urgência só honesta, escassez não usada. Veredito, ajustes e itens `[CONFIRMAR]` em `docs/agente/estudos-do-dono-18-11.md`. Nenhum cenário do Gemini rodado.

## 18/11/2026: avaliação do atendimento de 17/11 e diário do tráfego pago
- Criado `docs/agente/diario-trafego-pago.md`: diário dia a dia desde o início do tráfego real (16/11), com quadro de números, gargalos (códigos `G1711-n`), melhorias (`M1711-n`), backlog com status e consultas de apoio. Rotina: o dono verifica por dia e registra lá.
- Análise de 17/11 (17 conversas, 375 mensagens, 5 orçamentos, 1 pago de R$ 78,90, lucro real R$ 60,39 contra R$ 42,59 de anúncio). Principais gargalos: lentidão (P50 53 s, P90 347 s), lembrete Q1 de 10 min virou insistência (Wender recebeu 4), lembrete depois de recusa (Artur), fechamento travado no "APROVADO", dados fiscais em modo humano não salvos (NFC-e nº 71 rejeitada), orçamentos abertos sem lembrete depois que o humano assume (Edson e Patrícia) e opções de produto erradas (Hudson). 
- **Aplicado na sequência (mesmo dia)**: migrations `20261218000001` e `20261218000002` (cadência dos lembretes, orçamento aberto em modo humano, extração de dados fiscais, aprovação por pagamento, alerta de condição fora do padrão, travas de saída, opções sem duplicata, limite de ferramentas 6/16), `contato-cep-completar` v2 (sem JWT, aceita `x-cron-secret`), `produto-opcoes` v14 e WF2 com as regras O a W (publicado). `npm run gate` verde. Detalhes e como conferir em `docs/agente/diario-trafego-pago.md`.
- **Parte 2 (18/11)**: `montar_orcamento` agora alinha o item ao valor combinado no chat (migration `20261218000003`, wrapper sobre `private.montar_orcamento_base`, nunca bloqueia), motivo de perda automático na recusa e WF1 com no máximo 2 balões.

## 17/11/2026: aviso de versão nova do CRM
- Aba aberta antes do deploy continuava na versão antiga (o dono achou que o merge não tinha entrado; o servidor já tinha). Agora `NovaVersao` confere a cada 5 min e ao voltar para a aba se o arquivo principal publicado mudou e mostra "Tem uma versão nova do CRM" com botão "Atualizar agora". `sw.js`, `manifest.webmanifest` e `offline.html` passaram a `no-cache` no `.htaccess`.

## 17/11/2026: NF "não será emitida"
- Terceiro estado da nota em Bling e NF: o dono marca **"Nota não será emitida"** (com motivo no campo de anotação) e o pedido sai de pendente. Filtro e card próprios ("Notas não emitidas", com os motivos) e o card de pendentes ficou só com o que aguarda nota. A conferência com o Bling ignora pedido dispensado; se a nota for emitida (manual ou pelo Bling), o estado desfaz. Migration `20261217000029` (aplicada): `orders.nf_dispensada`, `nf_dispensar`. Para o imposto do Financeiro, nota não emitida continua fora do cálculo.

## 17/11/2026: Financeiro como conta (saldo que bate com o Mercado Pago)
- **Regras do dono**: todo pedido pago entra sozinho no saldo pelo valor BRUTO e a taxa do Mercado Pago sai sozinha (o MP deposita o líquido); o custo do pedido só sai do saldo quando o dono marca "Paguei" (ou "Já estava pago", sem mexer no saldo); o **imposto só conta para pedidos com nota emitida** (`orders.nf_emitida`), pedido sem nota fica fora e a tela mostra quanto; pagamentos de imposto registrados abatem o "imposto a pagar".
- **Abertura**: saldo do Mercado Pago em 17/11/2026 = R$ 1.516,13 (lançamento `abertura`, `app_settings.financeiro.inicio_automatico`). Pedidos pagos antes disso NÃO entram de novo; seus custos aparecem como pendentes para o dono baixar.
- **Banco** (migration `20261217000028`, aplicada): `financeiro_lancamentos.origem/order_id`, `financeiro_custos`, `financeiro_impostos_pagos`, `private.financeiro_sync_pedido` (gatilho em `orders`, nunca bloqueia o pagamento) e agendamento `financeiro-sincronizar` (10 min), `financeiro_painel`, `financeiro_custo_baixar/reabrir`, `financeiro_imposto_pagar/excluir`, `financeiro_resumo` (imposto só de nota emitida; lançamentos manuais separados dos automáticos). Simulação com rollback conferiu: 1.516,13 + venda 78,90 - taxa 0,78 - custo 14,99 = 1.579,26.
- **Tela** (`ContaFinanceira`): saldo e conferência com o saldo informado do Mercado Pago, custos a pagar, imposto (devido, pago, a pagar, aviso de pedidos sem nota, por mês) e extrato com origem; lançamentos automáticos não são editáveis.
- **Bling e NF**: cards de notas emitidas e não emitidas, com motivo automático (não enviado ao Bling, rejeitada, ainda não gerada) e campo de anotação do dono (`nf_motivo`, `nf_motivo_salvar`).
- Números de hoje: 6 notas emitidas (imposto devido R$ 79,63); 3 pedidos pagos sem nota (R$ 2.760,80 bruto, imposto estimado R$ 165,64 fora do cálculo); 8 custos pendentes (R$ 2.329,24).
- Painel e Campanhas ainda usam o lucro líquido do pedido com imposto de todos os pedidos (`order_financials`); só o Financeiro segue a regra de nota emitida.

## 17/11/2026: Meta sozinha e NF automática
- **Meta**: agendamento `meta-ads-sync-15min` (a cada 15 min, últimos 3 dias) além do diário de 7 dias; a tela de Campanhas relê sozinha a cada minuto e o botão virou "Atualizar agora".
- **NF automática**: `bling-integracao` (ação `conferir_nf`, agendamento `bling-nf-conferir` a cada 10 min e botão "Conferir no Bling agora") lê a nota do pedido no Bling e grava número, tipo, situação e chave (`nf_registrar_bling`, migration `20261217000027`, aplicada; função na versão 14). As notas do dono são **NFC-e** (pedido.notaFiscal.id é o id da NFC-e; `/nfce/{id}`, com `/nfe/{id}` como reserva). O Bling é a fonte da verdade: nota rejeitada, denegada ou cancelada volta o pedido para pendente. O marcador "faltam dados da NF" some quando a nota já foi emitida.
- Conferido com dados reais: 219 (nº 74), 220 (72), 224 (73), 294 (77), 295 (76), 296 (75) autorizadas; **407 (Marcos) nº 71 Rejeitada**; 293 (TEIA) sem nota no Bling; 23 sem pedido no Bling.

## 17/11/2026: template de arte enviado e extrato do Mercado Pago pausado
- Template `aprovacao_arte` (utilidade, conta Sua Gráfica BH) submetido à Meta (id 1546120117357833, em análise). Depois de aprovado, sincronizar em Configurações > WhatsApp e templates; então o botão Arte pode ser usado também por template fora da janela de 24 h.
- Agendamento `mp-extrato-sync` (a cada 5 min) pausado (migration `20261217000026`, aplicada). `mp-saldo` nunca teve agendamento. Funções e tabelas continuam como histórico; para religar: `cron.alter_job(job_id, active := true)`.

## 17/11/2026: primeira passada de visual e responsividade
Conferida com prints reais em celular (390), tablet (820) e desktop (1440):
- Menu lateral começa recolhido (só ícones) em telas menores que 1280 px quando não há preferência salva; o chat no tablet ganhou espaço.
- Campo de mensagem do chat quebra linha em painel estreito (antes ficava com ~96 px) e o cabeçalho do chat não corta mais os botões.
- Cartões de Campanhas no celular não cortam mais rótulo nem valor (antes "R$ 1.410,…").
- Configurações no celular usa um seletor de seção (antes as 16 abas ficavam escondidas na rolagem lateral).
- Próximos candidatos: Kanban no celular, tabelas de Pedidos e Catálogo, Painel, padronizar cabeçalhos de página.

## 17/11/2026: aprovação da arte
- Botão **Arte** no chat (ao lado do NF): coloca no campo a mensagem de aprovação ("responda APROVADO; depois disso entra em produção e não dá mais para corrigir"); o atendente anexa a arte e envia (o texto vai de legenda). Resposta rápida `/arte` com o mesmo texto (migration `20261217000025`, aplicada).
- Template da Meta `aprovacao_arte` (utilidade, 1 variável) registrado em `AGENT_TEMPLATES` (agora 12). **Ainda não submetido à Meta**: falta o dono escolher a conta do WhatsApp Business (há Sua Gráfica BH e Bauerlab). Fora da janela de 24 h o botão fica desativado; depois de aprovado, usar Enviar template.

## 17/11/2026: menu agrupado
- **Templates** viraram aba de Campanhas (`/campanhas?aba=templates`) e **Fila da arte** virou aba de Pedidos (`/pedidos?aba=arte`). `/templates` e `/arte` redirecionam. O menu lateral caiu de 15 para 12 itens (Painel, Laura, Kanban, Pedidos, Conversas, Contatos, Catálogo, Campanhas, Financeiro, Bling e NF, Tarefas, Configurações).

## 17/11/2026: Financeiro com saldo manual e Pagamentos dentro dele
- **Recebido líquido** agora vem só dos pedidos pagos (faturamento menos a taxa do Mercado Pago, `financeiro_resumo`). O extrato automático do Mercado Pago (que contava saídas como movimentação) e o saldo automático saíram da tela; as funções `mp-extrato` e `mp-saldo` e as tabelas `mp_movimentos` e `mp_saldo_historico` continuam no servidor, sem uso na interface.
- **Saldo manual**: só o que o dono lança em Receita e Despesa. O dono informa o saldo de hoje do Mercado Pago e a tela mostra a diferença para o saldo dos lançamentos (migration `20261217000024`, aplicada: `financeiro_saldo_manual` e `financeiro_saldo_informar`, só admin).
- **Pagamentos** virou aba de Financeiro (`/financeiro?aba=pagamentos`; `/pagamentos` redireciona). Financeiro deixou de ser só do admin: atendente vê só a aba Pagamentos.

## 17/11/2026: área Bling e NF + forma de pagamento no pedido do Bling
- **Forma de pagamento**: o pedido ia ao Bling com `formaPagamento.id = 0` (conferido nos pedidos reais). Agora `bling-integracao` consulta `/formas-pagamentos`, escolhe a forma pelo nome (Pix, cartão de crédito/débito, dinheiro, transferência) e, se não achar, pelo tipo da NF-e, e manda na parcela (a NF-e herda). Se não achar nenhuma, vai sem forma e o aviso do pedido diz para escolher na NF. Deploy da função feito (versão 13). Vale só para pedidos novos; os já enviados continuam como estão.
- **Indicador de presença**: não é enviado pelo CRM. O CRM cria o pedido de venda; a nota é gerada no Bling, onde o indicador (1, operação presencial) fica na configuração da nota. Não consegui confirmar pela API se o pedido aceita esse campo.
- **Bling e NF** (`/bling`, item novo no menu): checklist de NF por pedido pago (marcar emitida + identificador da nota), filtros Pendentes/Emitidas/Todas, faltas de dados e erro de envio. A conexão do Bling saiu de Configurações e virou a aba Integração dessa página. Migration `20261217000023` (aplicada): `orders.nf_emitida`, `nf_identificador`, `nf_emitida_em` e `nf_marcar`.
- A API do Bling não mostrou NF emitida em novembro, então o checklist começou todo pendente para o dono marcar.
- Pendente (próximas etapas do pedido do dono): Financeiro (recebido líquido só de pedidos pagos, saldo do Mercado Pago manual, Pagamentos dentro de Financeiro), Templates dentro de Campanhas, Fila de arte dentro de Pedidos, template de aprovação de arte, melhorias de UI e responsividade.

## 17/11/2026: botão NF no chat
- Botão "NF" ao lado do microfone em `ChatPanel`: coloca no campo a mensagem curta (`src/lib/nota-fiscal.ts`) pedindo nome/razão social, CPF/CNPJ, CEP, rua, número, bairro, cidade/UF e e-mail. O atendente confere e envia (só com a janela de 24 h aberta; fora dela, usar template). O código IBGE não é pedido ao cliente: deve sair do CEP.
- **Atualização**: a mensagem do botão NF pede só 5 itens (nome, CPF/CNPJ, CEP, número, e-mail). Rua, bairro, cidade, UF e IBGE saem do CEP pela função `contato-cep-completar` (deployada; só preenche campos vazios do contato).
- **Marcador "Faltam dados da NF"**: migration `20261217000022` (aplicada) cria `contato_nf_faltantes` e a coluna calculada `nf_faltantes` no pedido pago (não cancelado, excluído nem de teste). Aparece no card do Kanban e no topo do pedido, com o botão "Completar pelo CEP". Os 9 pedidos pagos de hoje estão todos com dados faltando.
- Pendente: chamar `contato-cep-completar` automaticamente quando a Laura salvar o CEP; template de NF para janela fechada.

## 17/11/2026: atribuição de anúncio nos pedidos (Campanhas)
- **Bug**: pedido pago do Marcos (#407, anúncio "Crachá com Cordão") não aparecia em Campanhas. `ad_performance` cruza por `orders.origin_ad_id`, mas só o pedido manual do front gravava esse campo; pedidos da Laura e do site ficavam sem origem (#407, #408 e #410 afetados).
- **Correção** (migration `20261217000021`, aplicada): gatilho `orders_herdar_origem_anuncio` (BEFORE INSERT) copia `source_id`, título e URL do `first_referral` do contato em qualquer caminho de criação; backfill dos pedidos existentes; `ad_performance` passou a ignorar pedido/contato de teste e pedido excluído e a contar o dia em horário de Brasília.
- **Conferido**: 30 dias = 7 conversas (bate com o painel), 1 venda paga de R$ 78,90 (lucro líquido R$ 58,39) no anúncio "Crachá com Cordão".
- Regra de atribuição: último contato por anúncio NÃO vale; vale o primeiro anúncio do contato (`first_referral`), igual ao funil de conversas.

## Fase 3, rodada 4 (15/11/2026): CRM responsivo, Financeiro e Bling
- **Bug raiz das abas**: `TabsContent` com `flex` vencia o `hidden` das abas inativas, então todos os painéis apareciam empilhados e o ativo ficava espremido (Catálogo e Kits "em branco com rolagem"). Corrigido em `ui/tabs.tsx` (`data-[state=inactive]:hidden`), vale para o CRM inteiro. Catálogo: cards no celular (tabela só de `md` para cima), abas quebram linha, filtros em largura total. Números de WhatsApp não são mais cortados (lista de conversas e cabeçalho do chat).
- **Financeiro** (`/financeiro`, só admin): resumo do período (faturamento, custo, impostos, taxas e lucro líquido dos pedidos pagos), receitas e despesas lançadas à mão (criar, editar, excluir), evolução de 6 meses, saldo do Mercado Pago (`mp-saldo`, depende de permissão do token) e um bloco "Resultado do mês" no Painel. Migration `20261204000001` (aplicada).
- **Bling**: ids salvos em `app_settings.bling` (loja do site 206358250; marketplaces `lojas_marketplace`: Mercado Livre 206359728 e Shopee 206359841, para a futura exportação). O envio automático continua DESLIGADO até o dono ligar em Configurações > Bling (ao ligar, os pedidos pagos já existentes vão de uma vez).
- Ainda pendente: migrations `20261202000002` (apagar conversa e contato) e `20261203000003` (pós-entrega), blog, fotos pela VPS, loja, bateria completa.

## Fase 3, rodada 5 (15/11/2026): blog e frete do site
- **Blog**: nenhum post saía porque o modelo configurado (`gemini-2.5-flash`) e o reserva davam 404 com a chave do Supabase (290 pautas coletadas, 0 posts). `app_settings.blog.modelo` passou para `gemini-flash-latest` (o mesmo alias do agente), o NewsAPI foi ligado (`newsapi: true`; só roda se o segredo `NEWSAPI_KEY` existir) e as pautas com erro voltaram para `nova`. Resultado: 2 posts publicados na primeira rodada, com crédito à fonte e sem preço. A função usa o alias como reserva (`blog-pautas`).
- **SuperFrete no checkout do site**: conferido com chamada real à `loja-frete`: CEP de São Paulo devolveu PAC R$ 33,09 (5 dias) e SEDEX R$ 50,61 (1 dia); a Praça Sete devolveu frete grátis. O `loja-checkout` recalcula o serviço escolhido no servidor e o frete entra no pedido com a trava de lucro. NÃO fiz uma compra completa de teste (criaria pedido e link de pagamento reais).
- **Site**: os selos já existem e só afirmam o que é verdade (HTTPS, Mercado Pago, CNPJ, avaliações públicas). Avaliações do Google NÃO foram importadas (exige a API do Google); a loja só linka para o perfil.
- Pendente: migrations `20261202000002` e `20261203000003`, fotos pela VPS, preço em tempo real para tamanho fora da planilha, banners, bateria completa.


## Fase 3, rodada 3 (15/11/2026): cupom, relâmpago e pós-entrega
- **Cupom VOLTEI5 (5%)**: a Laura pergunta se o cliente já avaliou no Google; se sim, usa `oferecer_condicao_especial` com o gatilho `VOLTEI5`; se não, manda o link de avaliação (https://g.page/r/CZ6eNNGjdgO4EAE/review) e pede para voltar. Vale uma vez por cliente (`cupom_ja_usado`), não empilha com outra condição e só sai se o percentual couber acima do piso (tudo ou nada). Regra 29 do prompt.
- **Desconto relâmpago (3%, link válido por 1 hora)**: gatilho `RELAMPAGO`, usado pelo follow-up F3 (dia 2, depois dos lembretes F1 e F2 sem resposta). Nada de percentual escolhido pelo modelo: `private.condicao_gatilho_fixo` calcula, confere o piso e a ferramenta gera orçamento novo, link e PDF. Testado no banco (desfeito no fim): R$ 7,97 sobre R$ 265,90, validade de 1 h; orçamentos sem gordura ou que já têm condição são recusados.
- **Pós-entrega**: agradecimento, pedido de avaliação no Google e aviso de novidades com saída por PARAR; quem recebe o pedido passa a `opted_in` (origem `pos_entrega`), exceto quem pediu PARAR. Template `pos_venda_avaliacao` enviado à Meta (MARKETING, em revisão). **A migration `20261203000003` ainda NÃO foi aplicada** (o Supabase pede confirmação para o `update` em massa): rodar no SQL Editor. Enquanto isso o pós-entrega segue com o texto antigo.
- Aplicadas direto no banco e versionadas: `20261203000001` (cupom e relâmpago) e `20261203000002` (alerta da VPS com 3 falhas e persona sem "assistente virtual").


## Fase 3, rodada 2 (15/11/2026, PR #95 mesclado)
- **Bling automático**: função `bling-integracao` (OAuth, fila a cada 2 min, contato, produto com NCM, pedido de venda na loja SUAGRÁFICABH), RPCs `bling_pendentes/resultado/reenviar/painel` e aba Configurações > Bling. Pedido sem CPF/endereço vai com aviso; só bloqueia sem nome, NCM ou pagamento. Falha repetida (3 tentativas) vira alerta ao dono. O envio fica desligado até o dono ligar na aba.
- **Laura é atendente**: nada de "assistente virtual", "IA" ou "robô" (prompt regra 13, persona `apresentacao`, 12 trechos da base de conhecimento, seed, testes). Se perguntarem se é pessoa ou robô, ela diz "sou a Laura, do atendimento" e oferece o dono, sem afirmar ser humana.
- **Template da Meta** `pedido_pago_confirmacao` editado pelo MCP (nova mensagem, em revisão); a Edge Function já usa o novo texto dentro da janela de 24 h.
- **Alerta da VPS**: só dispara depois de 3 verificações seguidas falhando (`origem_sessao.falhas_seguidas`).
- **Apagar conversa e contato** (admin, auditoria em `exclusoes_auditoria`, recusa pedido pago): telas prontas; as funções `excluir_conversa`/`excluir_contato` PRECISAM ser aplicadas no banco (a confirmação do Supabase trava os `delete`; SQL em `supabase/migrations/20261202000002_excluir_conversa_e_contato.sql`; a tabela já existe).
- **Pendente**: cupom VOLTEI5, desconto relâmpago de 3% por 1 h e pós-entrega com avaliação no Google (precisam de ferramenta nova na Laura + banco); CRM responsivo, Financeiro, blog; fotos pela VPS; loja; bateria completa de cenários.


## Fase 3: máquina de vendas, rodada 1 (15/11/2026, branch `feat/maquina-de-vendas`)
### Causa raiz do alerta "Falha da ferramenta buscar_produto" (cliente de teste, 13/11)
- A RPC `buscar_produto` estourava o `statement_timeout` (erro 57014): `private.categoria_bate` normalizava a categoria (`norm_busca`, ~7 ms por chamada) por token e por linha, milhares de vezes por busca (7 s a quente, mais de 18 s sob carga). O n8n repetia duas vezes o mesmo timeout e devolvia só "falhou".
- Correção: cache `private.categoria_norm` e `categoria_bate` com uma normalização por chamada; `buscar_produto` calcula as categorias que casam uma vez. Medido depois: 0,07 a 0,7 s (antes 7 a 18 s), com as mesmas 4 a 5 opções.
- Recuperação autônoma: o workflow `buscar_produto` agora tenta uma busca de reserva (3 palavras-chave, sem filtros) antes de desistir; se tudo falhar devolve `erro_detalhe`. O `despachar` grava `falhou: <motivo real>` em `agent_logs` e orienta o agente a manter o contexto, não repetir perguntas e oferecer o item mais próximo antes de chamar o dono.
### Qualidade da conversa
- `buscar_produto` passou a entregar `em_palavras` (tradução oficial da impressão, ex.: 4x1 = "colorido na frente e preto no verso") e `numero` de cada opção; o agente descreve cada opção só com isso (causa dos erros "4x1 descrito como frente e verso" e "1x1" no resumo da opção 2).
- Link do site removido da resposta da ferramenta e do prompt (a loja ainda não está aberta). Novas regras 25 a 28 no WF2: sem links do site, confirmar o nome real do cliente (nome do WhatsApp costuma ser falso) e salvar, não repetir pergunta já respondida para o produto em pauta, descrever opções só pelos campos da ferramenta. Travadas em `scripts/test-contratos.ts`.
- Mensagem pós-pagamento nova (sem o parágrafo da arte): "Oi, <nome>! Aqui é o João Victor da Sua Gráfica BH! Seu pagamento foi confirmado! Seu pedido SG-xxxx já entrou na fila. Previsão de ficar pronto: dd/mm. Quando estiver prontinho para retirada, te aviso por aqui com o endereço certinho da Praça Sete." (`cliente-pago-avisar` v12; fora da janela de 24 h segue o template aprovado `pedido_pago_confirmacao`, que NÃO foi alterado).
### CRM
- Feriados: escopo `minas_gerais` (Data Magna, 17/07), calendário 2028 e etiqueta do escopo na lista; nacionais e de BH já existiam.
- Configurações > Agente de IA mostra o estado real da Laura (ligada 24 h ou pausada) no lugar de "ainda não está conectado".
### Testado na prática
- `buscar_produto` com 5 buscas reais depois do ajuste; clone do WF2 com o prompt novo: cenários `e12-07` (nota fiscal salva) e `e2e-c6a` (funil de cartão) passaram; `npm run gate` verde. WF2 de produção publicado depois do clone.
### NÃO feito nesta rodada (continua pendente, em ordem sugerida)
1. **Bling**: envio automático do pedido pago (loja SUAGRÁFICABH, NCM obrigatório, dados fiscais); a ativação depende do estudo em `docs/bling-fiscal.md` e de credenciais do dono.
2. **Cupom VOLTEI5, desconto relâmpago de 3% por 1 hora e mensagem de pós-entrega com avaliação no Google e consentimento**: precisam de tabela e função no banco (o modelo nunca calcula desconto) e do ajuste do WF7.
3. **Foto de todas as opções direto do site do fornecedor logado**, preço em tempo real para tamanho fora da planilha e falso alerta de "sessão caiu" da VPS.
4. **CRM**: responsividade (números de WhatsApp cortados, abas Catálogo e Kits), aba Financeiro, blog (NewsAPI) funcionando.
5. **Loja (`ecommerce/`)**: reorganização por departamentos, um SKU por produto com foto própria, selos reais, avaliações do Google, banners, SuperFrete no checkout.
6. **PDF do orçamento**: revisão de redundâncias.
7. **Bateria completa** `e5-*`, `mvp-*`, `e8-*`, `e12-*` com leitura das respostas e conversas longas de ponta a ponta (só rodei 2 cenários de verificação).
- Observações: o prompt ainda manda a Laura se declarar "assistente virtual" quando perguntarem (regra 13, mantida por ser a conduta honesta, embora a decisão 7B diga o contrário; precisa de decisão do dono). O template `pedido_pago_confirmacao` aprovado ainda tem o texto antigo e exige nova submissão à Meta para mudar.


## Fase 2: Laura pronta para tráfego pago (12/11/2026, branch `feat/laura-trafego-pago`)
### Padrões de falha encontrados nas 27 conversas e 474 execuções do histórico (somente leitura)
- **Contato nunca salvo**: `agente_salvar_contato` falhava SEMPRE (gravava em `contacts.quer_nota_fiscal`, coluna que nunca existiu) e, mesmo corrigida, a restrição `contacts_segment_check` aceitava só 4 segmentos enquanto a função gera 10. Além disso o sub-workflow `salvar_contato` do n8n só repassava 7 dos 15 campos (e-mail, CNPJ, nota fiscal, endereço, notas e consentimento nunca chegavam). Corrigido nas três camadas.
- **Consentimento**: `none` (padrão) contava como "já cadastrado": a Laura nunca perguntava sobre promoções.
- **Cotação sem qualificação**: os "Lembretes" anexados a toda mensagem (e) e (f) e o bloco base mandavam cotar e enviar PDF de imediato, contradizendo a regra 19. Reescritos; regras 8, 9, 14, 19, 22 e nova 24 alinhadas (endereço do balcão agora público, como decidido em 09/11).
- **Silêncio**: 277 de 304 execuções "ignoradas" foram `modo_humano` (cliente sem resposta depois que uma pessoa assumiu, ex.: conversa ASARI em 10/11, resolvido no reset de teste). `fora_do_piloto` (10), `teto_conversa` (2) e `aguardando_dono` (8) são esperados; o piloto está desligado. Contatos reais sem resposta em modo IA: 4 antigos (1 a 10/11), anteriores às correções de 11/11.
- **Erros do n8n**: 16 `erro_workflow`; 6 são do nó de avaliação do cenário de teste (não do agente) e 3 "Bad request" no contexto são de 10/11 (antes da estabilização).
- **Trava de saída**: "margem" bloqueava "margem de segurança/sangria" (vocabulário normal de gráfica) e levava à resposta neutra; corrigido na origem.
- **Workflow solto**: um workflow de consulta ao site do fornecedor (ativo, sem pasta e com o nome do fornecedor no título; raspa o site sem login) NÃO é usado pelo despachante. Recomendação: despublicar. Não toquei.

### Entregue
- Migrations aplicadas: coluna `quer_nota_fiscal`, `contacts_segment_check` alargado, consentimento `none`, trava de saída "margem", `resetar_chat_completo` (Fase 1). n8n: `salvar_contato` (15 campos) e WF2 (prompt) publicados.
- Cenários novos `e12-*` em `testes_conversa` (vago, item parecido, 3 itens, link do SKU, nota fiscal, endereço, sacola, segmento sem kit); `e5-07` e `e8-fluxo-2` atualizados para a política do endereço público.
- Blindagem: `npm run gate` (typecheck, testes e build; roda no CI em `.github/workflows/gate.yml`) e `scripts/test-contratos.ts` (toda RPC e Edge Function chamada pelo n8n existe; prompt sem as instruções conflitantes; contexto lido; sem alias de modelo nos workflows).

### O que NÃO foi feito ou verificado (honestidade)
- **Modelo fixo do Gemini: tentei `gemini-2.5-flash` e o agente passou a dar ERRO em todas as rodadas; revertido para o alias na hora.** A versão precisa ser descoberta (o alias atual não informa a versão) e validada antes de fixar. Os workflows exportados já não contêm o alias no fallback.
- Suíte completa NÃO rodada. Com o prompt novo e o alias do modelo: `e12-01` (vago), `e12-04` (3 itens, cotou tudo e mandou PDF), `e12-07` (nota fiscal salva) e `e12-08` (endereço do balcão) PASSARAM; `e12-05` (link do SKU) e `e12-09` (sacola) não terminaram a tempo; `e12-02`, `e12-03`, `e12-10`, os `e5-*`, `mvp-*` e `e8-*` não foram reexecutados. No `e12-04` o cliente pediu cartão 4x4 e a Laura cotou 4x0 como "mais próxima": falha de qualidade que o critério automático não pega.
- Exportar para `n8n/`: `buscar_conhecimento`, `buscar_produto`, `agendar_followup` e o clone do WF2 continuam pendentes (o WF2 local foi atualizado à mão com o que publiquei).
- Tela "Erros recentes dos workflows do agente": não verificada.
- Teste ponta a ponta até o link do Mercado Pago em modo teste: não feito (o link é simulado nos cenários).
- Foto no PDF e a Laura enviar a foto do item orçado: não feito.
- 5 funções do banco ainda sem migration no repositório (listadas em `scripts/test-contratos.ts`): `agente_agendar_followup`, `agente_salvar_contato`, `verificar_frete`, `buscar_conhecimento`, `agente_preco`.

## Fase 1: /resetchat completo e números de teste (12/11/2026, branch `feat/resetchat-numeros-teste`)
- **Feito**: `/resetchat` agora chama `resetar_chat_completo` e apaga TODO o histórico do número (mensagens, notas, tarefas, alertas, orçamentos, pedidos não pagos e tudo que aponta para eles, logs e execuções do agente, follow-ups, envios de foto), devolvendo contato e conversa ao estado de cliente novo (fica o número e o nome do WhatsApp). Antes pede confirmação no navegador.
- **Travas**: só número da lista `numeros_teste` (casa pelo final do `wa_id`; inicial: 3132232356); recusa contato com pedido pago (`payment_status = aprovado`, etapas de produção em diante ou pagamento aprovado); cada tentativa, aceita ou recusada, grava em `reset_chat_auditoria` (que o reset não apaga). Aba Configurações > Números de teste lista, cadastra (só admin) e mostra os últimos usos.
- **Migrations** (aplicadas): `20261201000001` (tabelas, função, recusa com auditoria).
- **Testado de verdade (produção)**: ensaio em transação desfeita, recusa de TEIA (número comum) e de número de teste com pedido pago; reset REAL do 3132232356 (128 mensagens, 198 logs do agente, 36 execuções, 18 alertas, 2 orçamentos e 2 envios de foto apagados); depois, mensagem nova simulada: histórico só com ela, sem resumo, cérebro vazio, sem orçamento nem pedido, situação "novo".
- **Não verificado**: o clique no botão pelo navegador (o front passou em typecheck e build, não abri o CRM); apagar arquivos do Storage (PDFs de orçamento e fotos ficam, são inofensivos); números de celular com o nono dígito cadastrados de outro jeito (o casamento é pelo final do número).
- **Achado para a Fase 2**: `agente_contexto` lista `consentimento_promocoes` como "já cadastrado" em cliente novo (o valor padrão `none` conta como cadastrado), então a Laura nunca pergunta.

## Origem logada funcionando e calibrada (12/11/2026, noite)
- **Login feito pelo dono na VPS** e reconhecido (`origem_sessao.logado = true`). A leitura real da página de produto devolve: referência, material, cores, gramatura, peso, **tamanho da arte** e **tamanho final**, prazo de produção, valor do serviço, acabamentos com preço e dias, quantidades e fotos do produto exato (arquivos com o SKU no nome).
- **Achado**: SACDUP0201 custava R$ 2.002,93 no catálogo e R$ 2.186,21 no site; o preço da planilha (R$ 3.204,90) ficava abaixo do piso real (R$ 3.279,32). CFV02 e SCK02C500 conferem.
- **Regra automática (`origem_aplicar`, modo `app_settings.origem.modo = atualizar`)**: vale só se a "Referência" da página for o SKU e o acabamento padrão custar 0; custo e prazo SÓ SOBEM (queda só registra); variação fora de 50% a 160% só registra; grava `tamanho_final` (L x P x A) e `tamanho_arte` de embalagens. O gatilho do catálogo recalcula pisos e guarda o histórico; `calcular_preco` já usa o novo piso. Alerta baixo ao dono quando o custo sobe (`origem_custo_atualizado`).
- **Ao vivo no fluxo**: `montar_orcamento` (n8n) chama `origem-consultar` para o primeiro SKU antes de montar. A resposta ao agente não traz custo, URL de imagem nem endereço da origem.
- **Fotos**: a URL da foto do produto exato fica em `origem_consultas.detalhe.foto_url` (só o servidor lê). **Falta**: foto no PDF do orçamento (usar a foto já tratada de `ecommerce_products.fotos`) e a Laura mandar a foto do item orçado; varrer os ~738 SKUs de embalagem sem tamanho final e os mais vendidos para atualizar custos.
- O serviço não nasce mais pausado (`let pausado = false`); script segue vindo de `origem_script()`.

## Origem logada 24 h, tamanhos e melhorias (12/11/2026, mesma branch)
- **VPS (Coolify, serviço `origem-logada`)**: Chrome real com perfil persistente (noVNC com usuário `gbh` e senha em `SERVICE_PASSWORD_NOVNC`, no painel do Coolify) e API de consulta com token (`/saude`, `/consultar`) no mesmo contêiner de rede. Guarda de sessão a cada 4 min: se perder o login, `origem_sessao_registrar` cria alerta alto ao dono. Referência em `infra/origem-logada/`.
- **12/11 (noite)**: o login no navegador da VPS falhou no Turnstile da Cloudflare ("Verification failed"). Causa provável: o guarda estava anexado ao Chrome por CDP desde a subida. Correção: o serviço nasce **pausado** (`INICIO_PAUSADO=sim`), conecta ao Chrome só durante cada operação e desconecta; o script agora vem do banco (`origem_script()`, `app_segredos.origem_script`), então recalibrar = atualizar a linha e reiniciar o serviço. Rotas novas: `/retomar`, `/pausar`, `/diagnostico` (texto das abas abertas) e `/sessao` (importa cookies de uma sessão feita em outro computador). Depois do login, trocar `INICIO_PAUSADO` para `nao` (ou chamar `/retomar`).
- **PENDENTE DO DONO**: abrir o navegador do serviço (Coolify > origem-logada > domínios; endereço novnc), entrar na conta da origem uma vez (e-mail, senha, CAPTCHA) e deixar a janela aberta. Depois conferir `select * from origem_sessao` (logado = true) e `origem_consultas`.
- **Edge Function `origem-consultar`** (dono ou service role): pega o caminho do SKU (`produto_fotos_mapa`), chama a API da VPS, compara preços lidos com o custo do catálogo e grava `origem_consultas` (confere, divergente, inconclusivo, erro). URL e token da VPS ficam em `app_segredos` (`origem_api_url`, `origem_api_token`). Modo `app_settings.origem.modo = observar`: registra e alerta, nunca bloqueia; `bloquear` fica para depois de calibrar.
- **n8n**: `GBH | FERRAMENTA | montar_orcamento` consulta o primeiro SKU antes de montar (observação, timeout 25 s, falha não atrasa a venda). Sem login na VPS responde na hora "sessao_expirada".
- **Não calibrado**: os seletores e a leitura de preços/medidas são genéricos; só dá para ajustar depois do login (ver o que `/consultar` devolve em `origem_consultas.detalhe`). Divergência hoje = nenhum preço da página bate com o custo do catálogo e o SKU aparece no texto.
- **Tamanhos**: `catalogo.tamanho_final` e `tamanho_arte` (embalagens). 298 de 1.037 SKUs 3D preenchidos de títulos da loja; o resto mostra "a confirmar com o cliente". `buscar_produto` não mostra mais o tamanho da arte como tamanho do produto.
- **Melhorias aplicadas**: aprovação do link exige palavra explícita (palavras soltas só valem como mensagem inteira) e `marketing_consent` volta a gravar texto (`opted_in`/`opted_out`).
- **Resultado de segurança**: o Coolify negou a leitura de segredos pelo conector (correto); o token da API foi definido por mim e guardado só no Coolify e em `app_segredos`.

## Primeira venda automática: lições e correções (12/11/2026, branch `claude/laughing-ride-6sslzd`)
Cliente TEIA (sacolas), pedido pago. O que a conversa mostrou: PDF enviado 1 minuto depois de uma pergunta sem resposta; sacola 4x0 orçada para quem pediu frente e verso, com a afirmação inventada "cobre frente, verso e laterais"; tamanho da ARTE planificada (465 x 285) apresentado como tamanho do produto (`catalogo.tamanho_mm` é o da arte; o tamanho final não existe no catálogo); resumo do PDF e pedido de APROVADO repetidos depois do "aprovado".
- **Causa no prompt**: regra 19 do WF2 ("COTE LOGO") mandava cotar e enviar o PDF na mesma resposta, e a regra 1 mandava "fechamento assumido".
- **Feito (produção)**: migration `20261130000001` (`orcamento_gate_qualificacao`: bloqueia PDF com pergunta sem resposta, conversa curta demais, frente e verso pedido para item 4x0, embalagem sem tamanho final dito pelo cliente); sub-workflow `GBH | FERRAMENTA | gerar_pdf_orcamento` chama a trava antes do envio e devolve a orientação ao agente (falha da trava não bloqueia a venda); WF2 com regras 1, 19, 22 e 23 novas (publicado). Cenários `e11-01` e `e11-02` em `testes_conversa`. Teste SQL: `supabase/tests/gate_qualificacao.sql`.
- **Não feito**: conferência ao vivo no site do fornecedor (contêiner com Chrome logado na VPS, ferramenta `conferir_origem`); colunas `tamanho_final` e `tamanho_arte` no catálogo; export de `n8n/` atualizado (o MCP do n8n não grava no repositório: reexportar WF2 e `gerar_pdf_orcamento`).
- **Observado**: `agente_salvar_contato` grava `marketing_consent` booleano em coluna texto; a regex de aprovação de `preparar_link_pagamento` aceita "sim", "ok", "beleza", "certo" como aprovação.

## E-commerce/CRM Fase 16: Kanban por canal e catálogo por SKU atômico (11/11/2026, branch `feat/ecommerce-kanban-catalogo-atomico`)
- Kanban com abas Todos os Pedidos, WhatsApp (Laura) e E-commerce / Site. Os dois canais continuam no mesmo pipeline e nas mesmas travas de pagamento/arte/produção.
- Checkout passa a gravar `origin_label = 'ecommerce'`; trigger padroniza `canal = 'ecommerce'`. Valores legados `site` continuam aceitos nas funções de status e cobrança.
- Loja: cards separados por `produto_slug`, cada página lista tiragens/SKUs individuais com preço e prazo em dias úteis por opção. Ficha mostra material, gramatura, código de cores, acabamentos e prazo usando campos do catálogo. Acesso rápido às cinco categorias solicitadas.
- Migration `20261128000002_ecommerce_kanban_catalogo_atomico.sql` atualiza RPCs e trigger. **Pendente**: executar typecheck/testes/build, revisar PR e aplicar migration em produção somente após aprovação.

## E-commerce Fase 15: menu fixo, filtros na barra, ordem e cards compactos (10/11/2026, branch `claude/funny-ride-s51uyy`)
- Menu lateral fixo com rolagem própria, filtros em barra acima da lista (acompanha a rolagem), ordem por quantidade e impressão (4x0, 4x1, 4x4), cards e cabeçalho mais compactos. Migration `20261128000001` (aplicada). Detalhes em `docs/ecommerce.md` (Fase 15). Conferido em 390, 820, 1366 e 1920 px, sem rolagem lateral.

## E-commerce Fase 14: menu em etapas e departamentos completos (10/11/2026, branch `claude/funny-ride-s51uyy`)
- Menu e filtros agora abrem fechados e o cliente vai destrinchando; busca de categorias e tipos no menu e sugestões no cabeçalho; página `/departamentos` com tudo; gaveta "Departamentos" no cabeçalho; meta do Google Search Console. Detalhes em `docs/ecommerce.md` (Fase 14). Conferido em 390, 768 e 1366 px, sem rolagem lateral.
- Chaves: o dono já cadastrou `SUPERFRETE_TOKEN` e `GEMINI_API_KEY` no Supabase. Falta só o Pixel da Meta (`META_PIXEL_ID`, `META_CAPI_TOKEN` e `NEXT_PUBLIC_META_PIXEL_ID`). Falta testar o envio nacional (SuperFrete) com um CEP de fora de BH.

## E-commerce Fase 13b: duplicidade, títulos e PDF no servidor (10/11/2026)
- **Wind Banner repetido**: causa e correção em `docs/ecommerce.md` (Fase 13b). 0 opções ativas repetidas depois da correção; 1.246 variantes ocultas (257 de preço igual, 989 com preço maior) listadas por `select sku, oculto_motivo from ecommerce_products where oculto`. Rotina `private.loja_dedup` a cada 15 min; teste em `supabase/tests/loja_duplicidade.sql`.
- **Títulos crus** padronizados na origem (`titulo_vitrine`) e **PDF obrigatório** agora recusado pelo servidor (`validar_antes_de_cobrar`).
- **Não feito**: trocar as fotos com o carimbo "TEXTURA" (está dentro da imagem de origem; só dá para refazer com outra foto ou edição de imagem por IA, que não rodei em milhares de arquivos); nomear as variantes ocultas (depende do dono).

## E-commerce Fase 13: navegação em 4 níveis, tudo em uma página, PDF no checkout e Laura (10/11/2026, branch `claude/funny-ride-s51uyy`)
- **Laura (n8n, publicado)**: regra 3 do agente agora usa a frase exata de cobertura de preço quando o cliente pede desconto, acha caro ou diz que vai pesquisar (G2 só com a proposta); o nó `Montar prompt` deixou de mandar usar "vc" e o texto do corte virou "pedidos pagos até 10h30 começam a ser produzidos no mesmo dia". Export atualizado em `n8n/GBH-WF2-Agente.json`. O clone `GBH | TESTE | Agente (clone do WF2)` NÃO foi alterado. Falta rodar os cenários `e5-*` e um teste "achei caro, vou pesquisar" com o modelo real.
- **Loja**: categoria > subcategoria (cards) > opção > tamanhos; lista completa em uma página (rolagem infinita); cards com nome completo, etiquetas e quantidade; menu e filtros na home; PDF obrigatório no checkout. Detalhes em `docs/ecommerce.md` (Fase 13).
- **Banco (aplicado)**: migrations `20261126000001` a `20261126000005` (desagrupar, famílias, funções, facetas rápidas, cache das facetas da home). Edge Function `loja-arquivo` publicada.
- **Chaves e pendências para finalizar (dono)**: Hostinger tem só `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` e `NEXT_PUBLIC_SITE_URL`; falta `NEXT_PUBLIC_META_PIXEL_ID` (e novo build). Supabase (Edge Functions > Secrets), conferir: `SUPERFRETE_TOKEN` (envio nacional), `GEMINI_API_KEY` (blog e verificação de marca), `META_PIXEL_ID` e `META_CAPI_TOKEN` (Purchase no servidor). Também: "Leaked password protection" no Supabase, Search Console e o teste real de Pix pelo site.
- **Não feito**: acabamentos extras com preço no carrinho; títulos crus de ~3 mil opções (ficam sem subcategoria); o PDF no checkout só é exigido no navegador (a API não recusa pedido sem arquivo); validação de resolução do PDF (300 dpi) é só orientação.

## E-commerce Fase 12: taxonomia e filtros (10/11/2026, branch `claude/funny-ride-s51uyy`)
- **Banco (aplicado)**: migrations `20261125000001` a `20261125000005` (verticais, 572 subcategorias do fornecedor, atributos materializados com atualização a cada 15 min, `loja_facetas`, `loja_modelos_f`, `loja_arvore`, `loja_interpretar_busca`). Conferido: 8 verticais, 17.231 de 20.381 opções com subcategoria, filtro combinado responde rápido. A migration 4 foi aplicada pelo dono no SQL Editor (a confirmação do conector expirava).
- **Loja**: menu por verticais com mega menu, filtros facetados com contadores e chips, busca com sinônimos, selos de acabamento nos cards, rotas `/api/v1/taxonomia`, `/facetas` e `/modelos`. Sem rolagem lateral em desktop e celular (prints conferidos). `npm run test:loja` cobre a leitura dos filtros da URL.
- **Detalhes e o que fica**: `docs/ecommerce.md` (Fase 12) e `docs/api-v1.md`.
- **Laura (NÃO alterado no n8n)**: o WF2 publicado já tem cérebro, lista de itens, frete dos 7 bairros e tom sem "vc" repetitivo (nó do agente). Faltam dois ajustes, em `docs/agente/laura-ajustes-fase12.md`: a frase exata de cobertura de preço quando o cliente pede desconto, acha caro ou diz que vai pesquisar, e remover do nó `Montar prompt` a linha que manda usar "vc" (conflita com o agente). Exigem reescrever o workflow pelo SDK do n8n e testar com o modelo real; deixei fora desta fase para não arriscar o atendimento em produção.
- **Observado**: ~3 mil opções com título cru (sem subcategoria); filtro Express vazio (menor prazo é 2 dias úteis).

## CRM no celular: usabilidade (10/11/2026)
- **Zoom ao tocar nos campos**: o iPhone dá zoom em campo com fonte menor que 16 px. Agora todo campo tem 16 px no celular (`src/index.css`) e o `Textarea` usa `text-base`.
- **Conversa**: cabeçalho em uma linha (voltar, nome, status IA/Você, Detalhes e menu ⋯ com assumir/devolver, atenção e abrir pedido); etiquetas em uma fileira que rola; compositor com abas Responder/Nota, atalhos PDF e Link, campo que cresce com o texto e respeita a área segura do iPhone.
- **Navegação**: barra inferior (Conversas com contador, Kanban, Pedidos, Contatos, Mais); some com a conversa aberta, como no WhatsApp.
- **Kanban**: indicadores em uma fileira com rolagem lateral (antes ocupavam metade da tela).
- Telas conferidas com o simulador (`docs/telas/conversa-celular.png`, `kanban-celular.png`). Próximos candidatos: lista de conversas, Contatos e gaveta do pedido.

## Fase 11: vitrine em modelos, CRM e cérebro da Laura (10/11/2026, branch `claude/funny-ride-s51uyy`)

- **Banco (aplicado)**: migrations `20261124000001` (`loja_modelos`, SKU em `loja_buscar` e `loja_produto`, `irmaos`, `acabamentos_extras`, `loja_acabamentos`) e `20261124000002` (cérebro da Laura). Conferido: `loja_modelos` devolve 45 modelos de cartões, `anon` executa as funções novas e não lê a tabela de acabamentos.
- **Loja**: menu lateral, cards de modelo com SKU, home com vitrines por departamento, hero rotativo, configurador com tiragem e impressão, "Compre junto", Open Graph. Sem rolagem lateral em desktop e celular. **Falta publicar na Hostinger**: o deploy sai do merge na `main` (auto-deploy).
- **CRM**: coluna Pronto (aviso ao cliente em um clique: texto livre na janela, senão template `aviso_operacional_pedido`), botão para reabrir a janela de 24 h no chat, gaveta inferior de detalhes no celular, pedido manual com nome, WhatsApp, e-mail, CPF/CNPJ e endereço.
- **Laura (WF2 publicado)**: tom sem "vc" repetitivo, regra de lista de itens (um orçamento com todos), frete só nos 7 bairros por `verificar_frete` (a mesma regra do site) e bloco CÉREBRO. O cérebro é recalculado no banco a cada mensagem, sem modelo.
- **Decisões que mudei e preciso que confirme**: SKU público na loja (regras em `CLAUDE.md` e `AGENTS.md` atualizadas); a Laura continua sem citar SKU.
- **Não feito**: extração logada rodou só como código (precisa do login e do CAPTCHA do dono); acabamentos extras no carrinho; foto de perfil do WhatsApp (a API não fornece); testes com o modelo real da Laura (só validei a sintaxe da expressão do prompt).
- **Fotos (feito no banco, 10/11/2026)**: auditoria das 3.377 imagens de `loja-produtos`: 0 produtos sem foto, 729 abaixo de 1000 px (a origem só tem a imagem pequena, sem versão maior). As 729 foram ampliadas com Lanczos, limpeza de ruído e nitidez, e reenviadas no mesmo caminho (URLs inalteradas); os originais ficam em `loja-produtos/originais/`. Depois: 3.377 de 3.377 com 1000 px ou mais, a maior com 306 KB. Ampliar não cria detalhe novo; foto de produto realmente melhor só vem de uma imagem maior da origem ou de ampliador por IA. `scripts/melhorar-fotos.ts` repete a auditoria quando entrarem fotos novas.
- **Extração logada do fornecedor**: ainda sem dados (0 acabamentos e 0 gabaritos nas 20 páginas de teste, que eram abridores); falta o HTML real para ajustar os seletores. Fila lida agora em páginas (3.829 produtos).
- **Observado, não corrigido**: `agente_salvar_contato` grava `marketing_consent` como booleano, mas a coluna é texto (`none`/`opted_in`/`opted_out`); quando o cliente responde sobre promoções a gravação pode falhar. Vale um teste.

**Próximo passo:** teste real de pagamento pelo site (Pix de valor baixo, só com autorização do dono) e as pendências do dono listadas na Fase 10. O roteiro do e-commerce (Fases 1 a 10) está concluído. Ver `docs/ecommerce.md`.

## E-commerce Fase 10: loja no ar e varredura de segurança (10/11/2026)

- DNS propagado e site `suagraficabh.com.br` no ar com HTTPS (certificado vitalício, redirecionamento ligado). Conferido no domínio real: 8 rotas e um produto em desktop e celular, sem rolagem lateral, JSON-LD presente, tempo de resposta cerca de 0,7 s.
- Migration `20261123000001` (aplicada): `calcular_acabamento_seguro` fechada para `anon` e `authenticated` (vazava custo de acabamento). `npm audit` da loja: 0 vulnerabilidades (`overrides.postcss`).
- Detalhes, avisos que ficam e o que sobra para o dono em `docs/ecommerce.md` (Fase 10).
- **Visto uma vez e não reproduzido**: erro de hidratação do React (#418) numa rota no celular, em uma passada de teste; em duas voltas completas seguintes não voltou. Se aparecer no console de um cliente, investigar a página.
- **Pendente do dono**: `SUPERFRETE_TOKEN`, `GEMINI_API_KEY`, Pixel e token da Meta, "Leaked password protection" no Supabase, Search Console, imagem Open Graph. **Decisões**: follow-up de carrinho abandonado e a Laura usar `loja-frete`.
- **Não feito**: teste real de Pix e de cartão pelo site (cobrança real exige autorização).

## E-commerce Fase 9: checkout, frete, Pix e site no ar (09/11/2026)

- Migrations `20261122000001` e `20261122000002` (aplicadas): `cep_bairros`, `verificar_frete` por bairro, `loja_frete_base`, `carrinhos_abandonados` + `loja_carrinho_salvar/fechar` + `v_carrinhos_recuperar`, `loja_pedido_status`, método de entrega `correios`. Edge Functions `loja-frete` (nova) e `loja-checkout` (Pix, envio, troca de pagamento) publicadas.
- Loja: `/checkout` em 3 passos, carrinho enxuto, rotas `/api/v1/frete`, `/carrinho`, `/checkout/pay`, `/pedido/status`.
- **Site publicado na Hostinger** (`suagraficabh.com.br`, site novo criado na conta). A publicação só funcionou com Output Directory `.next`. **Falta o DNS**: o domínio usa o DNS do Registro.br e a raiz não tem registro A; o MX e o SPF da Hostinger já existem e devem ser mantidos.
- Validado: regra dos 7 bairros no banco (Savassi e Centro de BH grátis, Santo Antônio e "Centro" de São Paulo não), `loja-frete` ao vivo (CEP de BH e de SP), recusas do checkout, `npm test`, build, prints desktop e celular sem rolagem lateral.
- **Não testado ponta a ponta**: geração real do Pix e do link pelo site (evitei pedido real em produção; conferir o primeiro pedido no Kanban, título "Site SG-..."); SuperFrete sem token.
- **Pendências do dono**: DNS no Registro.br; `SUPERFRETE_TOKEN`; `GEMINI_API_KEY`; Pixel da Meta. **Decisões**: ligar o follow-up de carrinho abandonado (template de utilidade na Meta e consentimento); a Laura passar a usar `loja-frete` para o frete grátis.

## E-commerce Fase 8: blog e central de ajuda (09/11/2026)

- Migrations `20261121000001` e `20261121000002` (aplicadas): `blog_fontes` (7 feeds do setor + NewsAPI desligada), `blog_pautas`, `blog_posts`, funções públicas `loja_blog_*`, `app_settings.blog`, agendamento `blog-pautas`. Edge Function `blog-pautas` publicada.
- Primeira rodada real: 8 fontes lidas sem erro, 60 notícias, 46 barradas pelo filtro de assunto, 14 na fila.
- **Pendente do dono:** o segredo `GEMINI_API_KEY` não existe nas Edge Functions (as fotos também rodavam sem ele). Sem ele as pautas ficam guardadas e nenhum post é escrito. NewsAPI: o plano gratuito não permite produção; fica desligada (ver `docs/blog.md`).
- Loja: `/blog`, `/blog/[slug]`, `/ajuda` nova (6 categorias com busca e FAQPage). CRM: Catálogo > Blog do site.

## E-commerce Fase 7: Meta Pixel e Conversions API (09/11/2026)

- Migrations `20261120000001` e `20261120000002` (aplicadas): fila `meta_eventos`, `meta_evento_registrar`, gatilho de Purchase, lote e resultado para a função, agendamento `meta-conversions`. Edge Function `meta-conversions-api` publicada.
- Loja: Pixel (só com consentimento), aviso de cookies, eventos com `event_id` compartilhado e rota `/api/v1/eventos`.
- **Não existe Pixel na conta nem no Business da Sua Gráfica BH** (conferido pela API da Meta) e as ferramentas daqui não criam um: a fila guarda os eventos até `META_PIXEL_ID` e `META_CAPI_TOKEN` existirem.
- **Incidente corrigido na hora:** a primeira versão do gatilho de Purchase tinha um erro (faltava um valor no insert) que faria a confirmação de pagamento falhar. O teste pegou antes de qualquer pagamento (conferido: nenhum aviso do Mercado Pago no intervalo, conferência de 10 min normal). A correção também faz o gatilho nunca bloquear o pagamento por causa da medição.

## E-commerce Fase 6: estrutura fiscal do Bling e marketplaces (09/11/2026)

- Migrations `20261119000001` e `20261119000002` (aplicadas). NCM sugerido em 20.390 SKUs (todos `ncm_revisar` até o contador confirmar a regra). Payload `bling_pedido_payload` conferido num pedido pago real: monta contato e pedido e lista as pendências (CPF, CEP, endereço, IBGE, e-mail, id da loja no Bling).
- Edge Function `bling-webhook` publicada: recusa aviso sem assinatura (401) e grava os válidos em `bling_eventos`.
- `catalogo_marketplace`: CFV02 sai a R$ 191,90 no Mercado Livre e R$ 194,90 na Shopee para receber os mesmos R$ 151,90 do site.
- Nada foi enviado ao Bling. Estudo fiscal, pontos para o contador e passos de ativação em `docs/bling-fiscal.md`.
- Incidente evitado: a primeira versão de `fiscal_aplicar_ncm` recalculava as categorias a cada linha e travou por minutos; as duas sessões foram canceladas antes de afetar a operação e a função foi refeita (CTE materializado, 20 mil linhas em segundos).

## E-commerce Fase 5: vitrine, produto, carrinho (09/11/2026)

- Loja navegável de ponta a ponta: home, categorias, busca, produto com configurador e carrinho que fecha o pedido pelo checkout da Fase 4. Migration `20261118000001` (aplicada): `loja_categorias`, `loja_produto`, `loja_slugs`.
- Conferido com prints (desktop e celular, sem rolagem lateral): configurador recalcula preço, arte, prazo e frete; "Comprar agora" pede o WhatsApp e leva ao carrinho.
- **Não feito:** carrinho abandonado no banco e follow-up (Fase 9); títulos de produtos ainda sem ficha seguem crus até a fila da Fase 2 terminar.

## E-commerce Fase 4: API `/api/v1` (09/11/2026)

- Migrations `20261117000001` a `20261117000004` (aplicadas): `arte_conferencia_valor` (R$ 14,90), `loja_buscar` (com coluna `busca` pré-calculada e índice trigrama; responde em ~40 ms no banco), `loja_cotar`, `loja_calcular`, `loja_checkout_preparar`, filtros privados de frete e prazo.
- Edge Function `loja-checkout` publicada; rotas Next em `ecommerce/app/api/v1/` com limite por IP.
- Testado: busca, cotação (pronta, conferência e criação), cálculo com CEP central, Grande BH e fora de MG; checkout validado no banco dentro de transação desfeita (pedido origem `site`, item "Conferência e ajuste técnico do arquivo", total R$ 166,80 para CFV02 + conferência); recusas da função publicada (400 e 409).
- **Não testado ponta a ponta:** a geração real do link do Mercado Pago pelo site (evitei criar pedido de verdade em produção). O caminho é o mesmo `mp-criar-link` que já funciona no CRM. Primeiro pedido real pelo site: conferir no Kanban (título "Site SG-...").
- Contratos em `docs/api-v1.md`.

## E-commerce Fase 2: fichas técnicas e fotos (09/11/2026)

- Função `loja-fichas` e fila `loja_fichas` (migrations `20261116000001` e `20261116000002`, aplicadas). Lote de teste com 3 produtos: ficha, título de balcão e foto aplicados na vitrine. A fila completa (3.829 produtos) roda sozinha a cada minuto, cerca de 3 h.
- Leitor e glossário de balcão em `supabase/functions/_shared/ficha-origem.ts`; testes em `scripts/test-loja.ts` (`npm run test:loja`, dentro do `npm test`).
- **Não feito:** acabamentos opcionais com preço e gabaritos (exigem login na origem). Verificação de marca por IA desligada, como nas fotos do WhatsApp.
- **Como conferir:** `select loja_fichas_resumo()` logado como dono; abrir uma foto em `/storage/v1/object/public/loja-produtos/<caminho>`.
- Dono autorizou mesclar os PRs com testes verdes (registrado em `CLAUDE.md` e `AGENTS.md`).

## E-commerce Fases 1 e 3: base da loja e preço pela planilha (branch `claude/funny-ride-s51uyy`, 09/11/2026, pronto para revisão)

Decisões do dono: a planilha oficial de preços de venda substitui a pesquisa de mercado; endereço do balcão passa a ser público; loja em Next.js na Hostinger (`ecommerce/`); um PR por fase. Roteiro completo em `docs/ecommerce.md`.

### O que foi feito
- **Planilha conferida** (não versionada): 20.381 SKUs, 140 categorias, 0 duplicados, todos terminam em ,90, todos >= custo x 1,5, lucro bruto >= R$ 65 e nenhum com prejuízo. Com imposto e taxas, 5.841 (Pix) a 7.596 (cartão 2x) ficam com lucro LÍQUIDO abaixo de R$ 65: por isso a trava do modo planilha usa o lucro bruto, como a própria planilha.
- **Banco (aplicado em produção):** migrations `20261115000001` a `20261115000004`. `calcular_preco` lê `catalogo.preco_venda` (mesmo formato de retorno, `regra = planilha`); fórmula antiga em `private.calcular_preco_mercado` para SKU sem preço; `validar_margem` e `montar_opcoes` com lucro bruto mínimo no modo planilha; `lucro_liquido_minimo` 60 -> 65; horário do balcão 08:00. Staging, carga em lotes e relatório. Vitrine `ecommerce_products` (pública, sem SKU, custo nem piso).
- **Carga feita:** 20.381 SKUs com preço da planilha, 0 barrados, 0 custos alterados; 5 SKUs numéricos (planilha "0001", catálogo "1") casados por `private.sku_planilha`. 9 SKUs do catálogo não estão na planilha e seguem a fórmula antiga: CORD20MM, ETIQ-BAG, SQZ-500, CAM-DRY, BONE-AR, CART-A5, CV-LONA100-OP, SOB-CRED-100X148, SOB-CORD-825X20. Vitrine com 20.381 itens, 3.462 produtos e 140 categorias. Token temporário apagado.
- **n8n:** `GBH | FERRAMENTA | montar_orcamento` sem o nó de pesquisa (publicado); `GBH | FERRAMENTA | pesquisar_preco_mercado` despublicado. JSONs em `n8n/` atualizados.
- **CRM:** botão "Importar planilha de preços" em Catálogo > Produtos (confere no navegador, envia e aplica em lotes de 2.000 para caber no limite de 8 s). Textos de preço atualizados.
- **Loja (`ecommerce/`):** Next.js isolado; home, /categorias e /ajuda iniciais com dados reais da vitrine; cabeçalho, rodapé com crédito Bauerlab, botão do WhatsApp por contexto, selos, JSON-LD da empresa, robots e sitemap.
- **Testes:** `npm run typecheck`, `npm test`, `npm run build` e `npm run build:ecommerce` verdes; teste novo do leitor da planilha em `scripts/test-rules.ts`.

### O que NÃO foi feito (honestidade)
- `npm run test:sql` não roda: o executor local falha em funções que só existem em produção (drift anterior a esta etapa). Os testes SQL foram feitos direto em produção com conferência de resultado.
- Prompt da Laura ainda não cita o endereço do balcão (fica para a Fase 5).
- Títulos da vitrine ainda vêm da descrição do catálogo ("Couche Brilho - 300g"); a tradução de balcão completa e a ficha técnica entram na Fase 2. `traduzir_especificacao` chama de "papel fino" itens que não são papel (ex.: chaveiro UV 10g): revisar na Fase 2.
- Condição especial G2 continua calculando a "gordura" pelo piso líquido; em itens de margem apertada ela pode não oferecer desconto. Decidir se passa a usar o piso bruto.

### Como testar
1. CRM > Catálogo > Produtos: o preço de venda de CFV02 deve ser R$ 151,90.
2. Pedir um orçamento de cartão pelo WhatsApp de teste: o valor deve bater com a planilha.
3. `npm run dev:ecommerce` com `ecommerce/.env.local` (chave publicável) e abrir http://localhost:3001.

## Auditoria do relatório de aprimoramento (04/11/2026)

Conferência de cada item do relatório contra o banco de produção, os workflows exportados em `n8n/` e o código. Status: **OK** (verificado), **Parcial** (existe, mas diverge do relatório) e **Pendente** (não existe).

| # | Item | Status | Evidência e observação |
|---|---|---|---|
| 1 | Deadlock do debounce (WF1) | OK | Nó "Separar mensagens do grupo" emite item vazio controlado; `agente_finalizar` é chamada. |
| 1b | Lock com TTL | Parcial | Concorrência por `agente_execucoes` com janela de 3 min. O relatório pede 90 s. Reduzir pode gerar resposta duplicada se a rodada passar de 90 s, então não foi alterado. |
| 2 | Normalização de medidas (WF1) | OK | Regex `(\d+)\s*([×X*]|por)\s*(\d+)` gera `NxM`. |
| 3 | Ingestão contextual de mídia | Parcial | Documento entra no CRM e é transcrito/lido. A separação "referência de orçamento" x "arte pós-pago" está no fluxo de arte (`arte_receber`), não foi confirmada no export do WF1. |
| 4 | Abertura adaptativa (WF2) | OK | Proibida a pergunta genérica quando o cliente já especificou o pedido. |
| 5 | Pergunta-filtro antes das opções (WF2) | OK | Prompt exige a variável-chave (ex.: 4x0 x 4x4) antes de `enviar_foto_produto`. Filtro aplicado no prompt, não na busca. |
| 6 | SDR closer e nichos (WF2) | OK | Captura segmento (barbearia, restaurante/delivery, estética etc.) e orienta o cross-sell. |
| 7 | Cut-off das 10h30 (WF2) | OK | Prompt usa 10h30 em dias úteis. |
| 8 | Medidas técnicas com sangria de 3 mm (WF2) | OK | Prompt exige tamanho refilado e tamanho com sangria. |
| 9 | Regra da casa (WF2) | OK | Fotos de mostruário antes do pagamento; prova digital só depois. |
| 10 | Pix direto na conversa | Pendente | Não há geração de Pix copia e cola no `mp-criar-link` nem na ferramenta `gerar_link_pagamento`. Hoje sai só o link do Checkout Pro. |
| 11 | Realtime em `messages` e `conversations` | OK | Publicação `supabase_realtime` confirmada; front atualiza o cache pelo payload. |
| 12 | Mensagem automática ao assumir conversa | OK | Texto do relatório, enviado pelo `whatsapp-send` só na passagem IA para humano. |
| 13 | `/resetchat` com auditoria | OK | Migration aplicada; grava `reset_chat` com operador em `agent_logs`. |
| 14 | Nota de áudio transcrita | OK | WF1 baixa o áudio (`whatsapp-media`) e transcreve (Groq `whisper-large-v3-turbo`). |
| 15 | Calcular preço só com SKU e quantidade | OK | `calcular_preco(sku, 1, '{}')` retorna `ok` (testado com rollback). |
| 16 | Preço livre (override) no pedido | Parcial | Campo de total do item e preço manual quando a busca falha. O piso duro continua bloqueando, por regra do projeto. Preço livre abaixo do piso exige decisão do dono. |
| 17 | Normalização dos SKUs | OK | Migration `20261109000002_normalizar_skus_catalogo` aplicada em 04/11/2026: 32 SKUs normalizados, 0 colisões, 0 vínculos órfãos, 9 FKs recriadas com o mesmo estado de validação. |
| 18 | Mensagem consolidada em um balão (4.5) | Pendente (decisão) | O fluxo atual divide a resposta em mensagens curtas ("Dividir em mensagens curtas"). O relatório pede um único balão. Mudança de comportamento em produção: precisa de decisão do dono. |
| 19 | Auditoria noturna às 23h30 com Gemini | Pendente | Não existe a tabela `knowledge_audit_logs` nem o job. É construção nova. |

**Decisões do dono (04/11/2026):** preço abaixo do piso continua bloqueado (item 16). Normalização dos SKUs autorizada e aplicada (item 17).

**Pendências do dono:** itens 10 (Pix direto), 18 (mensagem em um balão) e 19 (auditoria noturna).

**Tempo real (04/11/2026):** o log do Supabase mostrou que o streaming do Realtime caía quando o cliente desconectava (celular em segundo plano, PWA) e não voltava sozinho, então a tela parava de receber mensagens até o F5. Correção no `useRealtimeSync`: estado do canal observado com reconexão automática, atualização completa ao voltar para o app (visibilidade, foco e rede) e, como rede de segurança, polling de 8 s nas mensagens da conversa aberta e de 10 s na lista de conversas. O polling pausa com a aba em segundo plano.

## Correções aplicadas direto nos workflows do n8n (produção, 04/11/2026)

Aplicadas no n8n pelo MCP, sem passar por este repositório. Os workflows exportados em `n8n/` ainda não refletem estas mudanças (ver pendências no fim desta seção).

**GBH | WF1 (entrada e debounce)**
- **Deadlock no debounce:** o nó "Separar mensagens do grupo" emite um item vazio controlado quando o array chega zerado. Assim `agente_finalizar` é sempre chamada. Corrige o travamento de 27 minutos sem resposta no WhatsApp.
- **Normalização de medidas:** regex converte variações (`50×50`, `50X50`, `50*50`, `50 por 50`) para o formato canônico `50x50`.
- **Ingestão contextual de mídia:** PDF e imagem deixam de ser tratados como arte pós-pago. Se a conversa está na fase de orçamento, viram modelo ou referência técnica para a dúvida.

**GBH | WF2 (agente de atendimento)**
- **Abertura adaptativa:** proibida a pergunta genérica "O que você precisa produzir hoje?" quando o cliente já chega com pergunta específica (ex.: caso impressão A1). A IA responde a dúvida técnica de imediato.
- **Pergunta-filtro antes das opções:** a IA qualifica as variáveis mestras (ex.: frente ou frente e verso) antes de disparar opções de catálogo com foto, para não enviar opções irrelevantes.
- **SDR closer e nichos:** qualificação ativa por nicho (barbearia, restaurante, estética), gravada no CRM para orientar upsell cirúrgico.
- **Cut-off operacional:** horário limite para produção no mesmo dia ajustado de 12h00 para 10h30.
- **Medidas técnicas obrigatórias:** tamanho final refilado e tamanho da arte com sangria de 3 mm.
- **Regra da casa:** fotos de mostruário físico antes do pagamento. Montagem formal da arte personalizada só depois do pagamento.
- **Checkout ágil Pix:** emissão de Pix direto pelo Mercado Pago na conversa, para pedido de balcão, sem exigir PDF prévio.

**Exportação (resolvido em 04/11/2026):** `n8n/GBH-WF1-Entrada-e-roteamento.json` (61 nós) e `n8n/GBH-WF2-Agente.json` (28 nós) foram reexportados da instância, sem credenciais (o campo `credentials` foi removido de cada nó e não há segredos no arquivo).

## Comando /resetchat (04/11/2026)

- **O que faz:** no chat do CRM, o operador digita `/resetchat` (só no modo resposta). A mensagem não vai ao cliente. O sistema:
  1. Chama a RPC `resetar_contexto_conversa`: grava `conversations.contexto_desde`, limpa `summary` e `collected_data`, devolve a IA (`ai_handled = true`) e grava em `agent_logs` a ação `reset_chat`, com `operador_id` e `operador_nome` de quem executou (só staff).
  2. Envia a saudação inicial pelo `whatsapp-send`.
- **Como o agente "esquece":** `agente_contexto_base` ignora mensagens e orçamentos anteriores a `contexto_desde`. Os pedidos e orçamentos continuam no banco, só saem do contexto.
- **Migration:** `supabase/migrations/20261109000001_resetchat_contexto.sql` (aditiva; recria `agente_contexto_base`).
- **Status:** migration `resetchat_contexto` aplicada em produção em 04/11/2026 (coluna, RPC e grants conferidos). `whatsapp-send` precisa estar na versão atual.

## Pós-liberação (03/11/2026)

- **Laura respondendo ao vivo:** o dono testou de outro WhatsApp e confirmou a resposta.
- **Modelo:** `agente_config.modelo_padrao`, `modelo_forte` e `modelo_resumo` = `gemini-flash-latest`, o mesmo modelo e a mesma credencial (`Google Gemini(PaLM) Api account`) do workflow da Iracema, que já funcionava. Modelo único: o Pro nunca é chamado. Mudança só de configuração no banco. Voltar ao anterior: `update public.agente_config set modelo_padrao='gemini-3-flash-preview', modelo_forte='gemini-3-flash-preview', modelo_resumo='gemini-3-flash-preview' where id=1;`
- **Pesquisa de mercado:** Gráfica Silcor (`www.graficasilcor.com.br`) registrada em `fontes_pesquisa` como prioridade 1 (AlfaCards prioridade 2) e incluída nos nós "Montar buscas" e "Escolher páginas" do workflow `pesquisar_preco_mercado`. robots.txt conferido (libera produto); termos de uso ainda por conferir (`termos_ok` vazio).
- **Conversa em modo humano:** conversas atendidas manualmente (ex.: negociação em andamento) são ignoradas pela IA de propósito (`agente_execucoes.motivo = modo_humano`). Teste sempre com um número sem conversa.
- **Pendência de segurança:** `public.e2e_exportar` é executável por `anon` (exige token); revogar depois do lançamento se o executor de testes não precisar.

- **Limpeza dos pedidos de teste (03/11/2026):** removidos os 148 pedidos dos contatos de teste (`TESTE_...` e `Teste_...`, todos de 02/11, sendo 48 com pagamento simulado) pela rotina `public.e2e_limpar`, que só apaga contatos marcados `is_teste` e o que depende deles (orçamentos, conversas, alertas, filas). Sobraram 7 pedidos reais; um com flag de teste e 2 contatos de teste cujo nome não começa com "teste" ficaram de fora de propósito (pedido do dono foi pelo nome).

## MVP final (03/11/2026): liberação formal pelo dono

Decisão do dono (proprietário), registrada por escrito nesta sessão: liberar o atendimento ao público, ciente de que o relatório do PR #43 (`docs/agente/e2e-relatorio.md`) trazia o ciclo 1 com média 7,7 e condução e recuperação abaixo de 8, e de que o registro das 3 repetições do funil não foi localizado no repositório. Nenhuma bateria de teste nova foi rodada por ordem do dono.

**Migration `20261108000001_mvp_final_orcamento_limites_piso.sql` (aplicada em produção; versão renomeada para vir DEPOIS da `20261107000004`, que reinstalaria a trava de R$ 5.000 em um banco novo):**
- `montar_orcamento`: até 100 pacotes por linha (cabe 500 + 250 + 50); teto de 50.000 unidades no total (`quantidade_irreal`); SKU fora do catálogo continua bloqueado com `sku_nao_encontrado` (agente não informa valor e chama o dono); trava de R$ 5.000 removida; acima de R$ 10.000 o orçamento sai normal e o dono recebe alerta só no WhatsApp (`orcamento_valor_alto`, sem push); sub-lotes do mesmo produto viram uma linha no PDF (`itens_exibicao`, ex.: 800 un., unitário médio, total). Limites em `app_settings.orcamento_agente` (`valor_alerta`, `unidades_max`, `pacotes_max_linha`).
- `calcular_preco`: sem dado de mercado nem histórico, o preço nunca fica abaixo de custo + R$ 1,80 por bloco (`parametros_comerciais.markup_minimo_bloco`); o piso de lucro (R$ 60 por orçamento) e o piso duro continuam valendo.
- Verificado em produção dentro de transação desfeita: 500 + 250 + 50 de sacolas = 1 linha de 800 un., total R$ 16.799,70 e 1 alerta de valor alto; SKU inexistente = `sku_nao_encontrado`; 100 x SAC1OX1000 = `quantidade_irreal`.

**n8n:** `GBH | FERRAMENTA | pesquisar_preco_mercado` publicado só com SearXNG e Playwright (Tavily, Serper, Firecrawl e os seletores de fonte removidos). Fontes prioritárias na lista `PRIORITARIOS` do nó "Escolher páginas" e `SITES` do nó "Montar buscas". **Falta:** o domínio da Gráfica Silcor (não consegui localizá-lo) e a conferência de robots/termos antes de acrescentá-lo também em `public.fontes_pesquisa`. O modelo do WF2 NÃO foi mexido: o dono seleciona e ativa direto no n8n.

**Liberação:** `agente_config.piloto_ativo = false` aplicado depois do merge; a Laura passa a responder qualquer número assim que o modelo do WF2 estiver ativo no n8n. Reverter: `update agente_config set piloto_ativo = true where id = 1;` (o piloto volta a valer só para `piloto_wa_ids`).

## Etapa 8C: clone de teste do WF2, ciclos de correção e pendências do CRM (em andamento, 02/11/2026)
Decisão do dono: NÃO publicar a versão `9621c5c2` do WF2 em produção; testar num clone isolado. Público segue fechado, nada de produção foi publicado, piloto intacto.
- **Clone isolado (publicado só ele e a entrada de teste):** `GBH | TESTE | Agente (clone do WF2)` (`UApV4FFAqpNsATyz`) e `GBH | TESTE | Entrada de teste (clone)` (`zTm85cM0ueX1hUvo`, webhook com caminho secreto). Isolamento provado: o clone só roda com `teste=true` (o nó `Montar prompt` lança erro se não for), a entrada de teste não tem gatilho da Meta nem nó de envio ao WhatsApp (só RPCs do banco e o clone), o despachante simula PDF, foto, link de pagamento e arte quando `teste=true`, só existem contatos `is_teste`, follow-ups de contato de teste são `simular`, e (novo, migration `20261107000001`) `alerta_criar` grava alerta de contato de teste com push e WhatsApp `desligado` (antes o alerta de uma conversa simulada podia chegar ao dono).
- **Executor dentro do banco (migration `20261107000002`):** `e2e_enfileirar`, `e2e_avancar` (pg_cron a cada 10 s + pg_net), `e2e_exportar` (leitura por token, para `tests/e2e/exportar.ts`). Uma rodada de 70 conversas leva uns 20 minutos e custa ~R$ 3. Sem subagentes executores; o juiz continua sendo agente independente.
- **Ciclo 2 (rascunho de prompt do ciclo 1, formulação 1):** zero críticas automáticas, 1 crítica do juiz (prazo "sexta-feira" sem data), média 7,41 (tom 6,84, condução 6,10, exatidão 6,91, honestidade 8,0, sigilo 9,4, personas 8,33, recuperação 6,30). Pior que o ciclo 1 (7,71): o juiz agora vê o estado de preparo e a regra 5 ("peça o número da opção") atrapalhou "pode fechar" e "APROVADO".
- **Ciclo 3 (em execução):** regras reescritas no clone (aprovação, uma pergunta, datas, orçamentos independentes, exceções), `agente_config.historico_mensagens` 6 para 10, contexto com lista de orçamentos abertos (migration `20261107000003`).
- **Achados fora do prompt:** (1) `pesquisar_preco_mercado` falhava no primeiro nó por falta de credencial Supabase (a pesquisa nunca chegou a rodar; corrigido só no rascunho, falta publicar); (2) SearXNG funciona mas está em endereço público sem senha; (3) Silcor tem páginas com `data-variants` (preço por quantidade) e robots liberado: ver `pesquisa-concorrentes.md`; (4) o simulador não grava as mensagens de "opções com foto" no histórico, então cenários de escolha por posição subestimam a nota.

**Etapa 8B (teste ponta a ponta, 02/11/2026): medição feita, liberação NÃO aprovada.** Relatório em `docs/agente/e2e-relatorio.md`, plano de liberação em `e2e-liberacao-gradual.md`, roteiro manual em `e2e-roteiro-manual.md`. Branch `claude/ecstatic-lamport-5ko2nc`.

### Em andamento (passagem de bastão da 8B)
- **Feito:** `tests/e2e/` (70 cenários x 3 formulações, personas, verificações automáticas, juiz independente, executor, `npm run e2e`, `npm run test:e2e` no `npm test`); migrations aditivas `20261106000001` a `04` (flag `contacts.is_teste`, `e2e_mensagens`, funções `e2e_*`, preparo multi-turno em `agente_teste_preparar`, correção do `agente_debounce` que estourava os 8 s do PostgREST e deixava o cliente sem resposta); ciclo 1 (70 conversas, formulação 1) julgado por 5 agentes independentes: média 7,7, condução 6,5, recuperação 6,8, 3 críticas apontadas (1 real, 2 artefato de preparo, já corrigido no juiz); `sql/tecnicos.sql` passa; botão Pausar IA testado (`ignorada:ia_pausada`); dados de teste limpos.
- **Falta:** publicar a versão rascunho `9621c5c2-a21a-41f4-900a-e76ab72c819a` do WF2 (correções de prompt em `e2e-prompt-wf2-ciclo1.md`). A publicação foi negada pelo classificador de permissões e **depende de autorização do dono**. Depois: ciclo 2 (mesmos 70 cenários), formulações 2 e 3, e duas rodadas completas seguidas aprovadas (zero críticas, média 9 ou mais, nenhum critério abaixo de 8). Também: atualizar critérios antigos de `testes_conversa` (`e5-04`, `e5-07`, `e5-21`, `e8-fluxo-1/2`), rodar concorrência de 20 conversas e o reinício do n8n.
- **Arquivos tocados:** `tests/e2e/*`, `supabase/migrations/20261106*`, `docs/agente/e2e-*.md`, `.gitignore`, `package.json`. No n8n: só o rascunho do WF2 (nó `Agente de atendimento`, `options.systemMessage`, itens 6 a 15), sem publicar.
- **Nada foi ativado.** Estado de produção confirmado: workflows publicados, `ia_ligada = true`, mas `piloto_ativo = true`, percentual 0, um número no piloto.

**Próximo passo: Etapa 8 (auditoria e ativação).** Roteiro completo e autorização do dono em `docs/agente/etapa8-roteiro-auditoria.md`. Tudo deve ser resolvido via MCP, sem ação do dono.

## Layout consolidado do orçamento em PDF (branch `claude/brave-cori-2xq21w`)

Migration `20261106000001_orcamento_exibicao_consolidada.sql` (aditiva): `orcamentos.itens_exibicao` e `orcamentos.alternativas`, usados por `orcamento_documento`; modelo `_shared/orcamento-html.ts` ganhou o quadro de alternativas e a nota de arredondamento; testes em `scripts/test-orcamento.ts`. **Falta (depende do dono):** aplicar a migration, publicar `orcamento-pdf` (bundle em `docs/agente/funcoes/`) e preencher os dois campos no orçamento SG-0234. Detalhes em `docs/orcamento-pdf.md`.

## Conversa completa como no WhatsApp (branch `claude/brave-cori-2xq21w`)

Migration `20261106000003_mensagens_whatsapp_completo.sql` (aditiva): `messages` ganhou `reply_to_wa_id`, `raw_type`, `meta`, `forwarded`, `sent_by`, `deleted_at`, `deleted_by` e os tipos `video`, `sticker`, `location`, `contacts`, `reaction`. O webhook passa a guardar todos os tipos (o que a Meta não repassa, como mídia de visualização única e enquete, aparece com aviso claro em vez de "[mensagem não suportada]" solto). `whatsapp-send` aceita imagem, vídeo, áudio, figurinha e documento (até 16 MB), resposta a uma mensagem, reação e apagar/restaurar no CRM. Tela: citação da mensagem respondida, reações, menu da mensagem (responder, reagir, copiar, dados, apagar no CRM), arrastar e soltar, colar imagem e gravar áudio. **Limites da API oficial:** não apaga nem edita mensagem já entregue ao cliente (apagar só esconde no CRM) e a gravação de áudio depende de o navegador gravar OGG ou M4A.

## Etapa 7C: banco de conhecimento v2, personas e fila da arte (branch `feat/agente-etapa7c-conhecimento`)

**Concluída (aguarda a Etapa 8) (02/11/2026).** Detalhes: `docs/agente/conhecimento-diferencas.md`, `conhecimento-testes.md`, `docs/agente-ia.md`.

**Aplicado em produção pelo MCP do Supabase (02/11/2026):** partes 1, 2 e 3 (`etapa7c_estrutura`, `etapa7c_importacao`, `etapa7c_personas_arte`). Os 83 trechos estão ativos: a regra de proteção tratou 50 como editados (todos os antigos tinham `revisado_em` posterior à criação), então foram aceitos depois comparando o conteúdo atual com o original da carga (iguais, ou seja, sem edição do dono). 0 sugestões pendentes, 113 trechos ativos. Teste de 40 perguntas em produção (texto): 40 de 40. Vetores dos 50 últimos entram pela reindexação automática (5 em 5 minutos).
**Edge Functions publicadas:** `orcamento-pdf` (v12), `mp-criar-link` (v17) e `cliente-pago-avisar` (v2), todas com `verify_jwt` desligado. Código publicado = bundles de `docs/agente/funcoes/` sem as funções não usadas.
**n8n (tudo DESATIVADO):** WF2 usa `persona.nome` e `fase` do contexto, prompt com apresentação, regra de reembolso e uso de `arte_receber` e `arte_baixa_ok`, com as duas ferramentas ligadas; o despachante chama `public.arte_receber` e `public.arte_baixa_ok` direto (HTTP com a credencial de serviço; confira a credencial nos dois nós novos). `encaminhar_setor` não existe no n8n: o prompt manda chamar o dono por `chamar_dono`.

### O que foi feito
- 83 trechos importados com equivalência, proteção do que o dono editou, sugestões e reversão.
- Variáveis novas resolvidas na hora: `persona_vendas`, `persona_pos_pagamento`, `cupom_percentual`, `cupom_teto`, `cupom_validade_dias`, `troca_prazo`.
- Configurações > Personas e política (nomes, automático pós-pagamento, política, parcelamento, setor de arte, cupom).
- Personas: `agente_persona`, fase decidida pelo pedido; o agente não para mais depois do pagamento (chave `personas.pos_pagamento_automatico`); para só em setor de arte ou dono.
- Setor de arte: `arte_receber`, `arte_baixa_ok`, `arte_aprovar`, `arte_fila`, `arte_varredura` (a cada 15 min), tela Fila da arte, alerta ao dono com resumo.
- Aba Conhecimento: usos, última vez, filtros (categoria, revisar, uso), ordenar, perguntas sem resposta com "criar trecho", sugestões da importação.
- Política no rodapé do PDF e na descrição do link; link mostra até 12 parcelas (2x sem juros, o resto com juros do cliente).
- Cupom de recompra: teto R$ 25, não acumula com condição especial, uso único; se não couber vira arte básica grátis (continua DESLIGADO até a simulação).
- Trava de saída: endereço liberado depois do pagamento; barra "vou te reembolsar" e variações.

### O que falta (honestidade)
1. Vetores: conferir `select count(*) filter (where embedding is null) from conhecimento where ativo;` = 0 (reindexação automática).
2. n8n: WF1 não precisou mudar (repassa `contexto` com `persona`); falta teste de conversa com o modelo real antes da Etapa 8.
3. Parcelas no Mercado Pago: dono confirmou que 2x sem juros já está ligado na conta; o link mostra até 12x.
4. Cupom de recompra: continua pela lógica própria da 7B com as mesmas travas (piso, gordura, `validar_margem`), não por `calcular_condicao_especial` literalmente.
5. Aviso ao cliente na aprovação da arte: feito pela tela Fila da arte (texto livre via `whatsapp-send`, só dentro da janela de 24 h; se fechada, a tela avisa o dono).
6. Decididos pelo dono: 2x sem juros já ligado no Mercado Pago; telefone da BauerLab (+55 31 99802-1169) confirmado e a indicação NÃO alerta mais o dono.


## Pendências para a auditoria (Etapa 8), herdadas da 7B

Registradas em 01/11/2026. As funções do Mercado Pago (`mp-webhook`, `mp-conferir`, `mp-criar-link`) já foram publicadas pelo dono. A proteção contra senhas vazadas não se aplica ao plano gratuito do Supabase (risco baixo: cadastro público desativado).

**n8n (ligação e ativação)**
- Ligar ao WF2 e ao despachante as ferramentas novas: `encaminhar_setor`, `bauerlab`, `montar_opcoes` e escolha de opção; passar os campos novos de `salvar_contato` (empresa, e-mail, documento, endereço, nota fiscal, consentimento, urgência).
- Aplicar o ajuste de tom no prompt do WF2 (`docs/agente/tom-e-vendas.md`).
- WF6 consultar `recuperacao_proximo_passo`; WF7 chamar `cupom_recompra_emitir`.
- Publicar o WF9 e ligá-lo a todos os workflows `GBH |`.
- Conferir credenciais nó a nó nos 26 workflows (`docs/credenciais-n8n.md`).
- Teste de conversa que tente arrancar cada promessa indevida (pagamento, arte, produção, conclusão, data, desconto, reembolso).

**Produto**
- Painel Comercial no front (usa `painel_comercial`), workflow `GBH | WF11 | Estudo diário`, recompra por comportamento (D2).
- PDF de uma página com as 3 opções de orçamento.
- Segundo link só de Pix e indicador "digitando" do agente.

**Infra e terceiros**
- SearXNG no Coolify (`docs/infra-coolify.md`) e teste de ponta a ponta com 5 especificações.
- Bloco C: fórmula ou tabela por m² do fornecedor e pontos de preço para os itens por dimensão (`docs/agente/preco-por-dimensao.md`).
- Bloco E: Análise de app da Meta antes do `GBH | WF10` (`docs/redes-sociais.md`).

**Decisões do dono**
- Taxa real do 2x sem juros (hoje 10,50% estimado), política de troca e reembolso, parcelamento acima de 2x, benefício de indicações, telefone da BauerLab, ligar ou não o cupom de recompra (após `cupom_recompra_simular`), apagar `private.bkp_products_etapa2`.

## Etapa 7B: melhorias consolidadas (blocos A, B, C a F entregues; ver pendências)

Decisões e inventário em `docs/agente/decisoes-e-melhorias.md`. Uma branch de trabalho (`claude/compassionate-ramanujan-s26vog`) com um PR por bloco.

### Bloco A: proteger a operação (concluído, 01/11/2026)
**Aplicado em produção pelo MCP do Supabase** (migrations `20261103000001` em 3 partes e `20261103000002`; cópias em `docs/agente/aplicar-etapa7b-a.sql` e `aplicar-etapa7b-a2.sql`). Advisors sem achado novo grave.

| # | Item | Resultado |
|---|---|---|
| A1 | Taxas por método | `taxas_pagamento` ganhou crédito 2x sem juros (10,50% **estimativa conservadora**, confirmar no Mercado Pago), débito, dinheiro e transferência. O piso usa a pior taxa (`metodo_piso = cartao_credito_2x`). Taxa real (`fee_details`, líquido, parcelas) gravada no pedido por `pagamento_taxa_real` (código em `mppay.ts`, **função ainda por publicar**) |
| A2 | Taxa por dentro | Já era "por dentro" (`receita_para_lucro`). Orçamento ignora método previsto (trava na pior taxa). Tabela interna de taxa e lucro por método em Pedido > Orçamentos (só o dono) |
| A3 | Link alinhado | `installments: 2` e boleto/lotérica excluídos em `_shared/mp.ts` (**publicar mp-criar-link**). Documentado em `docs/pagamento-mercadopago.md`. Pix direto: avaliado, adiado |
| A4 | Pedido manual | Método obrigatório (criar pedido, confirmar pagamento). `confirmar_pagamento_manual` recusa sem método. Taxa só do método escolhido; dinheiro e transferência 0%. Pedidos 18 e 19 de produção (pendentes, sem método) ficam com a taxa de pior caso: **nenhuma correção necessária** (não havia pedido manual pago com taxa indevida) |
| A5 | Exclusão | `pedido_excluir` (lógica com motivo e auditoria; teste some por completo; pago nunca apaga), `pedido_cancelar_ou_arquivar` (reembolso pendente + alerta alto). Tela: Pedido > Resumo > Zona de risco. Pago após exclusão restaura o pedido e alerta |
| A6 | Atraso e urgência | `pedido_esta_atrasado`/`pedidos_atrasados` (só em produção, regra única também em `pedidoAtrasado` no front). Selo URGENTE em cartão e lista, ordena a fila, `registrar_urgencia` não muda prazo |
| A7 | Trava de lucro | `supabase/tests/trava_lucro_caminhos.sql` (preço, orçamento, condição especial, link, pedido manual, importação) + simulação em massa da Etapa 3 (`npm run test:sql`); `test-rules.ts` confere que cada caminho está coberto |
| A8 | Sigilo do fornecedor | Detector com variações de grafia, mais extensões, e varredura dos textos gravados no banco |
| A9 | Credenciais do n8n | `docs/credenciais-n8n.md`. A credencial real é `Supabase account`; "GBH Supabase (service role)" nunca existiu |
| A10 | WF9 | Tipos de erro, ação por tipo (repetir, registrar, interromper e alertar), divergência de pagamento a cada hora, simulação testada. **Ligar o WF9 aos outros workflows exige publicá-lo (ativar), então fica para a Etapa 8** |
| A11 | Segurança | Senhas vazadas continua desligada (ação do dono). Backup `private.bkp_products_etapa2`: 20.381 linhas idênticas ao catálogo, sem dependências, 3,6 MB. Comando de remoção em `depende-de-voce.md` |
| A12 | Prazo | Uma só implementação (`private.prazo_data`), usada por pedido, orçamento e `calcular_prazo`; teste de igualdade |

Testes: `npm test` e `supabase/tests/*.sql` (melhorias 71, trava 12, preço 67, orçamento 56, regressão das Etapas 1 a 7 verde).

### Bloco B: agente, conversa e conversão (concluído no banco, 01/11/2026)
**Aplicado em produção** (migrations `20261103000003` a `20261103000005`, cópias em `aplicar-etapa7b-b.sql` e `-b2.sql`). Testes: `supabase/tests/melhorias_bloco_b.sql` (58). Tom e pesquisa web em `docs/agente/tom-e-vendas.md`.

| # | Item | Resultado |
|---|---|---|
| B1 | Debounce 10 s | `agente_config.debounce_segundos = 10`. `agente_debounce` espera até 20 s a mais (teto de 60 s) se a última mensagem parece incompleta; pergunta completa responde já. **A API oficial não avisa quando o cliente digita**: documentado |
| B2 | Tom humano | `docs/agente/tom-e-vendas.md` + trecho `tom-vendedor` no conhecimento. **O prompt do WF2 não foi alterado** (ver pendências) |
| B3 | Dados e CRM | `agente_salvar_contato` aceita empresa, e-mail, documento e endereço (só com nota fiscal ou entrega), devolve `falta`, consentimento de promoções em pergunta separada (data e origem `whatsapp`, nunca reverte `opted_out`), urgência |
| B4 | Pix primeiro, parcelamento | Conhecimento atualizado (`pag-formas`, `pag-pix`, `pag-parcelar`, `pag-nf`, `troca-politica` com `[CONFIRMAR]`) |
| B5 | Três opções | `montar_opcoes` (até 3 do mesmo grupo, margem validada no pior caso, diferenças reais), `orcamento_opcao_escolher`, view `opcoes_conversao`. **PDF de uma página com as 3 opções: não feito** |
| B6 | Setores | `conversations/tasks/alertas.setor`, `agente_encaminhar_setor` (comercial, arte, financeiro com resposta do sistema, dono com resumo, histórico, motivo e ação recomendada) |
| B7 | Promessas indevidas | `agente_promessas_indevidas` dentro de `agente_saida_segura`: pagamento, arte aprovada, produção, conclusão, data não dada, desconto fora da função e reembolso; 12 testes |
| B8 | Google e cupom | Avaliação sem benefício (trecho `google-avaliacao`). Cupom de recompra 5% incondicional **desligado**, com `cupom_recompra_simular`; não ligue antes de ver a simulação |
| B9 | Motivo da perda | `orcamentos.motivo_perda`, `estrategia_recuperacao` (condição especial sempre por último), `recuperacao_proximo_passo` (respeita optout). **WF6 ainda não consulta a função** |
| B10 | BauerLab | `agente_bauerlab` (uma vez, alerta baixo), `oportunidades_bauerlab`, config em `app_settings.bauerlab` (telefone **a confirmar por você**) |
| B11 | Validador | `pedido_pendencias` (cliente, itens, SKU, preço aprovado, pagamento, prazo, arte) |

**Ligação ao n8n (PARCIAL, honestidade):** as funções do banco estão prontas e testadas, mas o WF2 ainda não expõe ao modelo as ferramentas novas (`encaminhar_setor`, `bauerlab`, `montar_opcoes`, escolha de opção) nem os campos novos de `salvar_contato`, e o WF6/WF7 não chamam `recuperacao_proximo_passo` nem `cupom_recompra_emitir`. A trava de promessas, o debounce e o conhecimento já valem sem mudar o n8n. Editar o WF2 (26 nós) e o despachante fica para a Etapa 7C/8, com teste de conversa.

### Blocos C a F (01/11/2026): estrutura pronta, partes que dependem de você ou de terceiros ficam registradas
**Aplicado em produção** (migration `20261103000006`, cópia em `aplicar-etapa7b-cd.sql`). Testes: `supabase/tests/melhorias_bloco_cd.sql` (21).

- **C (preço por dimensão):** `catalogo_formulas` e `private.custo_por_dimensao` (só com fórmula validada, erro até 1%; sem ela não há oferta definitiva). Não consegui investigar o fornecedor (precisa do seu login e dos termos de uso). Passo a passo em `docs/agente/preco-por-dimensao.md`. O workflow de consulta automatizada **não foi criado** de propósito.
- **D (inteligência):** `painel_comercial` (cinco grupos de indicadores), `atribuicao_pedidos`, `rentabilidade_cliente` (só o dono), `produtos_complementares` + `complementar_sugerir`, `melhorias_sugeridas` (alvo crítico exige autorização, garantido por constraint) + `estudo_diario_coletar`, `experimentos` (só texto e momento; amostra pequena nunca declara vencedor), indicações (`indicacao_codigo`, `indicacao_registrar`, compra válida automática, **sem recompensa**). Definições em `docs/metricas.md`. **Faltam:** o painel Comercial no front, o `GBH | WF11 | Estudo diário` no n8n e a recompra por comportamento (D2), que continuam no backlog.
- **E (redes sociais):** Postiz lista Facebook, Instagram e Threads, mas só publica. Webhook de comentário exige Análise de app da Meta: `GBH | WF10` não foi implementado; roteiro em `docs/redes-sociais.md` e `docs/backlog.md`.
- **F (infra):** a VPS não aceita o gerenciador de Docker da Hostinger (Docker é do Coolify), então não instalei o SearXNG. Passo a passo em `docs/infra-coolify.md`. O teste de ponta a ponta com 5 especificações ficou pendente.

## Etapas concluídas

- Etapa 1: Fundação (PR mesclado, aplicada em produção).
- Etapa 2: **concluída** (PR #22 mesclado, aplicada em produção em 28/10/2026).
- Etapa 3: **concluída** (PR #24 mesclado, aplicada em produção em 28/10/2026).
- Etapa 4: **concluída e testada em produção** (29/10/2026). Banco (migrations 09 a 12), função `orcamento-pdf` e `mp-criar-link` publicadas pelo painel, Gotenberg no ar. PDF SG-0033 enviado e recebido no WhatsApp com o nome `Orcamento-SG-0033-29-10-2026.pdf`; segundo envio devolveu `ja_enviado` (sem mensagem duplicada). Pendente só para a auditoria final: botão Reenviar do CRM (ver abaixo).

- Etapa 4B: **concluída** (fotos de produto, aplicada em produção em 01/11/2026).
- Etapa 6: **concluída** (alertas, PWA e pós-pagamento, aplicada em produção em 01/11/2026; falta o teste no seu iPhone).
- Etapa 7: **concluída** (01/11/2026): banco e função publicados, workflows criados e desativados; falta a ativação (Etapa 8) e a ligação do WF9.
- Etapa 5: **concluída e validada** (agente WF1 e WF2, 01/11/2026). Migrations 01 a 03 aplicadas em produção; **21 de 21 cenários passam** com o modelo real; workflows desativados; funções Edge ainda por publicar (ver `depende-de-voce.md`).

## Etapa 7: follow-ups, pós-venda, status do pedido, painel de pedidos e observabilidade (concluída, 01/11/2026)

Branch da sessão `claude/magical-tesla-auylwy` (a pedida era `feat/agente-etapa7-followup-status`). Detalhes e decisões em `docs/agente-ia.md` (seção Etapa 7).

### O que foi feito e já está em produção
- **Banco** (migration `20261102000001`, aplicada em 3 partes pelo MCP; cópia em `docs/agente/aplicar-etapa7.sql`): `pedido_avisos`, colunas novas, 18 funções (`followup_*`, `pedido_*`, `recompra_*`, `fornecedor_*`, `agente_erro_registrar`, `observabilidade_checar`, `painel_agente`), gatilhos de subestatus e de entrega. Advisors de segurança sem achados novos graves (as funções novas seguem o padrão "executável por logado, conferem o dono por dentro"; as do n8n são só da service role).
- **Edge Function** `proativo-enviar` publicada (versão 1, só service role).
- **n8n** (pasta Sua Gráfica BH, tag `gbh`, desativados, exportados em `n8n/`): `GBH | WF6 | Follow-ups` (`ueCyozWur9Y5gs9c`), `GBH | WF7 | Pós-venda e recompra` (`OBHE31bWohDs2fQ4`), `GBH | WF8 | Status do pedido` (`h6Lviy09RV1coW6v`), `GBH | WF9 | Erros e observabilidade` (`vmaMVnZydmHpkW57`) e `GBH | FERRAMENTA | enviar_proativo` (`gZsE7enJOnpex8xv`). WF6, WF7 e WF8 foram executados uma vez em modo manual contra o banco de produção (fila vazia): credenciais e chamadas OK.
- **CRM**: página Pedidos, subestatus e avisos no cartão e no detalhe do pedido, Configurações > Follow-ups, Painel > Agente.
- **Testes**: `supabase/tests/followup_etapa7.sql` (**96 passam**) com cadência completa com e sem condição, janela aberta e fechada, `optout`, caçador, condição expirada, pagamento no meio, modo humano, IA pausada, horário, limite diário, falhas e tentativas, pós-venda, recompra, avisos de status, lista do fornecedor e observabilidade; regressão das Etapas 1, 3, 4, 5 e 6 verde; `npm test` (inclui `test:proativo`), typecheck e build verdes.

### O que NÃO foi feito (honestidade)
- **WF9 não está ligado aos outros workflows**: o n8n exige o fluxo de erro publicado e a regra é não ativar nada antes da Etapa 8. Fica para a ativação (publicar o WF9 e ligar nos 27 workflows `GBH |`).
- **Nenhum envio real** foi feito à Meta (nem a ninguém): a IA está desligada em produção e a lógica foi testada em SQL; `proativo-enviar` não foi executada contra a Meta (sem Deno aqui). Os templates 4 a 11 ainda precisam estar aprovados na Meta (a função recusa template não aprovado e tenta de novo).
- As telas novas passaram em typecheck e build, mas não foram conferidas no navegador com dados reais (ainda não há pedidos em Produção nem entregues).
- `whatsapp-webhook` com as novas palavras de descadastro ("não quero mais", "pare"): **foi republicado em 01/11/2026 (versão 29)**.
- Custos de template do painel são estimativas.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/followup_etapa7.sql supabase/tests/agente_etapa5.sql supabase/tests/alertas_etapa6.sql
```
No CRM: Pedidos, Painel > Agente, Configurações > Follow-ups; em um pedido pago em Produção, os botões Pronto, Saiu e Entregue.

## Etapa 6: alertas ao dono, PWA e confirmação de pagamento (concluída, 01/11/2026)

Branch `feat/agente-etapa6-alertas-pwa`. Detalhes e passo a passo do iPhone em `docs/pwa-e-notificacoes.md`.

### O que foi feito
- **Passo 0:** o CRM não tinha manifest, service worker nem push; `alertas` existia só como tabela e `chamar_dono` era um stub; "Marcar como pago" e o webhook já passavam por `private.confirmar_pagamento` (um só caminho) e gravavam `pagamento_confirmado`. Estendi tudo isso, sem recriar o pagamento.
- **Aplicado em produção (autorizado pelo dono):** migration `20261101000004` em 6 partes (`etapa6_alertas_push_parte1` a `5` e `etapa6_bloqueio_numero_do_dono`; o arquivo do repositório é a mesma coisa em um só), Edge Functions `alertas-enviar` e `cliente-pago-avisar` publicadas pelo conector (versão enxuta, sem comentários; o código completo está em `supabase/functions/` e em `docs/agente/funcoes/*.bundle.ts`). Advisors de segurança sem achados novos.
- **n8n (MCP, desativados, tag gbh, pasta Sua Gráfica BH):** `GBH | WF5 | Pagamento e alertas` (`rLER5HoORdxVy0S0`) e `chamar_dono` real (`TwvgUc15htbWkyDu`). Exportados em `n8n/`.
- **Testes:** 48 casos SQL novos (`alertas_etapa6.sql`), regressão das Etapas 1, 4 e 5 verde (54, 55 e 101), `npm test`, typecheck e build verdes.

### Decisões
- Fila única `alertas` com status por canal; gravidade baixa fica `agrupado` e sai no resumo de 2 h; "nova mensagem em modo humano" é só popup por padrão (WhatsApp ligável).
- Chaves VAPID: segredos de ambiente, ou geradas pela função e guardadas em `app_segredos` (assim você não precisa configurar nada).
- O agente nunca responde o número do dono (`numero_do_dono`), para o dono poder responder os alertas sem virar "cliente".
- WF5 por fila a cada minuto, com Database Webhook opcional para aviso imediato.

### O que NÃO foi feito (honestidade)
- **Teste real no iPhone:** não tenho o aparelho. Falta você instalar o PWA, ativar e tocar em "Enviar notificação de teste" (passo a passo no doc). O envio Web Push e o WhatsApp reais não foram executados daqui (sem Deno e sem acesso ao aparelho); a lógica foi testada em Node e em SQL e as funções estão publicadas.
- A simulação de pedido pago e do `chamar_dono` de ponta a ponta contra o WhatsApp só acontece com os workflows ativos (Etapa 8). Os 48 testes SQL cobrem o banco inteiro dessas duas rotas.
- Não existe `GBH | WF9 | Erros` na instância; os workflows novos não têm fluxo de erro global ainda.

### Pendências (dono)
1. Instalar no iPhone e fazer o teste (doc). 2. Opcional: Database Webhook para aviso imediato. 3. Ativação dos workflows só na Etapa 8.

## Etapa 5: o agente de atendimento (pronta para revisão, 01/11/2026)

Branch de trabalho da sessão `claude/admiring-einstein-apt8ei` (a pedida era `feat/agente-etapa5-agente`). **Atualização:** migration aplicada em produção em 01/11/2026 (autorizada). Funções Edge ainda não publicadas, workflows desativados. Detalhes em `docs/agente-ia.md` (seção Etapa 5) e testes em `docs/agente/etapa5-testes.md`.

### O que foi feito
- **Passo 0:** o receptor da Meta (`whatsapp-webhook`) já gravava a mensagem de forma atômica e idempotente; conversa nova nasce em modo humano; origem do anúncio já ficava em contato e conversa. Não criei outro webhook na Meta: o receptor passou a avisar o n8n com o id da mensagem.
- **Banco** (migration `20261101000001`, cópia em `docs/agente/aplicar-etapa5.sql`): `agente_execucoes` e 23 funções `agente_*` (ignorar sem chamar o modelo, debounce, trava por conversa, contexto enxuto, trava de saída, loop de ferramentas, tetos de tokens com alerta, primeiro contato, follow-up, modo de teste com avaliação automática) e 21 cenários.
- **Edge Functions:** `agente-enviar` (nova), `whatsapp-webhook` (gancho para o WF1) e `whatsapp-media` (aceita service role). Bundles em `docs/agente/funcoes/`.
- **n8n (MCP, desativados, tag gbh, pasta Sua Gráfica BH):** `GBH | WF1 | Entrada e roteamento`, `GBH | WF2 | Agente` (AI Agent Gemini com 11 ferramentas), `GBH | FERRAMENTA | despachar` e 6 ferramentas novas. Ver `docs/n8n-mapa.md`.
- **Testes:** 96 testes SQL passam, regressão das etapas 1 a 4B passa, `npm run test:agente` passa, e o despachante, o WF1 e o WF2 foram testados no n8n com os nós de rede fixados.

### Decisões
- **Despachante único** (`GBH | FERRAMENTA | despachar`): as 11 ferramentas continuam sub-workflows `GBH | FERRAMENTA | nome`, mas o WF2 as chama por um ponto só, que aplica loop, limpeza de custo e SKU, registro, aviso ao dono na falha e a conversa e o contato fixos (o modelo nunca escolhe).
- **Trava de saída em SQL** (`agente_saida_segura`): testável e única. Bloqueia vazamento e qualquer R$ que nenhuma ferramenta devolveu.
- **Tokens e custo são estimativas** (o n8n não expõe o uso real do Gemini): caracteres ÷ 3,5, marcado como estimativa no log.
- **Transcrição de áudio com Groq `whisper-large-v3-turbo`**, a opção mais barata já disponível na instância (cerca de R$ 0,002 por áudio de 1 minuto).
- **A IA assume o primeiro contato** de conversa nova (o CRM nasce em modo humano) e retoma quando o cliente responde um follow-up.
- Sem validação real do token do webhook (limitação do n8n sem variáveis de ambiente); a URL do webhook é longa e imprevisível e a rodada é idempotente. Ver `docs/n8n-mapa.md` para endurecer.
- `data_atual` (opcional) não foi criada: data e hora vão no prompt.

### O que NÃO foi feito (honestidade)
- **Os 21 cenários rodaram com o modelo real e passam** (relatório e custo médio em `etapa5-testes.md`). Para isso os 13 sub-workflows foram publicados só durante o teste (o `toolWorkflow` do n8n exige o sub-workflow publicado) e despublicados no fim. Na Etapa 8 será preciso publicar o despachante e as ferramentas junto com WF1 e WF2.
- Modelos: `gemini-3-flash-preview` (padrão) e `gemini-3.1-pro-preview` (forte); `gemini-2.5-flash` e `gemini-3-pro-preview` dão 404 na conta.
- A trava de saída não confere fatos numéricos soltos (ex.: "a partir de 100 unidades"), só R$ e vazamentos.
- Áudio (download e Groq), `agente-enviar` e o gancho do webhook não foram executados contra a Meta (sem Deno aqui; lógica testada em Node e SQL).
- Os JSONs dos 9 workflows desta etapa (WF1, WF2, despachante e 6 ferramentas) **não foram exportados para `n8n/`**: o retorno do MCP chega a mais de 100 KB e retranscrever à mão arrisca corromper o fluxo. Eles estão salvos no n8n (versionados) com os IDs de `docs/n8n-mapa.md`. Para exportar: n8n > workflow > Download, ou pedir a exportação em uma sessão com acesso à API do n8n.
- Edge Functions `agente-enviar`, `whatsapp-media` e `whatsapp-webhook` (com o gancho do agente) **publicadas**. Os segredos `N8N_WF1_URL` e `N8N_WF1_TOKEN` ficam para a Etapa 8: sem eles o webhook se comporta como antes.
- O prompt tem cerca de 890 tokens fixos (alvo de 700).

### Pendências (dono)
Ver `docs/agente/depende-de-voce.md`, seção Etapa 5.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/agente_etapa5.sql
```
Depois de aplicar: cenários de `docs/agente/etapa5-testes.md`.

## Etapa 4B: fotos de produto (pronta para revisão, 01/11/2026)

Branch de trabalho da sessão `claude/fervent-hawking-h6vgqf` (a pedida era `feat/agente-etapa4b-fotos`). Nada aplicado no Supabase, nenhuma função publicada, nenhum workflow ativado. Detalhes em `docs/fotos-de-produto.md`.

### O que foi feito
- **Passo 0:** o CRM não guardava imagens de produto. A origem (site público de terceiros, interna) tem `robots.txt` liberado e não tem página de termos de uso; páginas de categoria com 36 cartões, link terminando no SKU e imagem de até 1000 px.
- **Banco** (migrations `20261030000001` e `…02`, juntas em `docs/agente/aplicar-etapa4b.sql`): `produto_fotos`, `produto_fotos_grupos`, `produto_fotos_envios`, bucket privado `produto-fotos`, `app_settings.fotos`, 10 funções em `public` (a service role não alcança `private`), trecho de conhecimento `foto-produto`.
- **Edge Function `produto-fotos`** (bundle em `docs/agente/funcoes/`): busca na origem (1 req/s, 15 s, User-Agent identificável), reduz a 1000 px, JPEG sem metadados (meta 150 KB, teto 300 KB, descarta menor que 300 px), verificação de marca com modelo de visão (falha fechada), envio de imagem no WhatsApp, limites (3 por pedido, 1 pedido por minuto por conversa, 10 imagens por contato por dia), alerta de gravidade baixa quando não há foto, log sem origem.
- **CRM:** Catálogo > Fotos (aprovar, bloquear, trocar, buscar de novo, filtros "Para revisar" e "Sem foto", campo interno da origem, chave do aquecimento).
- **n8n (MCP, desativados, tag gbh, exportados em `n8n/`):** `enviar_foto_produto` (`ybnd6LjGjUO8dgTI`) e `Aquecer fotos de madrugada` (`MYEmz3rCIfhMhxxF`, opcional, desligado).
- **Testes:** `scripts/test-fotos.ts` (entra no `npm test`), `supabase/tests/fotos_etapa4b.sql` (**25 passam**), Etapas 1 a 4 contra o schema novo (54, 82, 67 e 55 passam), `npm test`, typecheck e build verdes. Teste real com 15 grupos: ver abaixo.

### Ajuste pedido pelo dono (01/11/2026): todo produto precisa de foto
- Varredura de todo o menu da origem (152 categorias): 26.639 itens, 18.808 códigos. Os 125 grupos do catálogo têm categoria equivalente (100% por grupo); por SKU, cerca de 90% com imagem própria (estimativa; o cruzamento exato sai na tela de Cobertura).
- Fotos pequenas (miniaturas) agora são aceitas, ampliadas e marcadas como baixa qualidade; o agente nunca diz ao cliente que não há foto.
- Migration `20261030000003` (mapa código -> imagem, candidatas, cobertura), ação `varrer` na função, botão "Mapear origem" na tela, `scripts/fotos-mapear-origem.ts` e `scripts/fotos-catalogo-pdf.ts` (reserva pelo PDF, 1.051 imagens extraídas no teste).
- 38 testes SQL de fotos passam.
- **Aplicado em produção em 01/11/2026 (autorizado pelo dono):** migrations da 4B (aplicadas pelo dono), função `produto-fotos` publicada pelo conector (versão 2; o pacote npm do `imagescript` não roda no Supabase, a função usa a versão Deno `deno.land/x/imagescript@1.3.0`), `app_settings.fotos.origem_base` preenchido, workflow `GBH | WF4 | Mapear fotos da origem` (`iLpTZUm9VLqNLXX1`) executado manualmente no n8n para gravar o mapa. Workflows seguem desativados.

### Decisões
- Domínio da origem fora do repositório: o `npm test` proíbe o nome do fornecedor em qualquer arquivo e o domínio contém esse nome. Fica em `app_settings.fotos.origem_base` (preenchido pelo dono) e o teste real recebe por variável de ambiente.
- Processamento na Edge Function (não no nó de imagem do n8n) para servir agente, tela e aquecimento com o mesmo código testado.
- Imagem sem verificação de marca fica pendente e nunca é enviada (falha fechada).

### O que NÃO foi feito (honestidade)
- A Edge Function não foi executada (sem Deno aqui), nem testada contra a Meta, o Storage real ou o modelo de visão; só a lógica pura e o processamento de imagem foram testados em Node com imagens reais.
- Os workflows foram validados, não executados (gatilho "Execute Workflow" não roda pelo MCP).
- Envio real de imagem e verificação de marca ficam para a auditoria da Etapa 8.

### Pendências (dono)
Ver `docs/agente/depende-de-voce.md`, seção Etapa 4B.

## Etapa 4: orçamento em PDF (concluída, aplicada em produção em 29/10/2026)

Branch `feat/agente-etapa4-orcamento`. Aplicado: migrations `…09` e `…10`, função `orcamento-pdf` (pelo painel, com o arquivo `docs/agente/funcoes/orcamento-pdf.bundle.ts`) e Gotenberg em `gotenberg.bauerlab.com.br`. Nenhum workflow do n8n foi ativado. Ajustes pedidos pelo dono no teste: página mais bem preenchida (passos "Como fechar seu pedido") e nome do arquivo `Orcamento-SG-0032-29-10-2026.pdf`. Detalhes em `docs/orcamento-pdf.md`.

### O que foi feito
- **Passo 0:** o CRM já tinha `orcamentos` e `orcamento_itens` (Etapa 1) e nenhum gerador de PDF de orçamento (só leitura de PDF do catálogo). Estendi as tabelas e unifiquei tudo no padrão novo. O trabalho da sessão interrompida nessa branch (migration com número repetido, funções sem autenticação que aceitavam piso e custo do chamador, provedor de pagamento genérico) foi **substituído**: removi os arquivos e arquivei no n8n os 4 workflows antigos.
- **Banco** (migration `20261029000009_etapa4_orcamento_pdf.sql`, aditiva e idempotente): `montar_orcamento` (preço, prazo, frete, arte, upsell por regra, `validar_margem`), `orcamento_documento` (só dados públicos + hash), `orcamento_renovar`, `preparar_link_pagamento`, `orcamento_registrar_link`, `validar_antes_de_cobrar` olhando a margem do orçamento, bucket privado `orcamentos`, colunas novas e tempo real em `orcamentos`.
- **Taxa do método e lucro real:** `validar_margem` já descontava a taxa do método previsto (Pix 0,99%, cartão 4,98%); agora, quando o pagamento chega, `confirmar_pagamento` grava a taxa real e o lucro líquido real no pedido (`taxa_pagamento_real_pct`, `lucro_liquido_real`) e passa o orçamento para `pago`.
- **PDF:** modelo HTML em `supabase/functions/_shared/orcamento-html.ts` (logo, paleta e Inter do CRM); Edge Function `orcamento-pdf` (Gotenberg, Storage, envio no WhatsApp, idempotente, vencido gera novo, trava de lucro antes de enviar). Infra em `infra/gotenberg/`.
- **n8n (MCP, desativados, tag gbh, exportados em `n8n/`):** `montar_orcamento`, `gerar_pdf_orcamento`, `gerar_link_pagamento`, `GBH | WF3 | Orçamento PDF`; o gancho de PDF de `condicao_especial` virou chamada real.
- **CRM:** Pedido > aba Orçamentos (número, status, valor, validade, margem, regra e confiança só do dono, abrir PDF, Enviar/Reenviar) e status do orçamento no cartão do kanban.
- **Exemplos:** 6 PDFs em `docs/exemplos-orcamento/` (catálogo fictício). Conferidos em tamanho de papel (A4) e de celular (390 px) e por texto: nenhum tem SKU, custo, margem, piso, fornecedor nem endereço de retirada; todos com 1 página e menos de 200 KB.
- **Testes:** `supabase/tests/orcamento_etapa4.sql` (**49 passam**), Etapas 1, 2 e 3 contra o schema novo (54, 82 e 67 passam), `npm test` (inclui `scripts/test-orcamento.ts`), typecheck e build verdes.

### Correção pós-aplicação (29/10/2026)
O banco de produção já tinha colunas da migration antiga da sessão interrompida (`orcamentos.avisos` e `orcamento_itens.especificacao` como `jsonb`), então `montar_orcamento` falhou com 42804. A migration `20261029000010_etapa4_compat_banco.sql` define o formato final (`avisos` jsonb, `especificacao` text), remove duas views sobras dessa tentativa e recria `montar_orcamento`. Testado em banco limpo e em banco com a migration antiga aplicada antes (49 + 67 + 54 + 82 passam). O erro foi reproduzido sem a correção.

### Correção 2 (29/10/2026, achada no teste de envio)
Nas Edge Functions a service role não alcança o schema `private`: `validar_margem` direto e a troca de status para `enviado` (trigger de lucro) falhavam com `permission denied for schema private`, e a função respondia "recusado pela trava de lucro" sem motivo. A migration `20261029000011` cria `orcamento_validar_margem` e `orcamento_marcar_enviado` (definer, só dono ou servidor) e a função passou a usá-los. Os testes locais rodam como administrador e não pegavam isso; agora há testes com `set role service_role` (51 passam). Lição: testar com o papel `service_role` sempre que uma Edge Function ou o n8n chamar uma função do banco.

### Regra do dono: entrega sem "bicicleta" (29/10/2026)
Para o cliente, a entrega grátis na região central é só "entrega grátis na região central, em horário comercial". A migration `20261029000012` troca os textos do orçamento e da ferramenta de frete, o código interno `bike_gratis` (o agente recebe `entrega_gratis`) e 4 trechos do conhecimento; o PDF e o seed foram ajustados e há testes que impedem a palavra. **Para a Etapa 5:** o prompt e os filtros do agente não podem citar bicicleta nem bike (`verificar_frete` ainda devolve campos internos como `cabe_na_bike` e `entrega_sugerida: bike`; o wrapper da ferramenta deve filtrar).

### Decisões
- O PDF é renderizado dentro da Edge Function (não no n8n) para o botão Reenviar do CRM funcionar sem o n8n e para o modelo ficar versionado e testado no repositório. O WF3 orquestra.
- O pedido (que o Mercado Pago cobra) nasce do orçamento na hora do link; arte entra como item "Criação de arte" (fora do catálogo, custo zero) e desconto vira `discount_pct` arredondado para baixo. Se um pedido já existente tiver valor diferente do orçamento, o link é recusado.
- Frete por Uber é por conta do cliente: não entra no total nem vira custo nosso. Entrega de bicicleta (grátis) entra como custo nosso no lucro.
- Texto livre nunca vira item: só SKU e quantidade. SKU e custo nunca saem para o agente.
- Os erros de preço (mercado abaixo do piso, `nao_competitivo`) ficam só nos campos protegidos do banco; o agente recebe só avisos públicos.

### O que NÃO foi feito (honestidade)
- **A identidade visual da pasta no seu computador (`G:\Meu Drive\...\SUA_GRAFICA_BH_BRANDKIT`) não estava acessível** a esta sessão (é uma pasta do Windows e o CRM roda em nuvem). Usei a paleta, o logo (mesmo do favicon) e a fonte Inter que o CRM já tem, que foram tirados do brand kit na Parte 1. **Compare um PDF de exemplo com o brand kit** (cores, fonte, logo) e me diga o que ajustar; é só o CSS do modelo.
- Gotenberg **não foi instalado** e a Edge Function não foi testada contra ele nem contra a Meta (sem acesso). Os PDFs de exemplo foram gerados com o Chromium local, o mesmo motor do Gotenberg.
- Os workflows do n8n foram validados pelo MCP, mas **não executados** (o gatilho "Execute Workflow" não roda pelo MCP). A lógica de preço, prazo, frete e travas foi testada no banco.
- Instagram (`@suagraficabh`) e site (`suagraficabh.com.br`) entram em `app_settings.company` por SQL (ver `depende-de-voce.md`); o PDF mostra só o que existir.

### Teste em produção (29/10/2026)
- Orçamento de teste criado por `montar_orcamento`, PDF gerado no Gotenberg (`gotenberg.bauerlab.com.br`), guardado no bucket privado, enviado como documento no WhatsApp a um número de teste (janela de 24 h aberta), recebido certinho. Segunda chamada de `enviar`: `ja_enviado: true`, sem mensagem repetida. `preparar_link_pagamento`: `ok` (pedido criado, valor igual ao do orçamento, link válido por 47,9 h). Chip "Orç. enviado" apareceu no cartão do kanban. Dados de teste apagados.
- **Para a auditoria final (Etapa 8):** testar o botão **Reenviar** na aba Orçamentos do pedido; testar `gerar_link_pagamento` ponta a ponta no n8n com o Mercado Pago em modo teste; republicar `mp-conferir` e `conhecimento` com o ajuste de autenticação da service role (hoje só `orcamento-pdf` e `mp-criar-link` têm); atribuir a credencial do n8n aos workflows da Etapa 3; sempre testar chamadas de função com o papel `service_role`.

### Pendências (dono)
Ver `docs/agente/depende-de-voce.md`, seção Etapa 4 (todas feitas em 29/10/2026, menos o que está em "Para a auditoria final" acima). Resumo: aplicar a migration (`docs/agente/aplicar-etapa4.sql`), rodar o teste SQL e os advisors, instalar o Gotenberg, criar os segredos `GOTENBERG_*`, publicar `orcamento-pdf`, atribuir a credencial do Supabase nos nós HTTP dos 4 workflows, conferir o PDF contra o brand kit e confirmar o prefixo do número do orçamento.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/orcamento_etapa4.sql supabase/tests/preco_etapa3.sql supabase/tests/agente_etapa1.sql supabase/tests/catalogo_etapa2.sql
npm run exemplos:orcamento -- docs/exemplos-orcamento     # refaz os 6 PDFs (Postgres local no ar)
```
No CRM (depois de aplicar): abra um pedido > aba Orçamentos > Enviar; o cartão do kanban mostra o status do orçamento.

## Etapa 3: preço inteligente e condição especial (concluída, aplicada em produção em 28/10/2026)

Branch de trabalho da sessão: `claude/etapa3-preco-desconto-julfis` (parte de `feat/agente-etapa3-preco`, que tinha o início do trabalho). Nada foi aplicado no Supabase, nada foi ativado no n8n, nada foi instalado no servidor.

### O que foi feito
- **Passo 0:** todo ponto que exibe ou grava preço foi listado e classificado em `docs/agente/mapa-crm.md` (seção 7). Tudo o que vai para cliente, orçamento, PDF ou link lê `calcular_preco`; o resto ficou rotulado "base de custo, sem pesquisa".
- **Banco** (migrations `20261029000006` e `20261029000007`, juntas em `docs/agente/aplicar-etapa3.sql`): cache e consultas de mercado, `fontes_pesquisa` (robots, termos e intervalo por domínio), `registrar_pesquisa_mercado` (outliers por desvio absoluto, mediana, confiança), `calcular_preco` com mercado, fator por grupo, âncora de vendas (3 ou mais em 90 dias, limitada pelo mercado), `nao_competitivo` e trava final no piso duro; `agente_preco` com orientação para o agente; `precos_praticados` alimentado por trigger; `aprender_precos_semana`; `oferecer_condicao_especial` (orçamento atualizado, pedido ligado, tudo ou nada), expiração com `pg_cron`, detector de caçador e de padrão incomum, relatório e resumo semanais, política com `simular_politica_desconto` e `salvar_politica_desconto`, edição manual de preço com piso duro e confirmação (`definir_preco_item_pedido`, `precos_manuais_log`), `skus_para_aquecer`. `aplicar_desconto` não existia no repositório nem no banco; o `drop` está na migration por segurança.
- **n8n (MCP):** 4 workflows criados na pasta Sua Gráfica BH, desativados e exportados em `n8n/` (ver `docs/n8n-mapa.md`). Lógica testada no n8n com dados simulados nos nós de rede.
- **Infra:** `infra/searxng` e `infra/renderer` prontos, com passo a passo em `docs/agente/infra-busca.md`.
- **CRM:** Catálogo > Saúde de preços completa (cobertura, margem, conversão, fator por grupo, fontes de cada preço, itens não competitivos, condições, resumo semanal, ajustes); Configurações > Política de desconto com simulação do pior caso e grupos sem desconto; pedido com lucro líquido, bloqueio e confirmação do dono ao editar preço.
- **Testes:** `supabase/tests/preco_etapa3.sql` (**67 passam**, inclui a simulação de **1.000 combinações sem nenhuma violação**), Etapas 1 e 2 contra o schema novo (54 e 82 passam), `npm test`, typecheck e build verdes. Relatório em `docs/agente/etapa3-validacao.md`.

### Decisões
- Fonte prioritária (alfacards.com.br): `robots.txt` libera, **não há página de termos** (ficou `termos_ok` vazio até o dono confirmar) e o preço só aparece com JavaScript e só para as opções padrão. Cobertura esperada baixa; as outras fontes e o cache completam.
- Mercado com 1 fonte é usado com confiança baixa e aviso; com 0 fontes vale a fórmula de custo.
- Aprendizado conta só orçamentos **encerrados** (ganho, perdido, expirado) dos últimos 30 dias, sem os de teste; o orçamento atualizado por condição conta como o original.
- A condição que levaria o orçamento atualizado a ser recusado pela trava de lucro vira "sem condição"; o agente nunca vê o motivo.
- Meta de margem do aprendizado: 20% (`meta_margem_liquida_pct`, para você revisar).
- O workflow de condição devolve o orçamento atualizado e o link novo; o **PDF** fica para o gancho da Etapa 4.

### Pendências
- Dono: aplicar `docs/agente/aplicar-etapa3.sql`, rodar `supabase/tests/preco_etapa3.sql` e os advisors, instalar a busca no Coolify, criar as credenciais no n8n, confirmar os termos de uso do concorrente (`docs/agente/depende-de-voce.md`).
- Etapa 4: PDF do orçamento atualizado e gravar nos itens do orçamento a fonte do mercado (`consulta_mercado_id`, `mercado_mediana`, `fontes_mercado`, `nao_competitivo`, `piso`, `piso_duro`, `lucro_liquido`, colunas já criadas).
- Etapa 5: mensagem curta de espera durante a pesquisa e G1 no WF2. Etapa 7: G2 e G3 nos follow-ups.
- `GBH | WF9 | Erros` ainda não existe (etapa 7/8); os workflows já usam retentativas e `continueRegularOutput`.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/preco_etapa3.sql supabase/tests/agente_etapa1.sql supabase/tests/catalogo_etapa2.sql
psql -h /tmp -p 54329 -U postgres -d gbh -f supabase/tests/tabela-etapa3.sql    # tabelas da validação
```
No CRM (depois de aplicar): Catálogo > Saúde de preços; Configurações > Política de desconto (mude um percentual e veja a simulação); Pedido > Itens (mude o preço de um item abaixo do piso).

## Etapa 2: Catálogo com SKU e banco de conhecimento (concluída, 28/10/2026)

### Aplicação em produção e fechamento (28/10/2026)
- Backup antes: cópia das 20.381 linhas em `private.bkp_products_etapa2` (área privada; apague quando quiser).
- Migrations 15 a 19 aplicadas pelo SQL Editor (`docs/agente/aplicar-etapa2.sql`). Conferido: `catalogo` com as mesmas 20.381 linhas, todas com piso calculado; `products` virou visão; CFV02 = R$ 75,99; 90 trechos; 12 perguntas no cache; 40 sinônimos; bucket `catalogo-fornecedor` privado; agendamento `conhecimento-reindexar` a cada 5 minutos; SKU obrigatório ligado.
- Edge Function `conhecimento` publicada (sem JWT; confere dono, service role ou `x-cron-secret`). Vetores `gte-small` funcionando (20 por rodada de 5 minutos, os 90 ficam prontos em cerca de 20 minutos).
- Segurança em produção: `anon` sem privilégio em `catalogo`, `products_priced`, `catalogo_importacoes` nem nas funções novas; RLS ligada em todas as tabelas novas; `buscar_produto` e `agente_preco` testadas com dados reais sem custo, piso, margem, lucro ou fornecedor na resposta.
- Advisors de segurança: nenhum alerta novo grave. As funções novas aparecem em "executável por usuário logado" por desenho (cada uma confere a permissão por dentro). Seguem os 2 antigos: `rls_auto_enable` executável por `anon` (função do próprio Supabase) e proteção contra senhas vazadas desligada no Auth.
- **A tabela do fornecedor passou a ser só Excel** (não mais PDF). A pré-visualização da importação mostrou que a planilha é **idêntica ao catálogo atual**: 20.381 linhas lidas, 20.381 iguais, 0 novas, 0 alteradas, 0 sem código, 0 conflitos, 0 rejeitadas, 0 removidas, CFV02 = R$ 75,99. Não havia nada a aplicar; a importação foi fechada como cancelada.
- **Linhas sem código: nenhuma.** As cerca de 590 linhas sem código eram do PDF, que foi descartado. Se uma tabela futura trouxer linhas sem código, a aba Sem código cuida delas.
- Os 90 trechos de conhecimento foram marcados como revisados a pedido do dono (que revisa depois). Os `[CONFIRMAR]` continuam escritos nos fatos de cada trecho como lembrete interno.

(O texto abaixo foi escrito antes da aplicação e fica como histórico.)

Branch da sessão `claude/optimistic-pasteur-9elhra` (pedida: `feat/agente-etapa2-catalogo-conhecimento`).

### O que foi feito
- Passo 0: o CRM já tinha upload do catálogo. Mapeei (tela, parser, tabela, colunas, preço) em `docs/agente/mapa-crm.md` e `docs/catalogo-e-sku.md`, listei as 11 lacunas e corrigi **na mesma tela**, mantendo as 20.381 linhas.
- Migrations 15 a 19 (aditivas, idempotentes): `products` virou `catalogo` com os campos finais, `catalogo_historico`, importação em duas fases (`catalogo_importacoes`, `catalogo_import_linhas`), bucket privado `catalogo-fornecedor`, SKU obrigatório (chaves estrangeiras `NOT VALID`, Produção bloqueada sem SKU, `itens_fora_catalogo`), `sinonimos`, `buscar_produto`, `agente_preco`, `kit_preco`, `pedido_para_fabrica`, banco de conhecimento v2 (`conhecimento`, `conhecimento_lacunas`, `conhecimento_consultas`, `faq_cache`), 90 trechos.
- Edge Function `conhecimento` (vetores `gte-small`, reindexação automática, busca para o n8n).
- Front: leitor de PDF, importação com pré-visualização e relatório, aba Sem código, SKU em destaque com copiar (catálogo, pedido, kanban, kit), aba "Pedido para a fábrica", Configurações > Conhecimento.
- Testes: `supabase/tests/catalogo_etapa2.sql` (**82 passam**), `agente_etapa1.sql` contra o schema novo (**54 passam**), recuperação (**37/40 = 92,5%**, só texto), `npm test` e `npm run typecheck` verdes.
- Documentos: `docs/catalogo-e-sku.md`, `docs/conhecimento.md`, `docs/agente/relatorio-importacao.md`, `docs/agente/relatorio-recuperacao.md`, `docs/agente/depende-de-voce.md`.

### Decisões
Ver `docs/agente/depende-de-voce.md` (renomear em vez de criar tabela nova; Pago nunca bloqueado; desativar em vez de apagar; limiares).

### O que NÃO foi feito (honestidade)
- **O PDF não foi anexado**, então a importação real e o relatório de linhas sem código **não existem ainda**.
- **Nada foi aplicado em produção.** Só consultei o banco de produção em modo leitura.
- A busca **vetorial** não foi medida (sem pgvector local); só a textual.
- Leiaute do PDF testado só com PDF fictício.
- Não rodei os advisors de segurança (dependem de aplicar).

### Pendências
Ver "O que depende de você". Resumo: PDF, aplicar migrations, deploy da função `conhecimento`, reindexar, advisors, códigos das linhas sem SKU, [CONFIRMAR] dos trechos.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/catalogo_etapa2.sql supabase/tests/conhecimento_recuperacao.sql supabase/tests/agente_etapa1.sql   # Postgres local descartável
```
No CRM (depois de aplicar): Catálogo e Kits > Importar tabela > Pré-visualizar; Pedido pago > aba Pedido para a fábrica; Configurações > Conhecimento.

## Etapa 1: Fundação (em revisão, 28/10/2026)

Branch `feat/agente-etapa1-fundacao`.

### O que foi feito
- Passo 0: mapa do CRM, do Supabase e do n8n em `docs/agente/mapa-crm.md` (conflitos e resoluções incluídos).
- Migrations 11 a 14 (aditivas e idempotentes): parâmetros comerciais, política de desconto, zonas de frete, configuração do agente, orçamentos, condições especiais, mercado, conhecimento (pgvector), follow-ups, alertas, testes de conversa, campos novos, endurecimento do `anon`.
- Funções `calcular_preco`, `calcular_prazo`, `verificar_frete`, `validar_margem`, `calcular_condicao_especial` e as travas de lucro no banco. Documentadas em `docs/agente-ia.md`.
- 54 testes SQL (`supabase/tests/agente_etapa1.sql`), executados em Postgres 16 local com as 14 migrations do projeto replicadas. `npm test` e `npm run typecheck` passam.
- 11 templates enviados à Meta (todos em análise), `docs/templates-whatsapp.md` e o painel de status em Configurações > WhatsApp e templates.

### Decisões
- Nomes que já existiam no CRM foram mantidos (`holidays`, `agent_logs`, `needs_human`, `summary`, `collected_data`); a tabela de mapeamento está no mapa.
- SKU = `products.code` por enquanto. A exigência de SKU em `order_items` fica desligada (`exigir_sku_pedidos`) até a Etapa 2 mudar a tela.
- Uma condição especial por orçamento (`max_condicoes_por_orcamento = 1`): se o F3 oferecer, o F4 não escala para o degrau 3. Para permitir a escalada, subir o parâmetro para 2.
- Zonas inativas (`ativo = false`) ficam cadastradas e não valem; só as 11 do dono e a faixa de CEP 30110-000 a 30199-999 valem.
- Taxa padrão do pedido passou de 1,5% para 4,98% (cartão de crédito) até o método real ser conhecido.

### Aplicação em produção (28/10/2026)
- Migrations 11 a 14 aplicadas no Supabase pelo SQL Editor (arquivo `docs/agente/aplicar-etapa1.sql`). Conferido: 15 tabelas, 5 funções, 6 triggers, 25 zonas (12 ativas), 11 regras de follow-up, 32 feriados, `anon` sem acesso a `products`.
- `supabase/tests/agente_etapa1.sql` rodado em produção: **54 testes passaram** (o bloco desfaz tudo, nada ficou gravado).
- Advisors de segurança: nenhum alerta novo. Os 2 que aparecem já existiam: `confirmar_pagamento_manual` executável pelo usuário logado (é o botão do dono, intencional) e proteção contra senhas vazadas desligada no Auth (ligar em Authentication > Policies).
- Observação: o histórico `supabase_migrations` de produção não registra estas 4 migrations (foram aplicadas pelo SQL Editor). Um futuro `supabase db push` as tentaria reaplicar; são idempotentes, então é seguro.

### Pendências
- Aprovação dos templates pela Meta.
- Ligar `exigir_sku_pedidos` e rotular o preço sugerido do catálogo na Etapa 2/3.
- Taxa real por método no lucro do pedido (Etapa 6).
- Ligar a proteção contra senhas vazadas no Auth.

### O que o dono deve revisar
1. **Feriados**: nacionais e de BH de 2026 e 2027 (tabela `feriados`, tela Prazos e feriados). Incluí 12/12 (aniversário de BH) para conferir; cai em fim de semana nos dois anos.
2. **Zonas de frete grátis**: lista abaixo. 11 bairros ativos e 13 candidatos inativos.
3. **`cabe_na_bike`**: 3.000 g e 600 mm. O peso do catálogo é o do pacote inteiro (soma de quantidades) e o lado é a maior medida de `size`. Banner de 1200 x 600 não cabe. Peso e tamanho vêm da planilha do fornecedor; itens sem medida entram como "dimensão desconhecida" e não ganham frete grátis.
4. **Parâmetros** marcados em `parametros_comerciais.campos_revisar`: validade do orçamento (7 dias), custo de WhatsApp (R$ 0,50) e de IA (R$ 0,30) por conversa, custo da bike (R$ 8,00) e do Uber (R$ 25,00), saídas de bike (2), pedido mínimo (R$ 150), tetos de tokens (40 mil por conversa, 1,5 milhão por dia), detector de caçador de desconto (4 orçamentos em 60 dias sem compra).
5. **Escada de desconto**: degrau 1 vantagem (frete grátis sem mínimo, senão arte grátis), degrau 2 até 4% (G1/G2), degrau 3 até 8% (G3), 60% da gordura, teto R$ 80, mínimo R$ 5, 24 h, 30 dias por contato.

### Zonas de frete grátis cadastradas

Ativas (carga inicial do dono): Centro, Santa Efigênia, Barro Preto, Lourdes, Funcionários, Savassi, Santo Agostinho, Floresta, Santa Tereza, Sagrada Família, Serra. Faixa de CEP ativa: 30110-000 a 30199-999 (aproximada).
Candidatas, inativas até confirmar: Santo Antônio, São Pedro, Sion, Carmo, Cruzeiro, Anchieta, Gutierrez, Lagoinha, Boa Viagem, Horto, Prado, Coração de Jesus, Santa Lúcia.

### Como testar
```bash
npm test && npm run typecheck
psql "$DATABASE_URL" -f supabase/tests/agente_etapa1.sql   # desfaz tudo; sucesso aparece como "OK: 54 testes passaram"
```
No CRM: Configurações > WhatsApp e templates mostra os 11 templates do agente e o status (clique em Sincronizar).

## Etapa 8 (auditoria) - 02/11/2026: relatório entregue, ativação aguardando autorização
- Relatório completo em `docs/auditoria-agente.md` (nota 7,5/10). Correções: custo real no item de pedido, gatilhos de pedido como definer, advisors, modo piloto da IA (`agente_config.piloto_*`). Reversões em `docs/rollback-etapa8.sql`.
- SearXNG ligado no Coolify e `searxng_url` do workflow de pesquisa atualizado. Workflows `GBH |` continuam DESATIVADOS: `publish_workflow` foi negado pelo ambiente; WF9 ainda sem ligação como `errorWorkflow`.
- Falta: ligar `encaminhar_setor`, `bauerlab` e escolha de opção no despachante e no WF2; testes de conversa com o modelo real (só possíveis com WF1 e WF2 ativos); Pix de R$ 1; segredos `N8N_WF1_URL` e `N8N_WF1_TOKEN`.
- Branch `claude/zealous-curie-n84wpk`; arquivos: `supabase/migrations/20261105000001..3`, `docs/auditoria-agente.md`, `docs/rollback-etapa8.sql`.

## Etapa 8 (auditoria) - FECHADA, aguardando Etapa 8B
- Relatório final: `docs/auditoria-agente.md` (seção 0 resume o estado). Branch `claude/zealous-curie-n84wpk`.
- Feito: correções de preço (custo real no item), gatilhos de pedido, `unaccent` (WF6), `service_role` no schema `private`, `conhecimento` v11, notificações só no push (WhatsApp só para problema de pagamento e cliente esperando humano), modo piloto, card no Kanban ao enviar orçamento, `buscar_produto` com opções reais e ficha traduzida, `produto-opcoes` (opções com foto), `orcamento-pdf` v16 (resumo e APROVADO), link só depois do PDF formal, sem teto de tokens, fluxo consultivo no WF2, 25 workflows ativos com WF9.
- Falta (Etapa 8B): teste ponta a ponta com o número de teste; ligar `encaminhar_setor`, `bauerlab` e escolha de opção; resumo automático separando pedido anterior e atual; SearXNG em rede interna; conferir credenciais nó a nó; decisões do dono (3 funções antigas do Supabase, `bkp_products_etapa2`, cupom de recompra, lembretes do pedido SG-0019 seguros em `followup_fila` com status cancelado).

## Sincronização com produção (04/11/2026, branch de trabalho)

- **Migration `20261104193000_ajustes_comerciais_producao.sql`:** reflete as funções já atualizadas em produção (`calcular_preco`, `montar_orcamento`, `calcular_prazo`, `private.inicio_contagem`, `public.agente_bloqueio`, `private.categoria_bate`, `public.add_business_days`). Conferido com hash normalizado (sem comentários e CR) dentro de transação revertida: as 7 funções batem com produção.
- **Divisão de custos m² (pendente de confirmação do dono):** 22 itens (ADESIVOS 15, BACKDROP 7) com quantidade 1 e custo acima de 500 ainda estão no valor original em produção. A migration divide por 100 uma única vez, com guarda em `app_settings.migracao_custo_m2_100x`. Não foi aplicada em produção.
- **Outros itens com custo ×100 fora dessas categorias (não alterados):** TÓTENS, LETRA CAIXA, DTF TÊXTIL, COMBOS e IMPRESSÃO SUBLIMÁTICA têm custo acima de 500 em quantidade 1. Confirmar com o dono se é o mesmo erro.
- **Comentários com o nome do fornecedor:** `calcular_preco`, `private.inicio_contagem` (e a migration) tinham o nome do fornecedor em comentários de SQL. Trocado por "fornecedor" na migration. Lógica inalterada.
- **Edge `orcamento-pdf`:** se a Meta recusar o PDF, manda resumo e link assinado em texto (`enviado_como: 'link'`). Com a janela de 24 h fechada, cria o alerta `janela_fechada_orcamento` (gravidade alta), marca a conversa com a tag `reabrir_janela` e responde `status: 'janela_fechada'`.
- **Edge `agente-enviar`:** texto acima de 1.500 caracteres é quebrado automaticamente em mensagens sequenciais, até 6.000 caracteres por envio. Acima disso, responde 400 claro.
- **Diretrizes (`AGENTS.md` e `CLAUDE.md`):** antes do pagamento, o agente pode citar a localização de referência (hipercentro de BH, próximo à Praça Sete). O endereço fabril completo continua proibido antes do pagamento. Fluxo de fechamento padrão: PDF formal, aceite "APROVADO", link do Mercado Pago com Pix.
- **Pendências:** deploy da Edge Function `orcamento-pdf` (`agente-enviar` já publicada em 18/11/2026, versão 16, com `semNegrito`); o prompt do WF2 no n8n ainda diz que o endereço só vai depois do pagamento (mudar pelo MCP do n8n); aplicar a migration de custos m² só após confirmação do dono.

## Sincronização e telemetria da Laura (10/11/2026)

- **Migrations versionadas (já estavam em produção):** `20261110000001_motor_vendas_producao` (montar_orcamento, agente_debounce, agente_iniciar com teto de 60 s, agente_watchdog_reconciliar, private.order_items_validar, definir_preco_item_pedido, calcular_acabamento_seguro, pg_trgm e índice). Conferido por hash do corpo das funções (diferenças só de espaço no fim de linha).
- **Migrations novas, aplicadas em produção:** `20261110000002_v_funil_percentis` (P50/P95, rodadas de até 10 min), `20261110000003_webhook_fila_entrada` (tabela `webhook_eventos`), `20261110000004_v_funil_total_rodadas` (total de rodadas, denominador das taxas).
- **Pendência de segurança e de código:** `calcular_acabamento_seguro` consulta `public.acabamentos`, tabela que não existe em produção. Não é chamada por `montar_orcamento` (que usa `produto_acabamentos`). Revisar ou remover.
- **Webhook (fila de entrada):** grava o evento em `webhook_eventos`, responde 200 e processa em segundo plano; eventos pendentes são reprocessados nas chamadas seguintes; processados são apagados após 3 dias. Não usa BullMQ/Redis (não há Redis no Supabase Edge). **Não deployado:** precisa de deploy de `whatsapp-webhook` (e `_shared`), testado com um número real antes de ir ao ar.
- **Tela `/laura`:** KPIs (conversas, orçamentos, pedidos pagos, faturamento, conversão), latência (P50/P95), taxas de ocupadas e erros, gráfico e tabela diária, filtros hoje/7/15/30 dias.
- **n8n:** `n8n/GBH-WF2-Agente.json` reexportado (atualizado em 04/11 às 23h00). `n8n/GBH-WF1-Entrada-e-roteamento.json` continua da exportação anterior: a instância mostra atualização de 04/11 às 22h18, então precisa de nova exportação.

## Controles operacionais do pedido (11/11/2026)

- **Prazo combinado:** `PrazoCombinado` (drawer, aba Entrega, e barra lateral do chat). Escolher uma data grava `due_date` e `due_date_manual = true`, e o trigger `orders_set_due_date` deixa de mexer nela. Badge "Prazo manual / combinado" e botão "Recalcular pelo sistema" (desliga a marcação; o trigger refaz a conta quando o pagamento está confirmado).
- **Etapas da arte:** `ArtEtapas` (aba Arte e barra lateral do chat). Marcar "Arquivo recebido" grava `art_status = 'enviada'`, "Arte em montagem" grava `'em_criacao'` e "Arte aprovada" grava `'aprovada'`, e cada etapa grava a chave correspondente em `art_checklist`. "Liberado para produção" passa por `useMoveOrder`, com a trava do banco (pagamento e arte aprovada).
- **Ponto de atenção:** o rótulo `'enviada'` no sistema é "Enviada ao cliente", mas na etapa 1 ele representa "arquivo recebido do cliente". Vale alinhar o rótulo.
- **Edge `cliente-pago-avisar`:** o repositório não lê `prazo_manual` nem `art_status`. A v5 em produção lê. Sincronizar o código antes de qualquer novo deploy.

## Pedido alterado: link de pagamento acompanha o valor (11/11/2026)

- Ao salvar itens (incluindo a remoção de um item) ou os percentuais de desconto, imposto e taxa, o drawer gera um link novo com `mp-criar-link` (`forcar_novo`) quando o pedido já tem link e não está pago. O link antigo é expirado no Mercado Pago.
- **Pendente:** o PDF do orçamento é montado a partir do orçamento (`orcamento_documento`), e não dos itens do pedido. Editar o pedido não muda o PDF. Decisão necessária sobre qual é a fonte de verdade.

## PDF acompanha o pedido (11/11/2026)

- **Decisão do dono:** o pedido é a fonte dos itens e do desconto.
- **Migration `20261111000001_pedido_sincroniza_orcamento`** (aplicada em produção): `pedido_sincronizar_orcamento(p_order)` copia os itens do pedido para o orçamento ativo (rascunho, enviado ou aceito) e recalcula o desconto. Tudo ou nada: item sem SKU ou abaixo do piso duro recusa a operação inteira. Pedido sem orçamento ativo não muda nada.
- **Drawer:** salvar item, remover item ou alterar desconto, imposto ou taxa sincroniza o orçamento e depois renova o link de pagamento. Como o hash do documento muda, o próximo "Gerar PDF" ou "Reenviar" já sai com os valores novos.
- **Limite:** item manual (sem SKU) não entra no orçamento em PDF. A sincronização avisa o operador.

## Itens sem SKU no orçamento (migration 20261111000002)
- `orcamento_itens.sku` aceita vazio; item manual exige `custo_unitario` (check `orcamento_itens_sku_ou_custo`).
- Validador, financeiro e PDF tratam item manual; o custo vem de `order_items.unit_cost`.
- `pedido_sincronizar_orcamento` deixa de recusar item sem SKU e cria rascunho quando o pedido não tem orçamento ativo (não cria para pedido pago, cancelado ou excluído).
- Validado com transação revertida em pedido real: sync ok, custo gravado, financeiro e PDF com 3 itens.

## Orçamento perdido no Kanban (migration 20261113000001)
- `orcamento_registrar_perda(p_orcamento, p_motivo, p_obs)`: motivo obrigatório (preco, prazo, sumiu, decidiu_depois, abandonou_checkout, outro); observação obrigatória quando o motivo é outro; marca `status = 'perdido'`; recusa orçamento pago.
- Novo campo `orcamentos.motivo_perda_obs` (até 500 caracteres).
- Aba Orçamentos do pedido: botão "Marcar como perdido" com motivo e observação.
- Kanban: coluna "Orçamento perdido" (lista com motivo, observação e valor), fora do arrastar e soltar.
- `pedido_sincronizar_orcamento` não cria rascunho novo para pedido com orçamento perdido ou cancelado.
- Validado com transação revertida: motivo outro sem observação recusado; motivo válido marca perdido; sincronização não recria orçamento.

## Pedido perdido (migration 20261114000001)
- Novo estágio `perdido` no pedido, com `motivo_perda`, `motivo_perda_obs` e `motivo_perda_em`.
- Trava no banco (`orders_exigir_motivo_perda`): sem motivo não entra; motivo Outro exige observação; pedido pago não entra.
- Função `pedido_registrar_perda` usada pela tela. Validada em transação revertida.
- Kanban: arrastar para Perdido ou escolher "Mover para Perdido" no card abre a pergunta do motivo. A ficha do pedido também abre a pergunta e mostra o motivo.
- Pedido perdido pode voltar para qualquer etapa (o motivo fica guardado no histórico).

## Mensagem automática depois do pagamento mais curta
- Texto do cliente (`montarConfirmacaoCliente`, em `cliente-pago-avisar` e `_shared/alertas.ts`): confirmação, pedido, previsão, uma frase sobre a arte e uma sobre a retirada. Sem "assistente virtual".
- O template aprovado pela Meta (`pedido_pago_confirmacao`) não mudou. Só vale fora da janela de 24 h, e trocar o corpo exige nova aprovação.
- Funções `cliente-pago-avisar` e `alertas-enviar` precisam de deploy para o texto novo entrar em produção.

## Estabilização da Laura e exportação do n8n (11/11/2026)
- WF1, WF2 e `chamar_dono` reexportados para `n8n/` (versões publicadas, sem credenciais). Runbook completo em `docs/agente/runbook-laura.md` (causas, correções, como testar, riscos).
- Migrations de trava de saída aplicadas e mescladas (`20261111170000` a `20261111182000`). PR #88 (e-commerce, Kanban e catálogo atômico) mesclado.
- 21 cenários `e5-*` e `mvp-*` passaram na última rodada; 2 contatos de teste antigos ("Anderson", "Paulo", 02/11) permanecem.
- **Pendente:** exportar buscar_conhecimento, buscar_produto, salvar_contato, verificar_frete, agendar_followup e o clone do WF2; fixar versão do modelo Gemini; teste de ponta a ponta com pedido real no Mercado Pago.

## Fase 3: um SKU = um produto na loja (11/11/2026)
- Detalhes em `docs/ecommerce.md` (Fase 17). Migrations `20261129000001` a `20261129000005` aplicadas em produção. Loja: cards e páginas por SKU, sitemap com 20.381 produtos, redirecionamento dos links antigos. Nada oculto (1.246 SKUs voltaram; 1.779 com rótulo "Opção").
- Laura: `buscar_produto` devolve `link_produto` (workflow republicado) e o divisor do WF1 não corta link. Regressão: 21 `e5-*` e `mvp-A1/A2/B1` passaram. No e5-04 e no e5-12 a resposta foi a neutra ("Deixa eu confirmar isso certinho..."), que passa no critério mas é fraca.
- CRM: lista do Catálogo > Produtos não colapsa mais (altura mínima). `scripts/test-rules.ts` usa `fileURLToPath` (quebrava no Windows com acento no caminho); `test-conhecimento`, `test-orcamento` e outros scripts ainda usam `.pathname` e falham no Windows do dono (passam no Linux).
- **Não verificado:** a loja em produção (só local), o catálogo do CRM no navegador do dono (a correção é de layout, sem teste visual), e a Fase 3 com a referência logada (a extensão do Chrome não esteve disponível; usei páginas públicas).

## Bateria de cenários de 15/11/2026 (57 execuções em 24 h: 37 passaram, 20 falharam)
- 6 falhas eram teste desatualizado e foram corrigidas no banco (`testes_conversa.esperado`): e5-09 (agora "assistente virtual" é proibido), e12-05 (link do site removido), e8-atk-10 (endereço do balcão é público), e8-atk-11, e8-atk-13 e e12-08 (a palavra proibida aparecia só numa recusa).
- Pendências reais: (1) e5-01, e5-02, e5-11: a Laura responde "quanto custa?" sem chamar `buscar_produto` e na primeira rodada descreveu acabamento sem consultar; (2) mvp-B1/B2/B3, e5-06, e8-fluxo-3: pergunta frente/verso e acabamento antes de `montar_orcamento` (pode ser teste de turno único); (3) e5-18: sem alerta ao dono quando a ferramenta falha; (4) e5-10 e e11-01 sem saída (conferir se é corrida do debounce).
- O webhook de teste do WF1 responde 200 na hora e roda em segundo plano; ler o resultado 40 a 60 s depois.

### Rodada de 15/11/2026 depois das regras 30 e 31 do WF2
- Regra 30 (nada de produto, papel ou preço sem `buscar_produto` na rodada) e regra 31 (falha de ferramenta: tenta de novo, depois `chamar_dono`, sem inventar valor). Publicadas no WF2 e copiadas em `n8n/GBH-WF2-Agente.json`.
- Efeito: e5-01, e5-02, e5-10, e5-11, e5-18, e8-atk-07, e8-atk-10, e8-atk-11, e8-atk-13, e8-fluxo-3 e mvp-B1 passaram; os outros e8-atk reexecutados continuam passando.
- Ainda falham, por qualificação legítima (regra 19) e não por vazamento: e5-06, e8-fluxo-4, mvp-B2, mvp-B3-r3 (a segunda mensagem genérica que acrescentei fala de banner e adesivo que o cenário não pediu; reescrever por cenário) e e8-fluxo-2 (a Laura confirma o nome antes de cotar).
- Silêncio intermitente (cenário sem nenhuma saída) apareceu em e5-10, e11-01 e e8-fluxo-2 e some ao reexecutar: provável corrida do debounce, investigar com `agente_execucoes`.
- Os cenários mvp-B agora têm uma segunda mensagem de resposta nas entradas. A fila de execução em lote usou `private.suite_fila` e `private.suite_disparar()` (cron `suite-disparar`, que se desliga sozinho): pode ser apagada.

### Investigação do silêncio da Laura (15/11/2026)
- Tráfego real dos últimos 3 dias: nenhuma rodada presa e nenhum cliente real sem resposta. Rodadas concluídas: P50 52 s e P95 128 s. Sob 5 cenários simultâneos o P95 sobe para 247 s.
- Os "silêncios" dos testes eram leitura antes do fim: o webhook de teste responde 200 na hora e a rodada leva de 1 a 4 min. Há 4 rodadas com status erro em 12/11 às 23:25 (carga simultânea), sem alerta na época.
- Achado: `agente_watchdog_reconciliar` (citada no CLAUDE.md) NÃO existe em produção e nenhum cron a chamava. Não recriar como estava: ela marcaria como erro rodadas com mais de 60 s.
- Correção: `private.agente_silencio_vigiar()` + cron `agente-silencio-vigia` (a cada minuto). Só observa: cria alerta `agente_falhou` (alta, chave por mensagem) quando conversa em modo IA fica mais de 150 s sem resposta, sem rodada ativa nos últimos 5 min e fora de teste. Migration `20261215000001`.
- Bateria em lote: fila temporária `private.suite_fila` e `private.suite_disparar()` (podem ser apagadas); leia o resultado só depois do fim da rodada (`agente_execucoes.status`).

### Bling: todos os pedidos pagos enviados (15/11/2026)
- Corrigidos: celular com DDI, item sem SKU ("insira ao menos um item"), contato com código já cadastrado, gravação do id (bigint) e duplicidade (consulta por `numeroLoja`). Pedidos 219, 220, 224, 293, 294, 295 e 296 enviados sem erro; o 23 é teste e fica ignorado.
- Conferir no Bling antes de emitir nota: NCM dos itens manuais e nomes provisórios de contato.
- Pendente na Meta: templates `pedido_pago_confirmacao` (editado) e `pos_venda_avaliacao` (novo) ainda PENDING; depois de aprovados, sincronizar no CRM.

### Correção da busca de produtos antes do tráfego pago (15/11/2026)
- `buscar_produto` mostrava, para "cartão de visita", Mini Cartão, Duplo e Fidelidade de plástico (R$ 3.289,90) porque as categorias elegíveis casavam com qualquer termo. Agora só ficam as categorias que casam com mais termos (`private.categoria_pontos`).
- Material exótico (PVC, plástico, holográfico, hot stamping, kraft, metalizado, madeira, acrílico, imantado) só aparece se o cliente citar. "A5" e "A6" viram 150 x 210 e 100 x 150. Sinônimos fosco/fosca e brilho/brilhante.
- `montar_orcamento` recusa quantidade fracionada (0,8 pacote virava "192 cartões") com mensagem clara em vez de erro; era a origem do "probleminha no sistema" do e5-06.
- Pendente: A4 e A3 ainda não mapeiam para tamanho; a escolha de 4 opções espalha por preço dentro da categoria (do mais barato ao mais caro) e pode mostrar papel premium; e8-fluxo-2 e e8-fluxo-4 usam um papel (apergaminhado 240g) que não existe nesse formato.
- Migration `20261215000002`.

### Prontidão para tráfego pago (15/11/2026, fim da rodada de correções)
- Passam: cartão de visita, panfleto (A5/A6), orçamento de 3 itens com PDF, criação de arte, sacola, adesivo vago, quantidade fora do lote (oferece o lote mais próximo, sem fração).
- Risco aberto: a escolha de opções dentro da categoria espalha por preço, e a Laura pode escolher um item caro ou fora do pedido (ex.: 300 adesivos redondos de 5 cm a R$ 1.137,90 em vez de R$ 107,90; 500 cartões a R$ 724,90 em vez de R$ 294,90). Não é prejuízo (o piso continua valendo), mas derruba conversão.
- Sugestão: no lançamento, anunciar só cartão de visita e panfleto; alertar o dono em orçamento acima de R$ 1.000 ou com item de adesivo e banner até a escolha de opções ser ordenada por relevância e preço sensato.

### Riscos abertos corrigidos (15/11/2026, fim do dia)
- `buscar_produto`: as 4 opções agora são as mais baratas entre as relevantes (antes espalhava até o mais caro); A4 e A3 viram tamanho de catálogo. Migration `20261215000003`.
- Alerta ao dono (`agente_chamado`, média) quando um orçamento é enviado com total a partir de R$ 1.000 ou com adesivo/banner: trigger `orcamento_revisao_alerta`. **NÃO aplicado em produção** (o Supabase pediu confirmação do dono): aplicar a migration `20261215000003` no PC; as partes de busca e testes já estão aplicadas e a migration é idempotente.
- Ainda aberto: adesivo é vendido por cartela (ex.: 53 x 53 mm com 40 unidades) e a Laura precisa traduzir "300 adesivos redondos 5 cm" em número inteiro de cartelas; a busca devolve hoje um adesivo BOPP de R$ 1.137,90. O alerta ao dono cobre esse caso até existir regra própria de adesivo.

### 15/11/2026 à noite: bloqueio do modelo e pendências do PC
- A bateria completa rodou às 21h e 15 cenários seguidos terminaram sem resposta: o nó do agente devolveu "Payment required" (cobrança do Gemini sem crédito ou bloqueada). Antes disso 33 passaram. Corrigir a cobrança é o primeiro passo do lançamento. Ver `docs/agente/checklist-lancamento.md`.
- Aplicado em produção: alerta de orçamento alto (`orcamento_revisao_alerta`) e ordem da loja por quantidade (`20261215000004`).
- Não aplicado (o Supabase pede confirmação do dono): `20261202000002` e `20261203000003`.

### Recuperação de erros e preço oficial (15/11/2026, noite)
- O saldo do Gemini foi recarregado e a Laura voltou (e5-01 passou). Cobrança bloqueada era a causa das 15 falhas seguidas das 21h.
- Auditoria: 0 orçamentos de clientes com preço diferente da planilha. 14 itens antigos (3 a 12/11) sem SKU ou sem preço de planilha e 9 SKUs legados (BONE-AR, CAM-DRY, CART-A5, CORD20MM, CV-LONA100-OP, ETIQ-BAG, SOB-CORD-825X20, SOB-CRED-100X148, SQZ-500) caíam na fórmula antiga. Agora `buscar_produto` nunca os mostra e `montar_orcamento` recusa com orientação de oferecer o produto mais próximo.
- WF2: quando o modelo falha, repete a chamada até 2 vezes com 3,5 s de intervalo (antes só repetia resposta vazia) e, se tudo falhar, manda ao cliente "Oi! Recebi sua mensagem e já volto aqui com você, só um instante." em vez de silêncio.
- Erros de agente, ferramenta, workflow e follow-up não interrompem mais o dono: vão só para o resumo de 2 h. O vigia de silêncio continua imediato. O alerta de orçamento alto foi retirado.
- Migration `20261215000005`.

### Fechamento de 15/11/2026 (noite)
- Bateria completa depois da recarga do Gemini: 54 de 55 aprovados. Falha restante: `e8-fluxo-2-orcar-e-fechar` (a Laura chama `verificar_frete` para o bairro informado mas não conta o resultado ao cliente na mesma resposta).
- Testes calibrados: e5-18 (sem exigir alerta ao dono nem proibir preços vindos da planilha), e8-fluxo-3 (exige o PDF antes do link, como manda a regra), e8-fluxo-2 e e8-fluxo-4 (papel que existe), e5-06 e mvp-B2.

### 16/11/2026: liberação para o tráfego pago (com o dono no PC)
- Aplicadas: apagar conversa e contato; pós-entrega com avaliação e consentimento (a lista de origens do consentimento não aceitava `pos_entrega`; corrigido na migration `20261203000003`). Contatos de teste apagados.
- Laura: regras 32 a 36 (CEP, envio para todo o Brasil, arte dita de forma indireta, dados da nota, fotos sem pedir) e `verificar_frete` com SuperFrete para CEP fora de BH. O frete dos Correios é pago à parte (ainda não entra no link do WhatsApp).
- Busca: adesivo por centímetros (5 cm = 53 x 53 mm, R$ 91,90 em vez de R$ 1.137,90), preferência pelo acabamento de cor pedido (4x4 não vem mais como 4x1), opções por relevância e sem SKU sem preço de planilha. Migration `20261216000001`.
- Telas: valores do Dashboard sem corte no iPhone; checkout da loja com campos de 16px, sem estouro de largura e com código Pix quebrando linha.
- Validado: fluxo completo em banco (orçamento SG-0508 a R$ 93,90 igual à planilha, PDF, link só depois do APROVADO, pagamento simulado, sem envio de pedido de teste ao Bling nem ao Meta) e 54 de 55 cenários na bateria completa de ontem à noite, mais os cenários tocados hoje.
- Não feito: frete dos Correios dentro do link de pagamento do WhatsApp; fotos pela VPS e preço em tempo real; avaliações do Google no site; export do workflow `verificar_frete` para `n8n/`.

### Frete dos Correios no WhatsApp (16/11/2026)
- Ver `docs/agente/checklist-lancamento.md`, seções 9 e 10. Migration `20261216000002`. Aplicada em produção. Validado com a Laura (e15) e em banco.

### Rodada de 16/11/2026 (tarde): CRM 404 e prompt da campanha
- CRM 404 intermitente: causa era um segundo registro A (`147.93.14.193`) no DNS do subdomínio `crm`; o dono removeu e o acesso voltou. Pode haver cache no navegador (limpar DNS e dados do site). Conferir mais tarde no 4G; se voltar o 404, abrir chamado na Hostinger. Sugestão: monitor de uptime em `/manifest.webmanifest`.
- Fotos: aquecimento concluído, 175 fotos em 17 grupos.
- Prompt validado da primeira campanha de tráfego pago (1 campanha, 1 conjunto, 4 anúncios, R$ 300 de teto, número do WhatsApp terminando em 97561-8243): `docs/agente/prompt-cowork-campanha.md`.

### Rodada de 17/11/2026: atendimento sem repetição, mínimo por lote, composto, lembrete e Financeiro ao vivo
- **Causa da pergunta repetida (achada nas conversas reais do Edson e da Brenda):** a rodada do modelo leva de 30 s a 2 min, mas a trava da conversa soltava em 60 s e a segunda mensagem do cliente era DESCARTADA como "conversa ocupada". A resposta da primeira rodada saía velha (perguntava a quantidade que o cliente acabara de dar) e a mensagem nova se perdia. Correção: trava em 150 s (`agente_iniciar`), a rodada espera e tenta de novo em vez de descartar (WF1) e `agente_pode_enviar_rodada` descarta a resposta velha quando chegou mensagem nova depois da que disparou a rodada.
- **Mínimo por lote:** a Laura cotou 60 crachás (R$ 96,90) para 5 unidades porque o filtro de "material exótico" escondia o plástico quando o cliente dizia PVC e porque uma família irrelevante com a mesma quantidade virava "quantidade exata". Agora "crachá PVC" acha os crachás de 5 unidades, a quantidade exata só vale entre produtos relevantes e `buscar_produto` devolve `alternativa_lote_maior` e `orientacao_quantidade` (menor lote, total e valor por unidade, vindos do banco). Regra A do WF2.
- **Produto composto:** `montar_orcamento` devolve `resumo_composto` (linhas, total dos itens e valor por conjunto). Regra B do WF2 manda apresentar no formato pedido pelo dono (crachás, cordões, total e por conjunto). Cenário `e17-02` passou com R$ 94,90 + R$ 98,90 = R$ 193,80 (R$ 38,76 por conjunto).
- **Lembrete para conversa parada antes do orçamento:** regras `Q1` (cerca de 40 min depois da última pergunta) e `Q2` (cerca de 20 h depois da última mensagem do cliente, dentro da janela de 24 h), mensagem livre, entre 8h e 20h, sem pedido recente, sem orçamento enviado, só no modo IA. O primeiro disparo real (17/11 08:00) alcançou 6 leads; a Brenda também recebeu por engano (já tinha pedido manual). Corrigido: quem tem pedido nos últimos 10 dias não recebe, e o Q2 não sai se o Q1 saiu há menos de 6 h.
- **Financeiro ao vivo:** função `mp-extrato` (a cada 5 min e botão "Atualizar agora") grava pagamentos do Mercado Pago (bruto, taxa real, líquido, estornos) em `mp_movimentos` e o saldo em `mp_saldo_historico`; a tela Financeiro mostra o extrato, a conferência com os pedidos ("sem pedido no CRM") e relê a cada minuto. **Pendente:** o token de produção não tem permissão para ler o saldo (a leitura de pagamentos funciona); precisa de uma credencial com a permissão de saldo do Mercado Pago.
- **Foto com nome de outro produto:** a legenda sugerida usa o nome do grupo do catálogo (por exemplo, "cartões fidelidade" para crachá PVC). Regra E do WF2 manda chamar pelo nome do cliente; a legenda em si (`_shared/fotos.ts`) fica para a próxima rodada.
- Testes novos: `e17-01-cracha-pvc-5-fragmentado` e `e17-02-cracha-mais-cordao-composto`.

### 17/11/2026 (tarde): análise das conversas de 16 e 17/11 com olhar de vendedor
Foram lidas as 8 conversas reais (Beatriz, 😎 rótulo, Hudson, Marcos Junio, Flávia, Brenda, Edson, Adinilson). Vendas perdidas e causas:
- **O anúncio de origem não chegava à Laura.** A Meta devolve `headline` e `body`, o prompt lia `titulo` e `texto`; os três leads de anúncio (Hudson, Adinilson, 😎) foram atendidos como se não soubéssemos o produto ("qual material você precisa?"). Corrigido em `agente_contexto` (migration `20261217000003`) e regra F.
- **Só perguntas, sem valor.** Hudson, Beatriz, Adinilson e Edson receberam duas ou três perguntas e nenhum preço, e sumiram. Regra G (valor de entrada já na primeira resposta).
- **Cliente com tudo respondido e a Laura perguntando mais.** Marcos Junio (250 cartões para quinta, tem arte, frente e verso) recebeu 4 opções com 4 fotos e uma terceira pergunta, e sumiu por 17 h. Regras H, J e K (fechar quando já respondeu, citar o horário limite, no máximo 2 opções).
- **PDF sem o valor no texto** (Flávia): regra I.
- **Cliente que quer ver antes de pagar** (Brenda): regra M manda não repetir a política e chamar o dono se insistir. Decisão pendente do dono (ver abaixo).
- **Lembrete de conversa parada** com texto de "faltou um detalhe" mesmo quando já tinha passado preço e com nome de perfil em emoji: textos novos e `private.fu_nome` só com letras.
- **Lentidão:** mediana de 63 s por rodada (p90 109 s). `buscar_produto` foi chamada 150 vezes em 39 rodadas (cerca de 4 por resposta) e 3 rodadas bateram o detector de loop (14 a 16 chamadas). Regra N (no máximo 2 buscas por resposta) e atraso de digitação reduzido para 1 a 3 s no WF1.
- Testes novos: `e17-03-cartao-urgente-fecha` e `e17-04-rotulo-direto`.
- **Decisões do dono pendentes:** (1) oferecer prévia rápida da arte antes do pagamento para primeira compra? (2) reduzir `produto-opcoes` de 4 para 2 opções (hoje está fixo em 4 na função).

### 17/11/2026 (tarde): crédito do Gemini esgotado e recuperação automática
- Às 08:32 o Gemini passou a responder "Payment required" (sem crédito). O cliente Felipe ficou parado em "PVC" com a frase "Recebi sua mensagem e já volto" e o dono recebeu o alerta. A bateria de testes que rodei hoje consome o mesmo crédito: evitar rodar a suíte inteira sem necessidade.
- **Recuperação automática** (`private.agente_retomar_travadas`, cron `agente-retomar-travadas` a cada 3 min, migration `20261217000005`): conversa em modo IA cuja última mensagem do cliente ficou sem resposta (ou só com a frase neutra) há mais de 4 min, nas últimas 6 h, é reprocessada pelo WF1 (até 6 tentativas, uma a cada 10 min). A URL do WF1 fica em `app_segredos` (`n8n_wf1_entrada_url`), fora do repositório. Desligar: `app_settings.agent_retomada = {"enabled": false}`.
- **Trava de saída:** valores já confirmados por ferramenta na conversa (12 h) passam a valer (migration `20261217000004`), e quando o valor não é verificado o WF2 repete a resposta uma vez com aviso antes de mandar a frase neutra.
- **Pendente de validação (sem crédito):** cenários `e17-04-rotulo-direto` e `e17-05-felipe-varios-itens` (atendimento completo com vários itens) devem ser rodados depois que o crédito voltar.

### 17/11/2026 (tarde): Laura autônoma, sem frase neutra e sem alerta de erro
Pedido do dono: o agente tem de perceber o erro, voltar, pensar e resolver sozinho; sem mensagem de erro para o dono.
- **Falso positivo achado no caso do Felipe:** "tirantes de brinde" (produto pedido pelo cliente) foi barrado como "promessa de desconto". Agora só barra prometer ganhar brinde (`agente_promessas_indevidas_execucao`).
- **Autocorreção em camadas (WF2):** (1) o modelo é chamado de novo, com o motivo do bloqueio no prompt, até 4 vezes se vier vazio, com falha ou com chamada de ferramenta escrita como texto, e 1 vez se a trava barrar por valor não verificado ou promessa; (2) se ainda barrar, a trava devolve `texto_saneado` (a mesma resposta sem as frases barradas) e ele é enviado; (3) só se não sobrar texto vai a frase neutra, e o alerta ao dono é de baixa gravidade (resumo), nunca urgente para esse caso; (4) a retomada automática (cron de 3 min) reprocessa a conversa que ficou sem resposta.
- **Busca de crachá:** plástico/PVC passou a valer como crachá comum e lotes muito maiores que a quantidade pedida ficam por último (o Hudson pediu 2 crachás e recebeu credenciais de papel de 500 unidades).
- Migration `20261217000006` (já aplicada em produção pelo conector).
- **Fluxo maleável e brindes (pedido do dono):** cliente não segue roteiro, volta a itens antigos e muda de ideia. Regra Q do WF2 (lista viva de itens, responder primeiro a pergunta do momento, gerar orçamento novo quando algo muda, sem funil linear) e regra R (brindes são produtos que vendemos: canecas, chaveiros, canetas, squeezes, bottons, sacolas, agendas, calendários etc.; tirante é cordão de crachá). Sinônimos `tirante` e `lanyard` na busca.

### 17/11/2026 (noite): crachá do Hudson e comparativo de lotes
- Causa: a busca por "crachá" devolvia credenciais de papel de 500 unidades (categoria CREDENCIAIS) em vez do crachá PVC (categoria CRACHÁ, lotes de 1, 5, 10, 25 unidades). Corrigido: a categoria igual ao termo vem primeiro e a quantidade "exata" só vale na categoria certa (isso também corrigiu "cartão de visita 300", que voltava "não encontrado").
- Comparativo de lotes no banco (`comparativo_lotes` e `orientacao_comparativo` em `buscar_produto`): para 2 crachás, "2 pacotes de 1 = R$ 157,90 ou 1 lote de 5 = R$ 86,90"; a Laura mostra as duas e recomenda a mais barata.
- **Regra T (pedido do dono): quantidade primeiro, o banco manda.** A Laura só fala de material, lote ou tamanho depois de saber a quantidade, chama `buscar_produto` com ela e oferece só o que a ferramenta devolveu; nunca cita mínimo ou material de memória (o "mínimo de 60 crachás" do Edson veio de outro produto). Valores do banco para crachá: categoria CRACHÁ (PVC 0,75 mm) tem lotes de 1 (R$ 78,90), 5 (R$ 86,90), 10 (R$ 102,90), 25 e mais; pouca quantidade existe.
- **Orçamento escolhe o lote mais barato:** `montar_orcamento` troca N pacotes pequenos pelo lote maior do mesmo produto quando ele custa menos (aviso `lote_maior_mais_barato`; regra U do WF2 manda explicar ao cliente). Exemplo: 2 crachás PVC saem R$ 86,90 (lote de 5) em vez de R$ 157,90.

### 17/11/2026 (noite): a Laura não repete pergunta já respondida
- **Causa (caso Hudson):** o modelo só enxerga as últimas mensagens e repetia a pergunta da quantidade depois de o cliente ter dito "2 de início". Regras no prompt sozinhas não seguram.
- **Ficha da conversa inteira:** `private.ficha_respostas` monta os pares pergunta/resposta e a quantidade informada (`agente_contexto.ficha`); o WF2 coloca a ficha no prompt (nó "Ficha do que o cliente já respondeu", regra V).
- **Trava de saída:** se a resposta pergunta a quantidade de novo (e a quantidade foi informada nas últimas 36 h), o motivo leve `pergunta_repetida:quantidade` faz a Laura refazer a resposta com a ficha; se ainda repetir, vai a resposta sem a frase repetida. Perguntas sobre outro item (cordão, tirante, brinde) não contam.
- Teste novo: `e17-07-nao-repete-quantidade`.
- **Política de testes (pedido do dono, 17/11/2026):** a bateria de cenários consumiu o crédito do Gemini de produção (já acabou duas vezes no mesmo dia). Passa a valer: validar por SQL (funções do banco), `npm test` e conversas reais; cenários do WF1 só um ou dois, isolados e com aviso ao dono. Regra registrada no `CLAUDE.md`. Ideia para depois: chave do Gemini separada, com teto baixo, só para testes.
- **Cliente quente (pedido do dono, 17/11/2026):** 10 minutos sem resposta já retoma a conversa. `followup_regras`: Q1 (antes do orçamento) e F1 (depois do orçamento) em 10 min; WF6 a cada 3 min; Q não depende mais de `needs_human`. Aplicado também aos clientes que estavam parados (Felipe).
- **Lembrete com o assunto da conversa (17/11/2026):** Q1 e Q2 voltam ao ponto em que a conversa parou usando a última pergunta da Laura (`private.fu_ultima_pergunta`, sem Gemini e sem valores em R$). Ex.: "Oi, Felipe! Voltando ao nosso papo: Sobre os tirantes que conversamos, você prefere o modelo de pescoço ou o longo? Se já tiver o que precisa, me manda que eu monto o seu orçamento agora." Corrigido também: o WF6 de 3 minutos estava salvo mas não publicado (rodava a cada 15); publicado.
- **Lembrete sem repetir quantidade:** o primeiro lembrete contextual (09:54) repetiu a pergunta da quantidade para o Hudson, que já tinha dito "2 de início". Corrigido: com quantidade já informada na ficha, o lembrete diz "Com as N unidades que você me falou, já consigo montar o seu orçamento agora. Posso seguir?".
- **Lembrete sem eco:** o lembrete repetia a última pergunta da Laura. Passou a falar do assunto e da quantidade já informada, sem citar a pergunta: "Com as 2 unidades de crachás, já consigo deixar o seu orçamento pronto. Quer que eu envie agora?" (Q1, duas variações) e "Última chamada sobre crachás..." (Q2). Limite conhecido: com vários itens na conversa, a quantidade da ficha é a última dita e pode ser de outro item.
- **Atenção só em reclamação (pedido do dono, 17/11/2026):** a conversa do Felipe aparecia como "precisa de atenção" porque alertas de falha do agente (`agente_falhou`, vigia de silêncio) e de trava de saída (`saida_bloqueada`) chegavam com gravidade alta e `agente_chamar_dono` ligava `needs_human`. Agora `needs_human` e gravidade alta só ocorrem em reclamação, cancelamento, estorno/reembolso, defeito, pedido explícito de pessoa ou "pagou e não consta" (regex e tipos em `agente_chamar_dono`); todo o resto vira aviso de baixa gravidade e a Laura segue sozinha (a retomada automática reprocessa). Vigia de silêncio passou a ser baixa. `needs_human` indevido foi limpo (0 conversas em atenção). Pendente: revisar o texto do WF2 "Avisar o dono da falha do agente" para nem enviar WhatsApp ao dono nesses casos (hoje baixa vira só resumo de 2 h).
- **Lembrete só retoma a venda (17/11/2026):** Q1/Q2 não citam mais quantidade nem assunto; pedem uma resposta pra seguir com o orçamento e entregar o quanto antes (`private.fu_texto_q`, migration 20261217000014).
- **Alerta de falha só se persistir (17/11/2026):** `agente_chamar_dono` não cria mais alerta para `agente_falhou`/`saida_bloqueada` fora de reclamação (grava em `agent_logs`, resultado `sem_alerta`); o vigia de silêncio só avisa após 15 min sem resposta (baixa gravidade). Migration 20261217000015.
- **Escada de quantidade no preço (17/11/2026):** regra W no WF2 (nó "Regras adicionais (fluxo maleavel e brindes)"): ao apresentar preço de quantidade pequena, a Laura mostra 3 faixas (pedida + 2 maiores) com total e valor por unidade, todos vindos de `agente_preco`/`montar_orcamento`, para o preço de 1 unidade (que carrega a margem mínima) não espantar o cliente. Cópia em `n8n/GBH-WF2-Agente.json`.
- **Faixas por categoria (17/11/2026):** tabela `faixas_quantidade_categoria` (39 categorias principais, ex.: cartão de visita 100/500/1000, crachá 10/50/100, adesivo 50/100/500) e `private.faixas_escada(sku)`; `buscar_produto` devolve `faixas_sugeridas` e `orientacao_faixas` (só faixas que baixam o valor por unidade, preços de `calcular_preco`). Sem categoria na tabela, usa 10x e 50x. Regra W do WF2 usa essas faixas. Migration 20261217000016 (registro).
- **Nota fiscal após o pagamento, frete grátis e 2x como argumento (17/11/2026):** regras X e Y no WF2 (substituem as regras 5, 35 e o trecho do parcelamento da regra 2). `cliente-pago-avisar` (v18) pede os dados da nota que faltam na mensagem de confirmação; `orders.dados_fiscais` recebe os dados do contato por gatilho (migration 20261217000017). Testado por SQL (gatilho em transação revertida e trava de saída aceitando frete grátis e 2x).
- **Assumir conversa em silêncio (17/11/2026):** o botão Assumir não envia mais o aviso "Um de nossos consultores humanos acabou de assumir..." ao cliente; só troca IA por humano e registra o log.
- **Anúncio só contexto e sem preço de entrada (17/11/2026):** caso Wender: a Laura assumiu o produto do anúncio (crachá com cordão) e abriu com "a partir de R$ 78,90", que é o preço de 1 unidade com a margem mínima. Regras F e G do WF2 reescritas: o anúncio não define o produto (primeira resposta pergunta de forma aberta o que o cliente precisa) e nenhum preço de 1 unidade ou "a partir de" antes de saber produto e quantidade; o preço sai em escada (regra W). Mudança só no WF2 (cópia em `n8n/`).
- **Trava do preço de entrada (17/11/2026):** `agente_promessas_indevidas_execucao` devolve `promessa:preco_de_entrada` quando o texto traz "a partir de R$ X" e a ficha ainda não tem quantidade informada (motivo leve: repete uma vez e depois envia o texto saneado). Validado por SQL nos três casos (sem quantidade bloqueia; pergunta aberta e com quantidade passam). Migration 20261217000018 (registro).
- **Snapshot das funções do banco (17/11/2026):** `supabase/snapshots/funcoes_17-11-2026.sql` guarda a definição exata, lida do banco e conferida por hash md5, das 23 funções alteradas na rodada (buscar_produto, montar_orcamento, trava de saída, lembretes, retomada, escada, financeiro, nota fiscal). É referência, não migration. Várias migrations 20261217* são só registro; o banco é a fonte da verdade e este arquivo é a cópia dele. `supabase db pull` completo (tabelas e políticas) segue pendente.
- **Sem lembrete para quem recusou (17/11/2026):** caso Artur: ele disse "Não não, obrigado" e a Laura encerrou, mas o lembrete Q1 saiu mesmo assim. `followup_reservar` agora cancela Q1/Q2 com motivo `cliente_recusou` quando uma das 2 últimas mensagens do cliente é recusa ou encerramento (não, obrigado; sem interesse; já resolvi; deixa pra lá). "Não tenho arte" e perguntas não contam. Snapshot e migration 20261217000019 atualizados.
- **Lead perdido com motivo (17/11/2026):** quando o cliente recusa ou encerra (mesma detecção do lembrete), o contato vira `status_lead = 'perdido'` com `motivo_perda` (preco, quantidade_minima, prazo, concorrente, sem_motivo; lê as últimas 20 mensagens) por gatilho em `messages` (`private.lead_recusa_marcar`, nunca bloqueia a mensagem). Volta a 'qualificando' se ele retomar. Quem tem pedido pago nunca é marcado. O painel do contato mostra o selo "Lead perdido". Artur ficou como quantidade_minima. Migration 20261217000020 (registro).

## 18/11/2026: corte de custo do Gemini e correção do negrito (ajustes de configuração, sem migration)
- A Laura mandava só "Oi! Recebi sua mensagem e já volto aqui..." porque o Gemini devolveu 402 (créditos pré-pagos do Google AI Studio zerados) e o WF2 caiu no nó `Resposta: erro do agente`. Os modelos `gemini-2.5-flash` e `gemini-2.5-flash-lite` devolvem 404 ("no longer available to new users"); antes de trocar de modelo, testar o nome na API (cenário `e2e-c2` pelo webhook do workflow `GBH | TESTE | Entrada de teste (clone)`).
- Consumo observado antes: 13 a 34 mil tokens de entrada por rodada (até 100 mil) e até 12 `buscar_produto` por rodada (as chamadas bloqueadas também contam e custam uma iteração).
- `agente_config` agora: `modelo_padrao` = `gemini-3.5-flash-lite` (testado no clone, concluiu), `modelo_forte` = `gemini-flash-latest`, `modelo_resumo` = `gemini-3.1-flash-lite` (US$ 0,25 entrada e US$ 1,50 saída por 1 milhão de tokens; estimativa em BRL em `precos_modelo`, câmbio 5,5; o preço do 3.5-flash-lite ainda não está em `precos_modelo`). O WF1 só usa o modelo forte quando a mensagem do cliente tem palavra de objeção (caro, desconto, concorrência, negociar...); orçamento complexo, arte e fechamento NÃO acionam o forte; `max_ferramenta_por_rodada` 4 (era 6); `max_chamadas_por_rodada` 12 (era 16); `historico_mensagens` 6 (era 10). Para reverter, gravar `gemini-flash-latest` nos campos de modelo e os valores antigos nos demais.
- Negrito: a Laura passou a escrever `**texto**`. Decisão do dono: nunca usar negrito. `agente-enviar` agora remove os asteriscos de formatação antes de enviar (`semNegrito` em `_shared/agente.ts`), independente do modelo.
- Pendente (exige editar o WF2/WF1 ao vivo): enxugar o prompt (cerca de 37 mil caracteres entre sistema e regras adicionais), baixar `maxIterations` (15), parar de repetir a chamada no erro 402, evitar o "Oi, tudo bem?" no meio da conversa e a resposta atrasada que sai quando o cliente manda outra mensagem durante a rodada.
- WF2 (produção, n8n): novo nó `Regras adicionais (rodada 18/11 noite)` entre `Regras adicionais (rodada 18/11)` e `Ficha do que o cliente já respondeu`, com 3 regras: Q) sem negrito nem markdown; R) saudação e apresentação só na primeira resposta; S) avisar quando tamanho, quantidade ou acabamento da opção do catálogo difere do pedido (ex.: 10x14 pedido, 10x15 oferecido). O clone de teste do WF2 não recebeu o nó (estrutura diferente). A cópia em `n8n/GBH-WF2-Agente.json` não foi reexportada.
- Esclarecimento: a "resposta atrasada" vista no teste real não era falha do fluxo; o cliente mandou mensagem enquanto a rodada anterior ainda enviava, e as duas respostas se sobrepuseram.
- 18/11/2026 (noite, 2): `precos_modelo` com `gemini-3.5-flash-lite` (R$ 1,65 entrada e R$ 13,75 saída por 1 milhão, câmbio 5,5; US$ 0,30 e 2,50) e `gemini-3.1-flash-lite` (R$ 1,375 e R$ 8,25).
- WF1 (publicado, versão `14110da6`): o modelo forte também vale quando a mensagem tem fechar, pagar, pix, link, pedido ou comprar, ou medida (NxN com x ou ×, ou número seguido de cm), além das palavras de objeção. Cópia em `n8n/` não reexportada.
- Trava de resposta atrasada: já existe. `agente_pode_enviar_rodada` (chamada pelo WF1 antes de cada parte) devolve `mensagem_nova` quando chegou mensagem do cliente depois da mensagem gatilho. O caso visto no teste real foi uma corrida de menos de um segundo.
- Os workflows `GBH | TESTE | Agente (clone do WF2)` e `GBH | TESTE | Entrada de teste (clone)` continuam ativos: o teste ponta a ponta (`tests/e2e`) depende deles.
- ATENÇÃO n8n: editar um workflow ativo pelo MCP salva só um rascunho; é preciso publicar (`publish_workflow`). O WF2 tinha rascunhos de hoje (17:44 a 18:27) sem publicar; com autorização do dono, o rascunho completo (inclui as regras da noite) foi publicado em 18/11 como versão ativa `ed9006ea`.

## Rodada 19/11/2026: melhorias do checkout (/pagar)
- **Quantidades (carrossel):** `private.checkout_quantidades` agora devolve SEMPRE todas as tiragens do mesmo produto e versão (a janela antiga andava com a opção escolhida e as outras sumiam). Front em `Quantidades.tsx`: carrossel horizontal com encaixe, setas no desktop, opção escolhida centralizada, selo de economia dentro do cartão (não sobrepõe mais no celular).
- **Unidades e valor unitário:** resumo do checkout e PDF mostram "5 un. x R$ X cada" em vez de "1x" (`unidadesDoItem` em `ecommerce/lib/pagar.ts`; `unidadesReais` em `_shared/orcamento-html.ts`).
- **Cupom:** tabelas `cupons_checkout` e `cupons_checkout_uso`, RPCs `checkout_aplicar_cupom` e `checkout_remover_cupom` (validade, limite de usos, um por contato, não soma com condição especial, trava de piso e lucro bruto mínimo sobre produtos e arte). `VOLTEI5` (5%) já cadastrado. **Falta o dono cadastrar o código do cupom do panfleto de pós-venda** (inserir em `cupons_checkout`).
- **Frete por CEP:** ações `frete_cotar` e `frete_definir` em `checkout-dados`, que chamam `loja-frete` (bairros grátis e SuperFrete). Valor sempre cotado no servidor; vira item "Frete ..." de repasse (custo = valor), sincroniza orçamento e PDF, grava endereço do CEP no contato (só campos vazios). O Bling recebe o frete em `transporte.frete` (item de frete fica fora das mercadorias).
- **Busca e outra quantidade no checkout:** `BuscaProdutos.tsx` (usa `/api/v1/products/search`, escolhe a tiragem e adiciona; limite de 3 extras continua).
- **Celular:** barra fixa com total e "Ir para o pagamento", balão do WhatsApp acima dela, textos longos quebram, campos de 48 px.
- **Bling, indicador de presença:** a API v3 de pedido de venda NÃO tem campo de indicador de presença; o valor vem da configuração do Bling (Preferências > Vendas > NF-e/NFC-e). O dono precisa trocar lá de "5 - fora do estabelecimento" para "1 - operação presencial". O payload já leva `indicador_presenca: 1` para uso futuro.
- **Site (/checkout):** o carrinho do site já tem CEP e SuperFrete próprios; o cartão abre o `/pagar` (depois do passo 5 do deploy), onde valem cupom, tiragens, busca e frete. Pix do site segue no próprio fluxo.
- **Publicar:** migration `20261220000001`, deploy de `checkout-dados` e `orcamento-pdf`, merge para publicar a loja.

## Rodada 19/11/2026 (2): Black Friday e qualificação
Migration `20261221000001_black_friday_arte_gratis.sql` (aplicada), faixa e aviso na loja, nó novo no WF2 (cópia em `n8n/GBH-WF2-Agente.json`). Detalhes e como encerrar em `docs/agente/decisoes-e-melhorias.md` (seção Black Friday 2026). Sem cenários e5-*, mvp-* nem e17-* rodados (regra do dono: gastam o Gemini); validado por SQL (contexto, campanha, trava de saída) e leitura das conversas reais.

## Rodada 19/11/2026 (3): frete do cordão
Checkout dizia "não conseguimos cotar o envio" para pedidos com cordão: a embalagem do fornecedor tem até 162 cm (limite dos Correios: 100 cm) e `loja-frete` devolvia `pacote_grande` sem consultar o SuperFrete. Migration `20261222000001_frete_cordao_dobrado.sql` (aplicada): na categoria CORDÕES o pacote é dobrado até caber em 100 cm (altura x número de dobras). Bandeiras, banners, totens e afins continuam `pacote_grande` de propósito. O checkout agora explica o motivo (grande demais, tamanho a confirmar, a confirmar pelo WhatsApp ou indisponível) em vez da mensagem genérica. Vale conferir com a transportadora se 2 dobras no cordão atendem na prática.

## 20/11/2026 (item 7): confirmação de pagamento sem dado fiscal nem Praça Sete
- **Causa:** a mensagem de `cliente-pago-avisar` (texto livre, janela de 24 h) pedia CPF/CNPJ, nome/razão social, e-mail e endereço com CEP de quem ainda não tinha algum desses dados, e sempre citava o endereço fixo de retirada na Praça Sete — duplicado desde que o checkout próprio (`/pagar/<token>`, via `checkout-dados`) passou a coletar esses mesmos dados de Nota Fiscal direto no pagamento. A mesma mensagem também usava `coalesce(..., 'cliente')` como vocativo no nome (`pagamento_pos_reservar_msg`), o "Oi, cliente!" que outras correções de 20/11 e 22/12 já tinham banido em todo o resto do sistema.
- **Correção:** `montarConfirmacaoCliente`/`templateConfirmacaoCliente` (em `supabase/functions/_shared/alertas.ts`, usado também pela cópia autônoma em `cliente-pago-avisar/index.ts`) ficam no formato exato pedido pelo dono: "Oi, {nome}! Aqui é o João Victor da Sua Gráfica BH! Seu pagamento foi confirmado! Seu pedido {numero} já entrou na fila. Previsão de ficar pronto: {data_prevista}." Sem `faltaNota` nem trecho de retirada. `pagamento_pos_reservar_msg` (migration `20261222000009`) passa a devolver `nome` via `private.fu_nome(c.name)` (nulo sem nome válido) em vez de `coalesce(..., 'cliente')`; sem nome, a saudação cai para "Oi!" (texto livre) ou "você" (variável do template `pedido_pago_confirmacao`, que a Meta exige não vazia) — nunca "cliente" como vocativo.
- **Prompt da Laura:** regra "NOTA FISCAL E CADASTRO" do WF2 (nó "Prompt consolidado (Fase 1)", `n8n/GBH-WF2-Agente.json`) reescrita para dizer que o checkout próprio já coleta nome/razão social, CPF/CNPJ, endereço com CEP e e-mail, e que a Laura só pergunta pelo chat, depois de pago, o que ainda estiver faltando após o checkout (conferindo o cadastro do contato antes) — não pede mais tudo de novo por reflexo.
- **Deploy:** migration `20261222000009` aplicada, `cliente-pago-avisar` redeployada, WF2 publicado (versão `eed0aad4`) e reexportado para `n8n/GBH-WF2-Agente.json`. `scripts/test-alertas.ts` atualizado (formato exato, saudação sem nome, nenhum termo fiscal/Praça Sete na mensagem). Sem cenários e5-*/mvp-*/e12-*/e17-* (mudança determinística de texto/prompt, validada por `npm run gate` e leitura do jsCode ao vivo antes e depois do push).

## 23/11/2026: CAPI Etapa 1, Purchase do WhatsApp atribuído ao anúncio (pedido do gestor de tráfego)
- **Diagnóstico (30 dias):** 81 contatos novos, 35 com referral e 33 com `ctwa_clid`; 13 pedidos pagos, só 2 com anúncio (407 e 426), e os dois foram enviados à Meta SEM `ctwa_clid` e com `action_source = 'chat'` (valor que não existe na API). 12 Purchases enviados, 10 descartados por passar de 7 dias parados (segredos só entraram em 13/11), 0 erros. 4 pagos antes de 11/11 nunca geraram evento (gatilho ainda não existia). O EMQ 5,7 é só de eventos da loja (PageView e Lead); o Purchase não tem EMQ medido.
- **Feito:** migration `20261223000001_capi_purchase_whatsapp.sql` (aplicada) e `meta-conversions-api` redeployada. Purchase de chat agora sai como `business_messaging` + `messaging_channel = whatsapp`, com `ctwa_clid` (conversa, primeiro anúncio ou outro contato com o mesmo telefone) e `whatsapp_business_account_id` (segredo `WHATSAPP_WABA_ID`, adicionado na função). Sem `ctwa_clid` sai como `system_generated` (casa só por telefone com hash) e o motivo fica em `meta_eventos.motivo_sem_ctwa`. `event_id` = `purchase-<id do pagamento do Mercado Pago>`; valor = o que o Mercado Pago aprovou (cai no total do pedido no pagamento manual). Estorno nunca gera evento. Pagamento parcial não existe no fluxo: qualquer pagamento aprovado marca o pedido inteiro como pago, e a Meta vê o valor aprovado.
- **Falta (etapas seguintes):** Etapa 2, eventos antes da compra (Lead no primeiro contato do anúncio e InitiateCheckout no link de pagamento, só com `ctwa_clid` e até 7 dias do clique); Etapa 3, relatório diário e conferência de pagos x `meta_eventos`. Decisão pendente do dono: reenviar os Purchases dos pedidos 407 e 426 com `ctwa_clid` (426 vale até 27/11).

## 23/11/2026: CAPI Etapa 2, eventos antes da compra (WhatsApp) e reenvio dos Purchases 407 e 426
- **Reenvio (decisão do dono):** 426 e 407 reenviados com `ctwa_clid` (clique em 19/11 e 17/11, aprovação dentro de 7 dias), `event_id` `purchase-<id do pagamento>`. O motivo está em `meta_eventos.motivo` nas linhas novas e nas antigas (`substituido_por ...`). A Meta pode contar duas vendas por pedido (o envio antigo sem `ctwa_clid` casa só por telefone); o antigo não tem como ser apagado pela API.
- **Eventos escolhidos:** `LeadSubmitted` (nome que a Meta documenta para Business Messaging; trocável em `app_settings.meta_capi.lead_chat_evento`) no primeiro `ctwa_clid` do contato (`event_id` `lead-<contato>`, gatilho em `contacts`) e `InitiateCheckout` quando o link de pagamento é gerado (`ic-<pedido>`, gatilho em `pagamentos` com `eh_link`). Fora do pacote de propósito: orçamento enviado (automático, infla volume sem intenção) e arte recebida (só chega depois do pagamento).
- **Regras:** só com `ctwa_clid`; clique com mais de 7 dias grava a linha como `descartado` com o motivo (auditoria); números e contatos de teste nunca geram evento (`private.meta_eh_teste`); pedido do site não entra (o Pixel já cobre). Gatilhos nunca bloqueiam contato, link nem pagamento.
- **Preenchimento inicial:** 31 leads e 17 links dentro dos 7 dias do clique entraram na fila na migration `20261223000002_capi_eventos_antes_da_compra.sql` (aplicada). Ritmo esperado com base nos últimos 30 dias: cerca de 8 leads e 3 links por semana.
- `meta-conversions-api` (versão 17) manda chat e site em lotes separados: um evento recusado de um lado não derruba o outro.
- Atenção: o agendamento `meta-conversions` roda a cada 5 minutos, não a cada 1 (a migration da Fase 7 dizia 1 minuto).
- **Falta (Etapa 3):** relatório diário, conferência de pagos x `meta_eventos`, investigação dos 11 compradores sem referral (taxa de compra por origem e tempo até o pagamento) e a proposta de registrar a origem de quem chega sem referral.
