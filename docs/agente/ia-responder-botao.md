# Botão "Responder com IA" (18/11/2026)

Pedido do dono: em conversa assumida pelo humano (modo humano), o cliente faz uma pergunta e o atendente quer que a IA analise e escreva a resposta para seguir a venda.

## Como funciona
1. No chat, o botão com o ícone de faíscas (ao lado de NF e Arte) chama a Edge Function `ia-rascunho` (só atendente logado).
2. O banco prepara o pedido (`ia_rascunho_preparar`): pega as mensagens do cliente desde a última resposta, o contexto da conversa e abre uma execução em modo rascunho.
3. O n8n (WF1, gatilho "Rascunho: receber pedido") chama o mesmo cérebro da Laura (WF2) e grava o texto em `ia_rascunhos` (`ia_rascunho_salvar`).
4. A tela espera o texto (cerca de 45 s) e coloca no campo de mensagem. O atendente **revisa e envia**. A IA nunca envia nada ao cliente.

## Regras
- **A voz é sempre a da Laura.** Nunca assina nem se apresenta como João Victor: no WhatsApp quem responde é só a Laura, e o João Victor (com C) só atende depois do pagamento. A regra está no prompt do modo rascunho (WF2) e vale para qualquer rascunho.
- Preço, prazo, frete e desconto só vêm das ferramentas; passa pela mesma trava de saída da Laura.
- No modo rascunho a IA só usa `buscar_produto`, `buscar_conhecimento`, `montar_orcamento`, `verificar_frete` e `salvar_contato`. PDF, link de pagamento, foto, condição especial, lembrete, arte e chamar o dono ficam bloqueados (`agente_tool_inicio`); se o próximo passo for um deles, o texto avisa que o atendente manda na sequência.
- Um segundo clique em menos de 4 minutos reaproveita o rascunho em andamento (não gasta duas vezes).
- Cada clique usa o Gemini uma vez. O custo aparece em `agente_execucoes` (`rascunho = true`).
- O botão fica desativado fora da janela de 24 h (como NF e Arte).

## Onde está
Banco: `ia_rascunhos`, `agente_execucoes.rascunho`, funções `ia_rascunho_preparar` e `ia_rascunho_salvar` (migration `20261218000006`). Servidor: `supabase/functions/ia-rascunho`. n8n: WF1 (4 nós "Rascunho: ...") e regra do modo rascunho no nó "Regras adicionais (rodada 18/11)" do WF2. Tela: `src/features/inbox/ChatPanel.tsx`. A URL do gatilho fica em `app_settings.ia_rascunho.url`.

## Verificação feita
Uma execução real na conversa do Thiago (única, para provar o caminho): rascunho pronto em 46 s, na voz da Laura, com a garantia de reembolso correta e sem assinar como João Victor. Nenhum cenário `e5-*`, `mvp-*`, `e12-*` ou `e17-*` foi rodado.

## Ideias para depois
- Modo "enviar direto" opcional para o caso de a conversa estar parada há muito tempo.
- Aviso na tela quando a última mensagem da conversa já foi respondida (o rascunho seria um complemento).
