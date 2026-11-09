# Decisões e melhorias (Etapa 7B)

Documento vivo. A seção 1 vale como regra. A seção 2 é pendência do dono, nunca regra. A seção 3 é o inventário do Passo 0 (o que já existia, o que era parcial e o que faltava) e o andamento por bloco.

## 1. Decisões já definidas (valem como regra)

- Pix: o agente SEMPRE oferece o Pix primeiro (0,99%), avisando que pode ser pago em qualquer banco. Desconto específico para Pix só depois de ver dados reais.
- Taxas Mercado Pago na conta do dono: cartão de crédito 4,98%, saldo, linha de crédito e pré-pago 4,99%, Pix 0,99%, Open Finance 0%, boleto desligado. Já aprovado: até 2x SEM juros nos links, para todos os pedidos.
- Parcelamento: o agente NÃO divulga o 2x sem juros em todo atendimento (consome margem). Usa só quando o cliente pergunta sobre parcelar ou demonstra hesitação por valor. Parcelas acima de 2x só se o dono decidir e, nesse caso, com juros repassados ao cliente e avisados antes.
- Nota fiscal: a empresa emite sempre que o cliente quiser.
- Prazo: o oficial, nunca alterado pelo agente. A contagem do prazo de entrega começa na APROVAÇÃO DA ARTE. Cliente com urgência recebe selo de urgência no CRM para ser atendido na frente, sem mudar o prazo oficial e sem prometer data não confirmada.
- Pedido só é considerado ATRASADO se já foi para produção e não foi entregue dentro do prazo útil.
- Reclamação ou problema: chama o dono (com resumo). O sistema deve resolver tudo o mais sozinho e o dono só assume após o pagamento.
- Pedido manual no CRM: o dono escolhe explicitamente o método de pagamento. O sistema não pode presumir crédito nem cobrar taxa não correspondente (bug já ocorrido).
- Orçamentos com 3 opções (econômica, intermediária, premium) para ancorar preço, sempre com diferenças reais do catálogo.
- Taxas devem estar embutidas no preço final calculado, de modo que o lucro líquido mínimo seja respeitado qualquer que seja o método.
- A empresa é tratada por setores (Comercial, Arte, Financeiro): o agente encaminha cada demanda ao setor certo e, sempre que possível, o próprio sistema executa a tarefa do setor.
- Encaminhamento BauerLab: quando o cliente precisar de site, marca, presença digital, divulgação ou anúncios, o agente apresenta a BauerLab (agência de sites, landing pages, lojas virtuais, identidade visual, design, redes sociais, tráfego pago e Google Meu Negócio) e passa o contato de João Victor, +5531998021169. Uma vez, sem insistir, e sem atrapalhar a venda em andamento.
- Dados do cliente: pedir só o que falta, nunca repetir o que já foi dito; usar os campos que o CRM já tem (nome, empresa, segmento, e-mail, CPF ou CNPJ, endereço, notas, consentimento de promoções). Pedir CPF ou CNPJ e endereço apenas quando o cliente quiser nota fiscal ou entrega. Consentimento de promoções é pedido separado e NUNCA presumido.
- Tom: humano, vendedor nato. Emoji com moderação, abreviações naturais como "vc" sem erro de português, "kkkk" ou "rsrs" só quando o cliente abrir espaço; em reclamação ou assunto sério, tom profissional.
- Agrupamento de mensagens: o agente espera 10 segundos; se chegar outra mensagem, reinicia a contagem; responde uma vez só com todo o contexto.
- Preço abaixo do piso duro (09/11/2026): liberação INTENCIONAL só para o dono logado, no pedido, com confirmação e motivo registrados em `precos_manuais_log` (faixa `abaixo_piso_duro`). Agente, n8n e service role continuam bloqueados. Migration `20261115000001` ajusta a restrição do log.
- Avaliação no Google (ver Bloco B, item 8): link https://g.page/r/CZ6eNNGjdgO4EBM/review.

## 2. Pendências que dependem do dono (não tratar como regra)

Política de troca e reembolso; benefício do programa de indicações (se houver); se o parcelamento acima de 2x será oferecido; confirmação de que o contato da BauerLab é o telefone informado; limite diário de fotos e outros parâmetros que o dono ajustar.

## 3. Inventário do Passo 0 (01/11/2026)

Legenda: JÁ FEITO, PARCIAL, FALTANDO. Evidência = arquivo, tabela ou workflow.

### Bloco A: proteger a operação
| # | Item | Estado | Evidência |
|---|---|---|---|
| A1 | Taxas por método e piso na pior taxa | PARCIAL | `parametros_comerciais.taxas_pagamento` (pix, cartão, saldo, linha, pré-pago, open finance, boleto) e `metodo_piso`; faltava 2x sem juros, débito, dinheiro, transferência e a taxa REAL (`fee_details`) no pedido |
| A2 | Taxa embutida no preço ("por dentro") | JÁ FEITO | `private.receita_para_lucro` divide por `1 - imposto - taxa`; falta só a tabela de taxa por método no orçamento interno |
| A3 | Link alinhado (2x sem juros, boleto off) | PARCIAL | `_shared/mp.ts` já exclui boleto e lotérica; faltava limitar parcelas |
| A4 | Pedido manual com método obrigatório | FALTANDO | `OrderDrawer` aceita método "Não definido"; `Kanban.confirmPaid` gravava `manual` e deixava 4,98% |
| A5 | Exclusão de pedidos com auditoria | FALTANDO | nenhuma coluna de exclusão lógica |
| A6 | Atraso só em produção, selo de urgência | PARCIAL | `Orders.tsx` marcava atrasado qualquer pedido pago desde `pago`; sem urgência |
| A7 | Teste da trava de lucro em todos os caminhos | PARCIAL | `scripts/test-rules.ts` existe (preço, kanban, login); `preco_etapa3.sql` tem a simulação em massa; faltava varrer todos os caminhos com taxa por método |
| A8 | Varredura do nome do fornecedor | PARCIAL | `npm test` já bloqueia o nome; ampliada para variações de grafia e `docs/agente/` |
| A9 | `docs/credenciais-n8n.md` | FALTANDO | só a tabela em `docs/n8n-mapa.md` |
| A10 | WF9 ligado a todos | PARCIAL | WF9 criado (`vmaMVnZydmHpkW57`), desligado e sem ligação |
| A11 | Higiene de segurança | PARCIAL | advisors lidos; senhas vazadas ainda desligada; backup `private.bkp_products_etapa2` existe |
| A12 | Prazo em uma só implementação | PARCIAL | `calcular_prazo` e `private.prazo_data` usam `add_business_days`; auditar uso |

### Bloco B: agente, conversa e conversão
| # | Item | Estado | Evidência |
|---|---|---|---|
| B1 | Debounce de 10 s com prolongamento | PARCIAL | `agente_debounce` existe com 8 s (`agente_config.debounce_segundos`) |
| B2 | Tom humano de vendedor | FALTANDO | sem `docs/agente/tom-e-vendas.md` |
| B3 | Dados e CRM, consentimento separado | PARCIAL | `salvar_contato` e `marketing_consent` existem; falta regra "só o que falta" no prompt |
| B4 | Pix primeiro e parcelamento estratégico | FALTANDO | conhecimento cita Pix; sem regra de 2x |
| B5 | Três opções de orçamento | FALTANDO | `montar_orcamento` devolve uma opção |
| B6 | Setores e escalonamento | FALTANDO | sem coluna `setor` nem `encaminhar_setor` |
| B7 | Proteção contra promessas indevidas | PARCIAL | `agente_saida_segura` barra R$ e vazamentos; faltam pagamento, arte, produção, data e reembolso |
| B8 | Avaliação no Google e cupom de recompra | FALTANDO | WF7 pede satisfação, sem link nem cupom |
| B9 | Recuperação por motivo de perda | FALTANDO | sem `motivo_perda` |
| B10 | BauerLab | FALTANDO | sem trecho nem tabela |
| B11 | Validador de pedidos | PARCIAL | triggers de Produção exigem SKU e arte; sem lista de pendências |

### Bloco C: preço por dimensão
FALTANDO. Sem `catalogo_formulas` nem workflow de consulta.

### Bloco D: inteligência comercial
| # | Item | Estado | Evidência |
|---|---|---|---|
| D1 | Atribuição e painel Comercial | PARCIAL | `first_referral`, `ad_performance`, `origin_ad_id`; sem painel Comercial nem `docs/metricas.md` |
| D2 | Recompra por comportamento | PARCIAL | WF7 com intervalos padrão |
| D3 | Complementares | FALTANDO | |
| D4 | Rentabilidade por cliente | FALTANDO | `contact_stats` sem margem |
| D5 | WF11 Estudo diário | FALTANDO | |
| D6 | Experimentos | FALTANDO | |
| D7 | Indicações | FALTANDO | |
| D8 | Backlog | FALTANDO | `docs/backlog.md` |

### Bloco E: redes sociais
FALTANDO.

### Bloco F: infraestrutura
PARCIAL. `infra/searxng`, `infra/renderer` e `docs/agente/infra-busca.md` existem; faltam `docs/infra-coolify.md` e o teste ponta a ponta.

## 4. Andamento por bloco

Ver `docs/agente/progresso.md`, seção "Etapa 7B".
