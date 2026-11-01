# CRM como app no iPhone, notificações e alertas ao dono (Etapa 6)

## Como o aviso chega
Cada alerta é gravado em `alertas` (uma só porta: `alerta_criar`) e entregue pela Edge Function `alertas-enviar` por **dois canais**:
1. **Popup no celular** (Web Push com chaves VAPID). O toque abre direto o pedido (`/kanban?pedido=...`) ou a conversa (`/inbox/...`).
2. **WhatsApp do dono** (`agente_config.whatsapp_dono`): texto livre se a janela de 24 h do dono estiver aberta, senão o template `pedido_pago_dono` (pedido pago) ou `alerta_atencao_dono` (demais). Os dois templates estão aprovados.

Regras: gravidade **alta** sai na hora; **baixa** é agrupada num resumo a cada 2 horas; o mesmo alerta da mesma conversa só uma vez a cada 30 minutos; horário de silêncio (padrão 22h às 7h) segura os popups não urgentes (pedido pago, atenção do agente e problema de pagamento furam o silêncio). Se um canal falha 3 vezes, o outro avisa que o primeiro não chegou. Cada canal tem seu status em `alertas` e na tela Configurações > Notificações.

Tipos: pedido pago, atenção do agente (`chamar_dono`), problema de pagamento (estorno, contestação), nova mensagem em atendimento humano (só popup por padrão), pagamento pendente há mais de 6 h, pedido pago sem arte há mais de 12 h, desconto fora do padrão e o resumo.

## Instalar no iPhone (iOS 16.4 ou superior)
1. Abra **crm.suagraficabh.com.br no Safari**.
2. Toque em **Compartilhar** e depois em **Adicionar à Tela de Início** > **Adicionar**.
3. Feche o Safari e abra o CRM **pelo ícone novo**. Entre com "Continuar conectado" marcado (a sessão fica guardada no app instalado; o app instalado não divide login com o Safari).
4. Vá em **Configurações > Notificações** e toque em **Ativar notificações** (o iPhone só pergunta a partir de um toque). Permita.
5. Toque em **Enviar notificação de teste**: deve chegar um popup e uma mensagem no WhatsApp do dono.

O selo vermelho no ícone mostra os avisos de gravidade alta ainda não lidos (some ao abrir o pedido ou a conversa ou em "Marcar tudo como lido").

## Se a notificação não chegar
- **Botão "Ativar" cinza e aviso amarelo:** você está no Safari, não no ícone da Tela de Início. Abra pelo ícone.
- **"Bloqueadas no aparelho":** iPhone > Ajustes > Notificações > Sua Gráfica > Permitir. Volte à tela e ative de novo.
- **Modo Foco ou Não perturbe:** o iPhone segura o popup. Adicione o app Sua Gráfica às exceções.
- **Teste diz "nenhum aparelho ativo":** toque em Ativar neste aparelho (a assinatura vence se o app for removido; basta ativar de novo).
- **Popup ok e WhatsApp "aguardando template":** o template ainda não está aprovado na Meta; a lista em Configurações > WhatsApp e templates mostra o status.
- **WhatsApp não chega mas o status diz enviado:** a Meta só entrega template ao número do dono se ele estiver ativo no WhatsApp; responda qualquer mensagem do número comercial para abrir a janela de 24 h (aí sai texto livre).
- **Nada chega e a lista "Últimos avisos" está vazia:** o workflow `GBH | WF5 | Pagamento e alertas` está desativado (ativação na Etapa 8). Até lá os alertas ficam gravados, mas só saem pelo botão de teste ou quando o disparador for chamado.
- Aparelho que não responde (404/410) é desativado automaticamente; falhas repetidas (5) também. Assinaturas inativas há mais de 30 dias são apagadas.

## Chaves e segredos
- As chaves **VAPID** vêm dos segredos `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` e `VAPID_SUBJECT` (opcional) das Edge Functions. Sem eles, a função gera um par na primeira chamada e o guarda em `app_segredos` (tabela fechada, só a service role lê). Nada disso fica no repositório nem no front: o CRM pede a chave **pública** à função. Trocar as chaves invalida os aparelhos (ativar de novo).
- O token do WhatsApp continua só nas Edge Functions.

## Pagamento confirmado (WF5)
O Mercado Pago, a conferência de 10 minutos e o botão "Conferir agora" continuam como estavam e gravam o evento `pagamento_confirmado`. "Marcar como pago" usa o mesmo caminho (`private.confirmar_pagamento`). O WF5 lê os eventos sem `processado_em` a cada minuto (ou na hora, se o Database Webhook opcional estiver ligado) e, para cada um, **uma única vez**:
1. `pagamento_pos_processar` (banco): confere SKUs e `validar_margem` (se algo estiver fora das regras, alerta alto e o pagamento é mantido), garante o lucro líquido real com a taxa do método pago, coloca a conversa em modo humano (o agente para), cancela follow-ups pendentes e condições especiais abertas do pedido e cria o alerta do pedido pago (cliente, itens com SKUs, valor, método, lucro líquido, previsão, link).
2. `cliente-pago-avisar`: UMA mensagem ao cliente com os próximos passos (arte e retirada ou entrega): texto livre na janela de 24 h, senão `pedido_pago_confirmacao`. Reserva atômica, até 3 tentativas, depois alerta o dono. Pedido de teste (`orders.teste`) não escreve ao cliente. Não vai SKU, custo, margem nem lucro ao cliente.
3. `alertas-enviar`: popup e WhatsApp ao dono.

Estorno ou contestação (`pagamentos_alertas`) viram alerta alto (`pagamento_problema`) por gatilho, sem mexer no pedido. O agente também nunca responde o número do dono (`agente_bloqueio` devolve `numero_do_dono`).

**Database Webhook opcional (aviso imediato):** Supabase > Database > Webhooks > INSERT em `eventos_pagamento` > HTTP POST para `https://n8n.bauerlab.com.br/webhook/gbh-wf5-pagamento`. Sem ele, o intervalo é de até 1 minuto.

## Testes
`npm run test:alertas` (montagem dos avisos, PWA, segredos) e `supabase/tests/rodar-local.sh supabase/tests/alertas_etapa6.sql` (48 casos: alerta, 30 minutos, resumo, silêncio, canais, WF5, mensagem ao cliente, estorno, permissões).
