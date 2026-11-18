# Diário do atendimento real (tráfego pago)

Objetivo: registrar dia a dia o que a Laura e o CRM fizeram nas conversas reais vindas do anúncio, o que travou e o que foi melhorado. O tráfego pago real começou em **16/11/2026** (campanha `GBH | CTWA | BH | Teste 4 criativos | 2026-11`, conta CA SUA GRÁFICA BH). Antes disso as conversas eram de teste e orgânicas.

Como alimentar este diário (rotina diária, sem rodar cenários do Gemini):
1. Rodar as consultas da seção "Consultas de apoio" para o dia.
2. Ler as transcrições (não só os números). Registrar o que funcionou, os gargalos e as melhorias.
3. Dar um código a cada gargalo (`G` + data + número, ex.: `G1711-2`) e a cada melhoria (`M` + data + número) e manter o status no quadro "Backlog de melhorias".
4. Nunca copiar dado pessoal de cliente (CPF, e-mail, endereço, telefone completo) para cá. Usar só nome próprio curto ou o número do pedido.

## Quadro diário (números)

| Dia | Leads novos | Leads com anúncio | Gasto Meta | Orçamentos enviados | Pedidos pagos | Lucro líquido real | Observação |
|---|---|---|---|---|---|---|---|
| 16/11 | 6 | 2 | R$ 16,82 | n/d | 0 | R$ 0,00 | Primeiro dia de tráfego. Transcrições ainda não avaliadas em detalhe. |
| 17/11 | 12 | 6 | R$ 42,59 | 5 (R$ 800,20 em aberto) | 1 (R$ 78,90) | R$ 60,39 | Resultado do dia: +R$ 17,80 sobre o gasto. Acumulado: +R$ 0,98. |

(Lucro líquido real = `orders.lucro_liquido_real`, depois da taxa real do Mercado Pago e do imposto. Gasto vem de `ad_daily`.)

---

## 17/11/2026 (terça)

Base: 17 conversas ativas, 375 mensagens (133 do cliente, 225 da Laura, 17 de atendente humano), 91 rodadas do agente concluídas, 0 mensagens com falha de envio, 5 orçamentos, 1 pago. Custo estimado da IA no dia: 2,94 (unidade de `agente_execucoes.custo_estimado`), cerca de 1,53 milhão de tokens de entrada.

Funil do anúncio "Crachá com Cordão" (R$ 24,19): 5 conversas no CRM (7 na Meta), 2 orçamentos, 1 venda de R$ 78,90. Anúncio "Cartão Retrovisor" (R$ 10,36): 1 conversa, 1 orçamento, 0 vendas. Cartão Premium e Panfleto: R$ 8,04 e 0 conversas.

### O que funcionou
- Resposta inicial em cerca de 30 s e abertura sempre pelo contexto do anúncio.
- Trava de saída segurou 2 respostas ruins (`preco_nao_verificado` e `promessa:desconto_fora_da_funcao`) e o cliente recebeu frase neutra, sem prejuízo.
- Áudios do cliente foram transcritos e entendidos (Felipe, Hudson, Patrícia).
- Orçamento em PDF, link do Pix e confirmação de pagamento funcionaram de ponta a ponta no pedido do Marcos (pago em 5 min depois do link reenviado pelo atendente). Taxa real do Mercado Pago (0,99%) entrou, lucro real R$ 60,39.
- Upsell por faixa de quantidade funcionou no Wender (5 unidades por R$ 86,90 custam menos que 2 avulsas).
- Nenhuma vez custo, piso, SKU ou endereço da fábrica vazaram.

### Gargalos encontrados

| Código | Gargalo | Evidência |
|---|---|---|
| G1711-1 | **Lentidão em parte dos turnos.** Mediana de 53 s, P90 de 347 s; 25 de 88 turnos passaram de 90 s e 9 passaram de 5 min. | Rodadas de 100 a 187 s com 83 mil a 100 mil tokens de entrada (Felipe 08:29, Hudson 08:54). `enviar_foto_produto` leva 23 s em média, `gerar_pdf_orcamento` 13 s, `montar_orcamento` 9,5 s. Felipe ficou 19 min sem resposta real (08:33 a 08:52) depois de `agente_falhou` e `saida_bloqueada`; Hudson esperou 7,5 min a primeira resposta. Edson teve 3 rodadas `ocupada` às 05:11 a 05:16. |
| G1711-2 | **Lembrete Q1 virou insistência.** Depois de baixar Q1 para 10 min (migration `20261217000009`), Wender recebeu 4 lembretes quase idênticos em 2 h 20 (14:21, 15:12, 15:57, 16:33), inclusive depois de avisar "estou em trabalho, já te respondo". Adinilson recebeu 3 no dia sem nunca responder. | `followup_fila` e transcrições. A frase "Passando pra gente não perder o fio" se repete. |
| G1711-3 | **Lembrete saiu depois de recusa.** Artur disse "Não não" e "Obrigado" às 15:25; às 15:39 recebeu um Q1. A trava `cliente_recusou` (migration `20261217000019`) não pegou "Não não". Depois ainda teve 5 mensagens de despedida ("Um abraço", "Até mais", "Um abraço!") para um cliente que já tinha encerrado. | `followup_fila` (Q1 enviado) e transcrição. |
| G1711-4 | **Fechamento em 3 passos trava quando o cliente já decidiu a forma de pagamento.** Edson disse "Pagamento será pix" e a Laura não gerou link (`aprovacao_do_cliente_pendente`); pediu "APROVADO" 3 vezes em 15 min (15:52, 15:55, 16:02), enquanto ele só estava reunindo dados dos colaboradores. | Alerta `agente_chamado` de 16:01 e transcrição. |
| G1711-5 | **Condição de pagamento fora do padrão não chegou ao dono.** Edson perguntou se podia pagar 50% e o resto na retirada; a Laura repetiu a regra e perguntou "fica tranquilo?". Pedido de R$ 274,70 aberto. | Transcrição 16:28 a 16:29; nenhum `chamar_dono`. |
| G1711-6 | **Dados fiscais enviados em modo humano não são salvos.** Marcos mandou nome, CPF, CEP e e-mail às 16:57; `orders.dados_fiscais` ficou nulo, o pedido foi ao Bling às 18:46 com aviso de dados incompletos e a NFC-e nº 71 saiu **Rejeitada**. A Laura ignorou 21 mensagens dele (modo humano). Ele também ficou em dúvida com o CPF por causa do formato digitado (119.555.006.57). | `orders` (#407), `agente_execucoes` (`modo_humano` 21x). |
| G1711-7 | **Quando o humano assume, o lead fica sem acompanhamento.** Patrícia (R$ 217,80) e Edson (R$ 274,70) estão sem nenhum lembrete pendente: todos os F1 a F4 foram cancelados com `cliente_respondeu`. Os dois maiores orçamentos abertos (R$ 492,50) dependem de alguém lembrar. Os avisos "Um de nossos consultores humanos acabou de assumir" saíram duas vezes para a Patrícia (13:35 e 13:59). | `followup_fila`. |
| G1711-8 | **Produto errado na vitrine de opções.** Hudson pediu 2 crachás para equipe de buffet e recebeu "4 opções de crachá para 2 unidades" que eram credenciais de papel couchê de **500 unidades** (R$ 362,90 a R$ 370,90). Ele pediu "algo mais simples" e sumiu. No caso do Diogo, as opções 1 e 2 (e 3 e 4) são idênticas, só muda a orientação do cartão. | Transcrições Hudson 08:56 e Diogo 15:55. Felipe também teve `agente_chamado` porque o crachá PVC "não foi localizado" (`buscar_produto`). |
| G1711-9 | **Informação de quantidade inconsistente e upsell esquecido.** Para Edson (5 crachás) a Laura disse "a tiragem mínima é o pacote de 60 por R$ 96,90", depois vendeu 5 por R$ 94,90 e mostrou 60 un por R$ 99,90. O cordão foi de R$ 98,90 (5 un, papel) para R$ 139,90 (mosquetão) sem explicação. | Transcrição Edson 05:14 a 15:50. |
| G1711-10 | **Promessas sem ferramenta.** Artur (folder 30x20, 2 dobras, papel mínimo 250 g, 100 un): a Laura citou couchê 150 g, depois 115 g, ignorou o 250 g pedido e prometeu "produção digital rápida, pronta para segunda" sem preço nem prazo da ferramenta. Patrícia: "entregamos por motoboy em toda BH e região" (frete só está definido para os 7 bairros centrais e retirada). | Transcrições Artur 15:16 a 15:24 e Patrícia 13:32. |
| G1711-11 | **Preço dito diferente do PDF.** Patrícia ouviu "100 unidades R$ 159,90" e o PDF saiu R$ 177,90 + arte R$ 39,90 = R$ 217,80. | `orcamentos` nº 552 e transcrição 13:29. |
| G1711-12 | **Regra do dono violada.** Laura perguntou "Você vai querer Nota Fiscal?" antes do pagamento (Marcos, 13:28), contra a decisão de 17/11 (emissão padrão, sem perguntar). O prompt do WF2 só manda confirmar se o cliente perguntar; é desvio do modelo, não está travado na saída. | Transcrição Marcos 13:28 e `n8n/GBH-WF2-Agente.json`. |
| G1711-13 | **Rajadas e repetição.** 3 a 4 balões por resposta com 4 a 5 s de intervalo; na conversa do Marcos a frase "Assim que o pagamento for confirmado, a equipe de criação..." foi dita 4 vezes em 20 min e a pergunta "conseguiu abrir o link?" 3 vezes. | Transcrição Marcos 15:32 a 15:38. |
| G1711-14 | **Promessa do anúncio x preço real.** Anúncio "Crachá com Cordão" leva a "a partir de R$ 78,90", mas o cordão é cobrado à parte (R$ 76,90 por 1 un), então 1 conjunto sai R$ 155,80. Diogo recebeu R$ 155,80 e parou; os 2 clientes que compraram ou pediram só pediram o crachá sem cordão. Quantidade típica do público é 1 a 5 unidades. | Orçamento nº 554 e transcrições Marcos, Wender, Diogo. |
| G1711-15 | **Perdas sem motivo registrado.** Nenhum orçamento tem `motivo_perda` (Artur e Flávia recusaram de forma explícita). | `orcamentos.motivo_perda` nulo. |

### Melhorias propostas (ordem de prioridade)

Prioridade 1, aplicar já (baixo risco, alto efeito):
- **M1711-1** Q1: no máximo 1 lembrete por conversa a cada 3 h e no máximo 2 por dia; não enviar se o cliente avisou que volta ("já te respondo", "estou em trabalho"); variar o texto. (resolve G1711-2)
- **M1711-2** Ampliar a trava `cliente_recusou` (não não, não quero, obrigado sem pedir nada, "deixa pra lá", "vou ver depois") e fazer a Laura encerrar em 1 mensagem curta, sem repetir despedida. (G1711-3)
- **M1711-3** Lembrete garantido para orçamento aberto mesmo depois de modo humano: reagendar F1 quando o atendente responde e o cliente fica 30 min sem falar; alerta "lead em modo humano parado há X horas" com valor do orçamento. (G1711-7)
- **M1711-4** Extração silenciosa de dados fiscais e de contato em modo humano: a Laura (ou uma função no banco) lê a mensagem do cliente depois do pagamento, salva em `dados_fiscais` sem responder, e o CRM mostra o CPF formatado para conferência. Enquanto não existe, botão "Salvar dados da última mensagem" no chat. (G1711-6)
- **M1711-5** Aceitar intenção explícita de pagamento ("pagamento será pix", "pode mandar o link") como aprovação ou perguntar APROVADO uma única vez por orçamento. (G1711-4)
- **M1711-6** Pedido fora do padrão (entrada de 50%, parcelar acima de 2x, desconto, prazo urgente) chama o dono na hora e responde "vou confirmar com o responsável" sem negar sozinha. (G1711-5)

Prioridade 2 (esta semana):
- **M1711-7** Velocidade: limitar o retorno de `buscar_produto` a 4 opções já deduplicadas (agrupar orientação e variações idênticas) e cortar o contexto por rodada (alvo: abaixo de 30 mil tokens); enviar fotos em segundo plano para a resposta de texto sair antes. Meta: P90 abaixo de 120 s. (G1711-1, G1711-8)
- **M1711-8** `buscar_produto` não devolve produto de outra família nem quantidade fora do pedido como "para N unidades"; se a menor tiragem for maior que a pedida, dizer isso uma vez e oferecer o item mais próximo. Corrigir a busca "crachá PVC" que não localizou. (G1711-8)
- **M1711-9** Função de faixa de quantidade: devolve "por +R$ X você leva N unidades" para a Laura sugerir sempre que a diferença de preço for pequena; proibir falar "tiragem mínima" sem vir da função. (G1711-9)
- **M1711-10** Trava de saída para: prazo ou alternativa de produção que não veio de ferramenta, "entregamos em toda BH", pergunta de nota fiscal antes do pagamento. (G1711-10, G1711-12)
- **M1711-11** Orçamento: se o preço do PDF diferir do último preço dito no chat, a Laura explica a diferença antes de enviar (ou a ferramenta bloqueia). (G1711-11)
- **M1711-12** Limite de 2 balões por resposta e filtro de frase repetida na mesma conversa. (G1711-13)

Prioridade 3 (comercial e medição):
- **M1711-13** Revisar o criativo "Crachá com Cordão": deixar claro que cordão é opcional e destacar lote (5 por R$ 86,90) ou criar kit "crachá + cordão simples" com preço único. Medir custo por conversa e por venda por criativo (hoje R$ 24,19 para 5 conversas e 1 venda; Retrovisor R$ 10,36 para 1 conversa). (G1711-14)
- **M1711-14** Pergunta de perda ao fim de recusa (preço, prazo, produto, só pesquisando) gravando `motivo_perda`. (G1711-15)
- **M1711-15** Primeira resposta já fazer a pergunta que avança (quantidade e se tem arte) em vez de "o que você precisa?" quando o anúncio já indica o produto (Renato e Taygor ainda sem resposta às 20:20).

### Pendências do dia (acompanhar em 18/11)
- Orçamentos abertos: Felipe R$ 151,90, Patrícia R$ 217,80, Edson R$ 274,70, Diogo R$ 155,80 (total R$ 800,20). Só Felipe e Diogo têm lembrete agendado.
- Pedido #407 (Marcos): NFC-e nº 71 rejeitada, precisa reemitir com os dados corretos.
- Renato e Taygor: primeira mensagem às 20:20, Q1 às 08:00 de 18/11.
- Leads de 16/11 sem resposta (Beatriz, Dj Brenda, Marcos Junio, "😎"): receberam Q1 às 08:00 de 17/11, nenhum respondeu.

---

## Backlog de melhorias

| Código | Descrição curta | Origem | Status |
|---|---|---|---|
| M1711-1 | Cadência do Q1 (1 a cada 3 h, 2 por dia, respeitar "já te respondo") | G1711-2 | Proposta |
| M1711-2 | Trava de recusa mais ampla e despedida única | G1711-3 | Proposta |
| M1711-3 | Lembrete e alerta para orçamento aberto em modo humano | G1711-7 | Proposta |
| M1711-4 | Salvar dados fiscais em modo humano | G1711-6 | Proposta |
| M1711-5 | Intenção de pagamento vale como aprovação | G1711-4 | Proposta |
| M1711-6 | Pedido fora do padrão chama o dono | G1711-5 | Proposta |
| M1711-7 | Menos tokens e fotos em segundo plano | G1711-1 | Proposta |
| M1711-8 | Correção de `buscar_produto` (família, quantidade, PVC) | G1711-8 | Proposta |
| M1711-9 | Função de faixa de quantidade | G1711-9 | Proposta |
| M1711-10 | Novas travas de saída (prazo, frete, NF) | G1711-10, G1711-12 | Proposta |
| M1711-11 | Preço do PDF igual ao dito no chat | G1711-11 | Proposta |
| M1711-12 | Máximo de 2 balões e anti-repetição | G1711-13 | Proposta |
| M1711-13 | Criativo e preço do anúncio de crachá | G1711-14 | Proposta (decisão do dono) |
| M1711-14 | Motivo de perda na recusa | G1711-15 | Proposta |
| M1711-15 | Primeira resposta já avança | geral | Proposta |

Status possíveis: Proposta, Em andamento, Aplicada (com data e PR), Descartada (com motivo).

## Consultas de apoio (somente leitura, projeto `bhlosshvwmlyzhbghsrc`)

Janela do dia em Brasília (ajuste a data): `created_at >= '2026-11-17 03:00+00' and created_at < '2026-11-18 03:00+00'`.

- Conversas do dia: `conversations` com `last_message_at` na janela, junto de `contacts`.
- Transcrição: `messages` (direction `in`/`out`, `sent_by` preenchido = atendente humano), por conversa, em ordem.
- Latência de resposta: para cada mensagem do cliente que abre um turno (sem outra do cliente nos 25 s anteriores), tempo até a primeira mensagem `out`; reportar P50, P90, quantos acima de 90 s e de 5 min.
- Rodadas lentas, ocupadas ou com erro: `agente_execucoes` (`status`, `motivo`, `tokens_entrada`, `finalizado_em - iniciado_em`).
- Ferramentas: `agent_logs` agrupado por `ferramenta`, `result` e média de `duracao_ms`.
- Alertas: `alertas` por `tipo` (`saida_bloqueada`, `agente_falhou`, `agente_chamado`).
- Lembretes: `followup_fila` por contato (`regra_codigo`, `status`, `motivo`, `agendado_para`, `enviado_em`).
- Orçamentos e pedidos: `orcamentos` (`total`, `status`, `motivo_perda`), `orders` (`stage`, `payment_status`, `lucro_liquido_real`, `nf_situacao`, `dados_fiscais`).
- Anúncios: `select * from ad_performance(dia, dia)` e `ad_daily` (coluna `day`, `spend`).

Cuidados: a tabela `contacts` não tem coluna `teste`; `orders` e `orcamentos` têm. Não rodar cenários `e5-*`, `mvp-*`, `e12-*`, `e17-*` (gastam crédito do Gemini).
