# Pagamento com Mercado Pago (Checkout Pro)

O CRM gera o link de pagamento a partir do orçamento já calculado, recebe o aviso do Mercado Pago, confere tudo na API do Mercado Pago e move o card para **Pago**. O agente de IA (etapas seguintes) só lê os eventos descritos no fim deste documento.

## Arquitetura

```
CRM (aba Pagamento do pedido)  ──►  mp-criar-link  ──►  Mercado Pago (cria a preferência)
                                        │ grava em pagamentos (link, valor, validade, modo)
cliente paga no link  ──►  Mercado Pago  ──►  mp-webhook (valida x-signature)
                                                  │ consulta GET /v1/payments/{id}
                                                  ▼
                                   mp_registrar_pagamento (banco, atômico e idempotente)
                                      ├─ confere referência, valor e moeda do pedido
                                      ├─ aprovado e conferido: private.confirmar_pagamento
                                      │     (pedido vira Pago, grava eventos_pagamento)
                                      └─ qualquer divergência: pagamentos_alertas (pedido NÃO muda)
botão "Marcar como pago" ──► confirmar_pagamento_manual ──► private.confirmar_pagamento  (mesmo caminho)
```

- **Preço**: vem sempre de `order_financials.total` (calculado no banco). O front e o cliente nunca informam valor. Antes de criar o link roda `public.validar_antes_de_cobrar(pedido)`, ponto de extensão para regras de piso e margem (hoje confere pedido existente, valor maior que zero e pedido ainda não pago).
- **Referência**: `external_reference` = `SG-` + número do pedido com 4 dígitos (`SG-0001`). No CRM o orçamento é o próprio pedido (aceita `pedido_id` ou `orcamento_id`).
- **Itens enviados**: uma linha por item com a descrição comercial (`3x Cartão de visita 500 un`), já com o desconto, fechando o total em centavos. Nunca vão código do fornecedor nem custo.
- **Pix e cartão** habilitados. Boleto e lotérica ficam desligados.
- **Idempotência do link**: o mesmo pedido, com o mesmo valor e link ainda válido, devolve o mesmo link. Valor mudou, link expirou ou "Gerar novo link": o anterior é invalidado (e expirado no Mercado Pago) e um novo é criado. Só existe um link ativo por pedido e modo.
- **Idempotência do aviso**: tudo é atômico no banco. O mesmo aviso repetido não duplica pagamento, evento nem alerta. Aviso antigo que chega depois (ex.: "pendente" depois de "aprovado") é ignorado.
- **Resposta do webhook**: o processamento é uma consulta e uma gravação (milissegundos), então a função responde 200 depois de gravar. Se algo falhar ela devolve 5xx para o Mercado Pago tentar de novo; avisos ignoráveis (tipo desconhecido, simulação do painel) respondem 200.
- **Divergências** (não alteram o pedido, vão para Pagamentos > Alertas): valor diferente, moeda diferente, referência desconhecida, pagamento recusado, estorno, contestação, reclamação, segundo pagamento aprovado no mesmo pedido, pagamento de teste em pedido real, aviso de modo diferente do configurado.

### Modo teste e produção
`MP_MODO=teste` ou `producao` escolhe qual par de segredos a função usa. Em **teste** tudo é gravado como teste e **só pedidos marcados como "Pedido de teste"** (interruptor na aba Pagamento) mudam de etapa; pagamento de teste em pedido real vira alerta. Em **produção** a função recusa criar link para pedido de teste. Um selo amarelo "MODO TESTE" aparece no topo de Pagamentos enquanto estiver em teste.

## URLs
| Função | URL | JWT |
|---|---|---|
| Webhook | `https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/mp-webhook` | não (valida `x-signature`) |
| Criar link | `https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/mp-criar-link` | dono logado ou service role (servidor) |

`mp-criar-link` recebe `{ "pedido_id": "uuid", "expira_horas": 48, "forcar_novo": false }` e devolve `{ link, pagamento_id, valor, expira_em, modo, referencia, reutilizado }`. `expira_horas` vai de 0,1 a 168 (padrão 48). `{ "acao": "status" }` devolve o modo e os NOMES dos segredos que faltam (nunca valores).

## Segredos (Supabase > Edge Functions > Secrets)
| Nome | O que é |
|---|---|
| `MP_MODO` | `teste` ou `producao` |
| `MP_ACCESS_TOKEN_TESTE` | Access Token das credenciais de **teste** |
| `MP_WEBHOOK_SECRET_TESTE` | Assinatura secreta do webhook em **Modo de teste** |
| `MP_ACCESS_TOKEN_PRODUCAO` | Access Token das credenciais de **produção** |
| `MP_WEBHOOK_SECRET_PRODUCAO` | Assinatura secreta do webhook em **Modo de produção** |
| `CRM_BASE_URL` (opcional) | Padrão `https://crm.suagraficabh.com.br`; usado nas páginas de retorno |

Nada disso fica no repositório, no front ou em logs. Os logs só registram o motivo da rejeição (ex.: assinatura inválida) e códigos de erro.

## Configuração no painel do Mercado Pago
1. Mercado Pago Developers > Suas integrações > aplicação "Sua Gráfica BH" > **Webhooks**.
2. **Modo de teste**: URL `https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/mp-webhook`. Eventos: **Pagamentos**, **Reclamações** e **Contestações**. Salve e copie a **assinatura secreta** (Revelar) para `MP_WEBHOOK_SECRET_TESTE`.
3. **Modo de produção**: mesma URL e mesmos eventos. Copie a assinatura secreta para `MP_WEBHOOK_SECRET_PRODUCAO`.
4. Credenciais: em "Credenciais de teste" copie o Access Token para `MP_ACCESS_TOKEN_TESTE`; em "Credenciais de produção", para `MP_ACCESS_TOKEN_PRODUCAO`.
5. O botão "Simular notificação" do painel usa um ID falso: a função responde 200 "ignorado" (o pagamento não existe). Isso confirma que a assinatura e a URL estão certas.

A assinatura vale 10 minutos a partir do carimbo (`ts`) enviado pelo Mercado Pago; fora disso o aviso é rejeitado (proteção contra replay).

## Como testar
1. Crie um pedido com itens, abra a aba **Pagamento** e ligue **Pedido de teste**.
2. **Gerar link de pagamento**. Abra o link com o usuário comprador de teste do Mercado Pago.
3. Cartão de teste aprovado: nome do titular `APRO`. Recusado: nome `OTHE`. Número de teste do Mercado Pago (Mastercard 5031 4332 1540 6351, código 123, validade 11/30) e CPF de teste conforme a documentação atual do Mercado Pago.
4. Confira: o pedido vai para **Pago**, aparece em Pagamentos > Cobranças como TESTE, e existe um evento `pagamento_confirmado` em `eventos_pagamento`.
5. Casos para repetir: recusado (alerta, pedido fica), alterar um item e gerar de novo (o link antigo é invalidado), link vencido (use `expira_horas` baixo), reenviar o mesmo aviso (nada duplica).

Testes automáticos: `npm run test:mp` (assinatura válida, inválida, ausente, malformada e antiga; itens da preferência; status; busca de segredos no repositório).

## Virar para produção
1. Cole `MP_ACCESS_TOKEN_PRODUCAO` e `MP_WEBHOOK_SECRET_PRODUCAO`.
2. Troque `MP_MODO` para `producao`.
3. Apague ou ignore os pedidos de teste (eles aparecem com o selo "teste").
4. Faça um pagamento real de valor baixo em um pedido real e estorne depois pelo painel do Mercado Pago (vira alerta "Estorno"; o pedido não muda sozinho).

## Contrato dos eventos para o agente (tabela `eventos_pagamento`)
Só leitura para o app (a escrita é do banco). O agente, com a service role, lê os eventos com `processado_em is null`, ou assina o Realtime da tabela, trata cada um e grava `processado_em = now()`. Cada evento existe uma única vez (`chave` única), então tratar na ordem e marcar como processado basta.

| `tipo` | Quando | Ação sugerida ao agente (etapas seguintes) |
|---|---|---|
| `link_criado` | link gerado | enviar o link ao cliente |
| `pagamento_pendente` | Pix gerado ou aguardando | aguardar |
| `pagamento_em_analise` | cartão em análise | aguardar |
| `pagamento_confirmado` | pagamento aprovado e conferido, pedido já está em Pago | avisar o cliente, seguir para arte |
| `pagamento_recusado` | cartão recusado | oferecer tentar de novo no mesmo link |
| `pagamento_cancelado` / `pagamento_expirado` | cancelado ou vencido | oferecer novo link |
| `pagamento_estornado` / `pagamento_contestado` | estorno ou chargeback | só sinalizar ao dono; nada automático |

Campos: `id`, `tipo`, `order_id`, `pagamento_id`, `criado_em`, `processado_em` e `payload` (JSON):
```json
{ "pedido_id": "uuid", "pedido_numero": 1, "referencia": "SG-0001", "valor": 120.00,
  "metodo": "pix|cartao|manual", "mp_payment_id": "123", "modo": "teste|producao",
  "origem": "mercadopago|manual", "teste": false }
```
`pagamento_confirmado` também vem do botão manual (`origem: "manual"`, sem `mp_payment_id`). Eventos de pedidos com `teste: true` nunca devem disparar mensagem a cliente real.

Para saber a data de entrega depois da confirmação, leia `orders.due_date` (ver `docs/agente-ia.md`).

Esta etapa **não envia mensagem ao cliente nem alerta ao dono**: deixa o evento pronto.
