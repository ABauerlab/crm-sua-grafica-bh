# Roteiro de 8 testes manuais para o dono (WhatsApp real)

O simulador prova a lógica e a conversa, mas não prova o que só o mundo real mostra: aprovação de templates na Meta, entrega real das mensagens, aparência no celular, push no iPhone e cobrança de verdade. São 8 testes curtos (uns 5 minutos cada), pelo seu próprio WhatsApp, com o número que está no piloto (`agente_config.piloto_wa_ids`). Faça nesta ordem e marque o resultado.

Antes de começar: `piloto_ativo = true`, `piloto_percentual = 0`, seu número em `piloto_wa_ids`, IA ligada. Nenhum cliente de verdade é atendido nesse estado.

| # | Teste | O que fazer | O que deve acontecer | Por que o simulador não prova |
|---|---|---|---|---|
| 1 | Primeira conversa pelo anúncio | Clique em um anúncio de cartão (ou mande "Oi, vi o anúncio do cartão") do seu celular | A Laura se apresenta, usa o contexto do anúncio, faz uma pergunta por vez, mensagens curtas, sem travessão, sem lista | Entrega real, atraso de digitação e aparência no celular |
| 2 | Orçamento em PDF e fotos | Peça 500 cartões com arte e entrega no Centro; depois peça "uma foto do cartão" | PDF abre bem no celular (resumo, "APROVADO", sem custo, SKU nem endereço), foto leve chega, no máximo 3 por pedido, ordem das mensagens correta | PDF e foto são simulados no modo de teste |
| 3 | Link de pagamento e Pix real | Peça para fechar; abra o link; pague R$ 1 de Pix se o dono quiser testar de verdade, ou use o ambiente de teste do Mercado Pago | Link abre no celular, Pix aparece primeiro, 2x sem juros disponível, o valor é igual ao do PDF; depois do pagamento chega UMA mensagem do João Victor e o alerta ao dono | Cobrança real e webhook do Mercado Pago |
| 4 | Troca de persona e endereço | Depois de pagar, pergunte "onde retiro?" | Responde como João Victor, agora com o endereço; antes de pagar (teste com outro pedido) NÃO informa endereço | Pagamento real muda a fase |
| 5 | Templates aprovados na Meta | Deixe a janela de 24 h fechar (ou espere um dia) e provoque um aviso: marque um pedido de teste como "Pronto" no CRM | Chega o template de utilidade (pedido pronto) no seu WhatsApp, com texto certo e variáveis preenchidas | Aprovação e categoria de template só existem na Meta |
| 6 | Alerta ao dono no iPhone | Com o CRM instalado como PWA, mande no teste "quero falar com uma pessoa" | Popup no iPhone e mensagem no seu WhatsApp, uma só vez (regra de 30 min), com resumo da conversa | Push depende do aparelho |
| 7 | Botão Pausar IA | No meio de uma conversa, aperte "Pausar IA" no topo do CRM e mande uma mensagem; depois religue | Enquanto pausado a IA não responde nada; ao religar, volta a responder sem repetir mensagens antigas | O botão é do front |
| 8 | Descadastro | Responda "PARAR" a uma mensagem; depois mande "oi, quero cartão" | Chega a confirmação de descadastro, nenhuma promoção depois; ao voltar por conta própria, o atendimento funciona normal; follow-ups não chegam | Fluxo real de opt-out e templates de marketing |

Se qualquer item falhar, anote o print e o horário e pause a IA (`ia_ligada = false`). Em seguida peça o ajuste e rode `npm run e2e -- --critico` antes de religar.

Bônus rápido (se der tempo): mande um áudio de 20 segundos pedindo panfletos (transcrição real) e uma imagem de arte pequena (aviso de baixa qualidade).
