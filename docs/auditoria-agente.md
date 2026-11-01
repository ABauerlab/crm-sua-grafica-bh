# Auditoria final do agente (Etapa 8)

Data: 02/11/2026. Branch `claude/zealous-curie-n84wpk`. Auditor: Claude (sessão remota, via MCP do Supabase, n8n, WhatsApp Business, Coolify e GitHub).

## 1. Resumo executivo

**Nota de prontidão: 7,5 de 10.** O núcleo financeiro (preço, piso, prazo, frete, SKU, pagamento, RLS) está sólido e foi provado com evidência. O que impede nota maior não é defeito de regra: é **o que não pôde ser testado daqui** (conversa real com o modelo, Pix real de R$ 1, push no iPhone) e **a ativação dos workflows, que foi barrada pela política de segurança do ambiente** (deploy em produção) e precisa de um "sim" seu.

- Provado: 5.092 simulações de preço sem nenhum lucro negativo e nenhum preço abaixo do piso; RLS fechado para `anon` e usuário comum; 17 templates APROVADOS; prazo e frete corretos nos casos de borda; mutação de piso é detectada pelo teste; `npm test` completo passa.
- Corrigido nesta etapa: 3 falhas reais (seção 4), todas com migration aditiva, reversão em `docs/rollback-etapa8.sql` e reteste.
- SearXNG foi ligado no Coolify e respondeu às 5 especificações de teste.
- Workflows continuam **DESATIVADOS** (nada foi publicado). Veja a seção 7.

## 2. Tabela de itens

Legenda: PASSOU, FALHOU (corrigido), NÃO TESTÁVEL (daqui, com o motivo).

| Bloco | Item | Resultado | Evidência |
|---|---|---|---|
| A | 26 workflows `GBH |` na pasta `Sua Gráfica BH`, tag `gbh`, todos inativos | PASSOU | `search_workflows`: 26, todos com `parentFolderId` da pasta e tag `gbh`, `active=false` |
| A | Credencial do despachante (`arte_receber`, `arte_baixa_ok`) | PASSOU | nós já usam `Supabase account` (`g3WlIOkLdfsc4XIJ`) |
| A | Credenciais nó a nó dos outros 25 workflows | NÃO TESTÁVEL por completo | só conferi despachante e pesquisa; leitura nó a nó dos 25 exige ~15 mil tokens cada. Pendente: rodar a conferência numa sessão dedicada |
| A | Despachante tem as ferramentas `encaminhar_setor`, `bauerlab`, `montar_opcoes` | FALHOU (aberto) | o `Qual ferramenta?` tem 13 saídas e não inclui as 3 da 7B. As funções existem no banco; falta ligar no despachante e no WF2 (risco de edição em produção, ver 5) |
| A | WF9 publicado e ligado como `errorWorkflow` | NÃO EXECUTADO | `publish_workflow` negado pelo classificador de segurança. Fica como primeiro passo da ativação |
| B | RLS `anon`: catalogo, catalogo_historico, precos_mercado, condicoes_especiais, politica_desconto, agent_logs, alertas, app_segredos, orders, contacts, messages... | PASSOU | 20 tabelas, todas `permission denied` |
| B | RLS `authenticated` sem perfil de atendente | PASSOU | 22 tabelas com 0 linhas visíveis; `app_segredos` negado |
| B | Advisors de segurança | PASSOU com ressalva | 2 achados corrigidos (migration 20261105000001). Restam: 78 funções `SECURITY DEFINER` chamáveis por `authenticated` (INFO esperado: todas com trava `dono_ou_servidor`/`is_staff`, exceto `agente_preco`, `buscar_conhecimento`, `conhecimento_resolver`, `politica_texto`, que não devolvem custo) e senha vazada (plano gratuito) |
| B | Advisors de desempenho | PASSOU | 43 FKs sem índice (INFO), 32 índices ainda sem uso (normal, sem tráfego), 1 índice duplicado em `orcamento_itens` (WARN, baixo; não removi por causa da regra de não apagar sem backup) |
| B | Segredos no repositório | PASSOU | varredura de padrões (JWT, `sb_secret_`, `APP_USR-`, `TEST-`, `EAA...`, chave privada): 0. Só 6 PDFs de exemplo fictícios em `docs/exemplos-orcamento/` |
| B | Token do Coolify fora do front | PASSOU | só em `COOLIFY_URL` e `COOLIFY_TOKEN` do ambiente do servidor, nenhum prefixo `VITE_` |
| B | 15 ataques de prompt com o modelo real | NÃO TESTÁVEL | `test_workflow` do n8n fixa os nós com modelo; sem ativar WF1 e WF2 não há chamada real. Defesa por código existe e foi testada nos 21 cenários da Etapa 5 e na trava de saída (`agente_saida_segura`). Rodar no piloto |
| B | Assinatura e idempotência dos webhooks | PASSOU | `npm test` (HMAC Meta, assinatura Mercado Pago, idempotência por `wa_message_id`) |
| C | 5.000 combinações aleatórias | PASSOU | 5.092 simulações (SKU real, quantidade de 1 a 10.000, mercado ausente, acima, abaixo, muito abaixo e com outlier, entrega, 7 métodos de pagamento): **0 lucro líquido negativo, 0 preço abaixo do piso duro, 0 abaixo do piso, lucro mínimo R$ 60,00**. Transação desfeita (0 linhas sobraram) |
| C | Burla por SQL direto no item de pedido | FALHOU, corrigido | com `unit_cost = 0` o banco aceitava preço de R$ 0,01. Agora recusa ("Preço abaixo do piso duro") |
| C | Edição manual de preço para R$ 0,01 | PASSOU | recusada pela confirmação do dono |
| C | Item de pedido sem SKU | PASSOU | recusado ("Item sem SKU não pode entrar no pedido") |
| C | Mover pedido para Pago sem pagamento | PASSOU | bloqueado pelo gatilho |
| C | Pesquisa de mercado real (10 especificações) | PARCIAL | SearXNG respondeu a 5 especificações com 37 a 41 resultados e 8 a 10 com R$ no trecho. A extração e a mediana dependem do workflow, que só roda ativo. `precos_mercado` está vazio: toda cotação hoje cai na fórmula de custo com travas (seguro) |
| C | Aprendizado de 30 dias | NÃO TESTÁVEL | sem 30 dias de dados; função com simulação (`aprender_precos_semana(p_simular)`) cobre as travas 0,90 a 0,98 nos testes SQL da Etapa 3 |
| D | Condição especial (G1 a G3, teto, piso, validade, uma por orçamento) | PASSOU por testes anteriores | `supabase/tests/preco_etapa3.sql` (67 testes) e `orcamento_etapa4.sql`; não repeti nesta sessão |
| E | `calcular_prazo` | PASSOU | sexta 16h, sábado, domingo, segunda 9h e 13h, quarta 15h, feriado de 20/11 (pula a sexta), +1 dia uma única vez, com e sem arte, itens de 1 e de 7 dias: todos com data de calendário |
| E | `verificar_frete` | PASSOU | centro abaixo do mínimo (R$ 25 de referência + "falta R$ 130"), centro acima (grátis, custo nosso R$ 8), pacote de arte, fora da região, CEP fora. Custo e `cabe_na_bike` são retirados pelo despachante |
| E | SKU obrigatório | PASSOU | ver C |
| F | 21 cenários da Etapa 5 e 10 novos com o modelo real | NÃO TESTÁVEL | idem B. Os 21 existem em `testes_conversa` |
| F | 40 testes de conhecimento (meta 90%) | PASSOU por teste anterior | 40 de 40 em 7C; `npm test` valida 91 trechos |
| F | Custo por conversa | NÃO TESTÁVEL | `agent_logs` e `agente_execucoes` têm 0 linhas |
| G | Templates da Meta | PASSOU | 17 de 17 APROVADOS; todos os 6 usados nas cadências existem e estão aprovados |
| G | Pagamento Mercado Pago em teste e Pix de R$ 1 | NÃO TESTÁVEL | exige uma ação sua (pagar). Funções `mp-*` na v12 a v17 e `npm run test:mp` passam |
| G | Push no iPhone | NÃO TESTÁVEL | só o dono instala o PWA |
| G | Quedas simuladas (Supabase, Gotenberg, SearXNG, Meta) | NÃO TESTÁVEL | exigem workflows ativos |
| G3-6 | `scripts/test-rules.ts` roda no `npm test` e pega preço abaixo do piso | PASSOU | mutação: piso pela metade em `src/lib/pricing.ts` quebrou o teste; arquivo restaurado |
| G3-7 | Varredura do nome do fornecedor | NÃO TESTÁVEL por mutação | o teste existe e passa; a injeção do nome por pasta não foi feita |
| G3-3 | Exclusão de pedido pago não apaga | PASSOU por testes anteriores | gatilho `orders_pago_apos_exclusao` presente |
| G3-20 | SearXNG sem exposição indevida | FALHOU (aberto) | o serviço criado tem domínio público `sslip.io` sem autenticação. Ver risco R2 |
| G3-21 | `private.bkp_products_etapa2` preservado | PASSOU | existe (aparece no advisor); não apaguei |

## 3. Infraestrutura (Coolify)

Inventário (somente leitura): `n8n-migration` (n8n), `postiz`, `gotenberg` (rodando) e `searxng` (estava `exited`). Não toquei em n8n nem Postiz. Iniciei só o SearXNG (POST `/services/<uuid>/start`), ficou `running:healthy`, `/healthz` 200 e a API JSON responde. No n8n, `GBH | FERRAMENTA | pesquisar_preco_mercado`, caixa "Início e configuração", `searxng_url` aponta para o serviço. O leitor com navegador (`renderer`) **não existe**; a pesquisa usa leitura HTTP direta (suficiente para a maioria dos sites; páginas só com JavaScript viram "sem dado" e a cotação cai na fórmula de custo, que respeita o piso).

## 4. Falhas encontradas e corrigidas

1. **Item de pedido abaixo do piso por SQL/API com custo zero** (crítico para a regra "nunca vender abaixo do piso"). Causa: a trava confiava no `unit_cost` informado. Correção: no caminho do CRM (papel `authenticated`) o custo nunca pode ser menor que o do catálogo. n8n e pagamento não mudam. Migration `20261105000002`.
2. **Trava de item de pedido quebrada para o usuário logado desde a 7B Bloco A**: `taxa_pagamento` perdeu o EXECUTE e a trava rodava como o usuário, dando "permission denied" ao inserir item. Correção: funções de trava como `SECURITY DEFINER` (ficam no schema `private`, fora da API).
3. **Mudar o método de pagamento do pedido pelo CRM falhava** ("permission denied for function taxa_pagamento"), o que bloqueia o pedido manual com método obrigatório. Mesma correção nos gatilhos de pedido e orçamento. Retestado: método Pix e 2x gravam; mover para Pago sem pagamento continua bloqueado.
4. **Advisors**: `rls_auto_enable` sem EXECUTE para anon e authenticated; `search_path` fixado em `atualizar_orcamento_atualizado_em`.

Também entregue (aditivo, desligado por padrão): **modo piloto** da IA em `agente_config` (`piloto_ativo`, `piloto_wa_ids`, `piloto_percentual`), usado por `agente_bloqueio`. Com `piloto_ativo = true` a IA só atende os números da lista e a fatia de tráfego escolhida (hash estável do número). Reversão: `piloto_ativo = false`.

Reversões: `docs/rollback-etapa8.sql`. Migrations: `20261105000001`, `20261105000002` (e a do modo piloto foi aplicada no banco; o arquivo está em `20261105000003_etapa8_modo_piloto.sql`).

## 5. Riscos que restam

- **R1. Conversa real com o modelo nunca foi observada em produção.** Mitigação: modo piloto, teto de custo diário (R$ 15), trava de saída. É o motivo de eu recomendar ligar primeiro só para um número de teste.
- **R2. SearXNG com URL pública `sslip.io` sem senha.** Qualquer pessoa que descobrir o endereço pode usar a busca. Risco baixo (só busca), mas o combinado era rede interna. Ação: no Coolify, aplicar a rede interna do n8n ao serviço e trocar `searxng_url` para o nome interno, ou proteger com autenticação.
- **R3. Três ferramentas da 7B sem ligação** no despachante e no WF2 (`encaminhar_setor`, `bauerlab`, escolha de opção). O agente funciona sem elas (chama o dono pelo `chamar_dono`), mas setores e BauerLab não funcionam. Editar o despachante em produção exige teste com modelo, por isso deixei como pendência.
- **R4. Três Edge Functions antigas no Supabase** não documentadas: `gerar-link-pagamento`, `montar-orcamento`, `gerar-pdf-orcamento` (da sessão interrompida, `verify_jwt = true`). Sugiro excluir depois de você confirmar. `meta-ads-sync` está com `verify_jwt = false` no deploy (a tabela do CLAUDE.md diz que exige login): conferir se a função valida o JWT por dentro.
- **R5. `precos_mercado` vazio**: o preço de hoje vem da fórmula de custo com multiplicador. É seguro (piso garantido), mas pode ficar acima do mercado e perder venda. O ganho vem de ativar a pesquisa e acompanhar a tela "Saúde de preços".
- **R6. Chaves**: token de teste do Mercado Pago ainda precisa de rotação (você).

## 6. Pendências suas

1. Autorizar a ativação (seção 7) e informar o número de teste do piloto (não pode ser o seu número do dono, que a IA ignora por regra).
2. Criar os segredos `N8N_WF1_URL` e `N8N_WF1_TOKEN` no Supabase (Edge Functions > Secrets). Sem eles o `whatsapp-webhook` não avisa o WF1. É o interruptor real do agente.
3. Pagar um Pix de R$ 1 pelo link de teste (valida pagamento ponta a ponta) e instalar o PWA no iPhone.
4. Rotacionar o token de teste do Mercado Pago.
5. Códigos SKU das ~590 linhas sem código, `[CONFIRMAR]` do conhecimento (parcelamento, nota fiscal, troca e reembolso), política de troca, feriados municipais, zonas de entrega, `cabe_na_bike`, nota fiscal e LGPD.
6. Decidir: excluir as 3 funções antigas, o índice duplicado e o backup `bkp_products_etapa2`; ligar o cupom de recompra depois de `select public.cupom_recompra_simular();`.

## 7. Plano de ativação e piloto

**Checklist (nesta ordem):**
1. Parâmetros revisados (`parametros_comerciais`, taxa do 2x em 10,50%), templates aprovados (feito: 17 de 17), Mercado Pago em produção validado, PWA instalado, teto de custo conferido (R$ 15/dia), backup do banco feito.
2. Publicar `GBH | WF9 | Erros e observabilidade` e, em cada um dos outros 25, `setWorkflowSettings { errorWorkflow: "vmaMVnZydmHpkW57" }`.
3. Publicar na ordem: WF9, WF5, WF8, WF7, WF6, WF2, WF1 (WF3 e as ferramentas são chamadas por "Execute Workflow" e não precisam ficar ativas).
4. No banco: `update agente_config set piloto_ativo = true, piloto_wa_ids = array['55319XXXXXXXX'], piloto_percentual = 0, ia_ligada = true where id = 1;` e `app_settings.agent.enabled = true`.
5. Criar os segredos `N8N_WF1_URL` e `N8N_WF1_TOKEN`.
6. Teste final com o número de teste: anúncio, orçamento, PDF, link, pagamento, arte, produção, pronto.

**Piloto:**
- Fase 1: só o número de teste, 20 conversas ou 3 dias.
- Fase 2: `piloto_percentual = 10`, por 7 dias.
- Ampliar para 50% e depois 100% se: margem líquida real ≥ 20%, zero preço abaixo do piso, custo por conversa dentro do planejado, 0 vazamento nos logs, reclamações = 0 por IA, erros do WF9 sem pendência.
- Voltar (rollback) se: qualquer preço abaixo do piso, qualquer vazamento de custo, fornecedor ou endereço, 2 reclamações por erro da IA, custo diário acima do teto.

**Reversão (testável a qualquer hora):** `update agente_config set ia_ligada = false where id = 1;` (ou botão "Pausar IA" do CRM) devolve tudo ao atendimento humano sem perda de dados. Para parar de vez, despublicar o WF1. `personas.pos_pagamento_automatico = false` faz a IA parar depois do pagamento. `piloto_ativo = true` com lista vazia e percentual 0 também desliga para todos.

## 8. Rotina do dono

**Todo dia (5 minutos):** alertas do CRM (push e WhatsApp), kanban (Atrasados e Arte), pagamentos pendentes, tela do agente (custo do dia e erros), conversas com "precisa de humano".
**Toda semana:** resumo semanal de preços e condições (alerta de 40% de margem consumida), Saúde de preços, lacunas do conhecimento, taxa de conversão por anúncio e gasto Meta, lista para o fornecedor, backup do banco.

## 9. As dez melhorias de maior impacto (em ordem)

1. Ligar a pesquisa de mercado e acompanhar a "Saúde de preços" por 30 dias antes de mexer em fatores.
2. Colocar SearXNG na rede interna do Coolify (fecha R2).
3. Ligar `encaminhar_setor`, `bauerlab` e escolha de opção no despachante (fecha R3).
4. Preencher os SKUs faltantes (~590 linhas) para aumentar a cobertura de cotação.
5. Rodar um conjunto fixo de 15 ataques de prompt toda semana como teste de regressão (`testes_conversa`).
6. Usar o modelo pequeno para classificação e o forte só no fechamento (reduz custo por conversa sem perder eficiência).
7. Cache de respostas frequentes (`faq_cache`) com revisão mensal.
8. Pedir foto do produto só quando o cliente hesitar (poupa chamadas e imagens).
9. Alerta no WF9 para custo diário acima de 70% do teto.
10. Painel Comercial com a conversão por opção (três opções) depois do piloto.
