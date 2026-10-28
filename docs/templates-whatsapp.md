# Templates do WhatsApp do agente

Conta de mensagens "Sua Gráfica BH" (negócio 28975133282116738), idioma `pt_BR`. Enviados para aprovação em 28/10/2026. O status em tempo real aparece em **Configurações > WhatsApp e templates** (botão Sincronizar). Regras da Meta aplicadas: corpo não começa nem termina com variável, variáveis sem quebra de linha, utilidade sem conteúdo promocional.

Os quatro templates de marketing levam o botão de resposta rápida **Parar promoções** (mesmo padrão de `novidade_promocao`): quando o cliente toca, o webhook marca `opted_out` e confirma. O CRM só envia marketing para quem está `opted_in`.

| # | Nome | Categoria pedida | Status na Meta | ID | Onde é usado |
|---|---|---|---|---|---|
| 1 | `pedido_pago_dono` | Utilidade | Em análise | 29518626637723162 | Alerta ao dono: pedido pago |
| 2 | `alerta_atencao_dono` | Utilidade | Em análise | 2503907503451229 | Alerta ao dono: `chamar_dono` |
| 3 | `pedido_pago_confirmacao` | Utilidade | Em análise | 1659659038932560 | Confirmação ao cliente |
| 4 | `pedido_pronto_retirada` | Utilidade | Em análise | 1416712628190719 | Aviso de pronto (com endereço) |
| 5 | `pedido_saiu_entrega` | Utilidade | Em análise | 1323778349816810 | Aviso de saída para entrega |
| 6 | `pagamento_pendente` | Utilidade | Em análise | 1113781801411116 | Lembretes de pagamento (1 h, 6 h, 24 h) |
| 7 | `pos_venda_satisfacao` | Utilidade | Em análise | 1131419262562437 | Satisfação depois da entrega |
| 8 | `orcamento_vence_hoje` | Marketing | Em análise | 2233114997556920 | Follow-ups F2/F3 com janela fechada |
| 9 | `ultima_chance_orcamento` | Marketing | Em análise | 1302748728707925 | Follow-up F4 sem benefício |
| 10 | `recompra_lembrete` | Marketing | Em análise | 1509477404562839 | Recompra |
| 11 | `condicao_especial_orcamento` | Marketing | Em análise | 3726353930835635 | Follow-ups F3/F4 com janela fechada |

## Textos e variáveis

1. `pedido_pago_dono`: "Pedido pago por {{1}}. Itens: {{2}}. Valor: {{3}}. Lucro líquido: {{4}}. Previsão: {{5}}. Abra o pedido no CRM: {{6}} para dar atenção agora." Variáveis: cliente, itens, valor, lucro líquido, previsão, link do pedido.
2. `alerta_atencao_dono`: "Atenção no atendimento. Cliente: {{1}}. Motivo: {{2}}. Abra a conversa no CRM: {{3}} para ver os detalhes." Variáveis: cliente, motivo, link da conversa.
3. `pedido_pago_confirmacao`: "Pagamento confirmado, {{1}}! Seu pedido {{2}} já entrou na fila. Previsão de ficar pronto: {{3}}. Se ainda não enviou a arte, pode mandar por aqui mesmo." Variáveis: nome, número do pedido, previsão.
4. `pedido_pronto_retirada`: "Oi, {{1}}! Seu pedido {{2}} está pronto para retirada. Endereço: R. Rio de Janeiro, 462, 22º andar, Sala 2217, Centro, Belo Horizonte. Atendimento: segunda a quinta das 9h às 17h e sexta das 9h às 18h30. Quando chegar, é só avisar por aqui." Variáveis: nome, número do pedido.
5. `pedido_saiu_entrega`: "Oi, {{1}}! Seu pedido {{2}} saiu para entrega. Acompanhe por aqui: {{3}}. Qualquer dúvida, é só responder esta mensagem." Variáveis: nome, número do pedido, link de acompanhamento.
6. `pagamento_pendente`: "Oi, {{1}}! Seu orçamento {{2}} está aguardando o pagamento. O link é {{3}}. Se precisar de ajuda para pagar, é só responder por aqui." Variáveis: nome, número do orçamento, link de pagamento.
7. `pos_venda_satisfacao`: "Oi, {{1}}! Seu pedido {{2}} foi entregue. Deu tudo certo? Se precisar de mais alguma coisa, é só chamar por aqui." Variáveis: nome, número do pedido.
8. `orcamento_vence_hoje`: "Oi, {{1}}! Seu orçamento {{2}} vale até {{3}}. Dá para fechar hoje e garantir a entrega no prazo. Quer que eu reenvie o link de pagamento?" Variáveis: nome, número do orçamento, validade.
9. `ultima_chance_orcamento`: "Oi, {{1}}, passando para saber se ainda faz sentido seguir com o seu pedido de {{2}}. Se quiser ajustar quantidade ou acabamento, me chama por aqui que a gente resolve rápido." Variáveis: nome, produto.
10. `recompra_lembrete`: "Oi, {{1}}! Já faz um tempinho desde o seu pedido de {{2}}. Quer repor ou aproveitar para incluir algo novo? Me responde por aqui que eu monto o orçamento rapidinho." Variáveis: nome, produto.
11. `condicao_especial_orcamento`: "Oi, {{1}}! Consegui uma condição especial no seu orçamento {{2}}: {{3}}. Vale até {{4}}. Quer que eu envie o link de pagamento atualizado?" Variáveis: nome, número do orçamento, condição (`texto_curto` de `calcular_condicao_especial`), validade.

O texto de cada template também está em `src/lib/agent-templates.ts` (usado pela tela e por `npm test`).

## Templates que já existiam na conta (não duplicados)

`atualizacao_pedido`, `novidade_promocao`, `retomar_orcamento`, `pedido_pronto`, `orcamento_pronto` (todos em análise) e `hello_world` (aprovado, en_US). `retomar_orcamento` e `pedido_pronto` têm função parecida com `ultima_chance_orcamento` e `pedido_pronto_retirada`; os nomes são diferentes, então nada foi sobrescrito. Se quiser enxugar, a Meta permite apagar os antigos depois que os novos forem aprovados.

## Pendente

- Acompanhar a aprovação. Se algum de utilidade for reclassificado como marketing, a tela mostra "Reclassificado pela Meta" e a Etapa 6/7 passa a tratá-lo como marketing (só para quem está `opted_in`).
- Os templates 1 e 2 vão para o número do dono; a janela de 24 h do dono não conta (é número comercial recebendo template).
- Dentro de 72 h do clique no anúncio, confirmar na documentação atual da Meta como fica a cobrança dos templates (Etapa 7).
