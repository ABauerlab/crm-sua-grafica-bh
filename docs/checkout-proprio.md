# Checkout próprio (suagraficabh.com.br/pagar/<token>)

18/11/2026. O cliente paga Pix ou cartão (até 2x sem juros) dentro do nosso site, com a identidade da Sua Gráfica BH, sem abrir o app nem pedir login do Mercado Pago. Motivo: o Checkout Pro mandava o celular para o app do Mercado Pago (caso do Paulo Moreira) e travava a conversão.

## Fluxo
```
Laura / CRM / loja  ->  mp-criar-link  ->  pagamentos (link = https://suagraficabh.com.br/pagar/<checkout_token>)
cliente abre /pagar/<token> (Next.js, pasta ecommerce/)
   ├─ checkout-dados      carregar, status, salvar dados, escolher arte, adicionar/remover sugestão
   └─ checkout-mp-processar  Pix ou cartão -> POST /v1/payments (valor e referência SG-xxxx vêm do banco)
                               └─ registrarObjeto -> mp_registrar_pagamento (mesmo caminho do mp-webhook)
                                    └─ private.confirmar_pagamento -> eventos_pagamento -> WF5 -> mensagem no WhatsApp
mp-webhook e mp-conferir continuam valendo (aviso duplicado é ignorado).
```
- **Token**: `orders.checkout_token` (32 hex, único, fixo por pedido). Renovar o link só estende a validade (`pagamentos.expira_em` do link ativo); o mesmo endereço volta a funcionar. Vencido ou pago bloqueia novo pagamento e mostra o estado.
- **Kill switch**: segredo `CHECKOUT_PROPRIO=false` faz o `mp-criar-link` voltar ao Checkout Pro. `CHECKOUT_BASE_URL` muda o domínio (padrão `https://suagraficabh.com.br`).
- **Nada interno na resposta**: sem SKU, custo, piso, margem ou fornecedor. O valor nunca vem do navegador.

## Página
- Topo escuro com logo e "Pagamento seguro"; banner (`ecommerce/public/banners/checkout-desktop.jpg` 1920x420 e `checkout-celular.jpg` 1080x620, gerados por `scripts/gerar-banner-checkout.cjs`).
- Carregamento com a logo animada (círculos ciano, magenta e amarelo se encontrando), respeitando `prefers-reduced-motion`.
- 1. Dados: nome, e-mail e CPF/CNPJ (só pede o que falta; salva em `contacts`; o documento salvo volta só com 3 dígitos).
- 2. Arte (prioridade do upsell): já tenho pronta / conferir e ajustar (R$ 14,90) / criar a arte (R$ 39,90). Muda o pedido e o total na hora (`checkout_definir_arte`); a arte não tem custo de fornecedor, então só soma lucro. Arte inclusa por condição especial não é alterada.
- 3. Pagamento: aba Pix primeiro (QR Code + copia e cola + "Copiar código", reaproveita o Pix pendente do mesmo valor) e aba Cartão (Payment Brick oficial só com crédito, até 12x). **Até 2x sem juros** (a conta do Mercado Pago absorve); de 3x a 12x o Mercado Pago cobra os juros do cliente e mostra o total no formulário (decisão do dono, 18/11/2026). O alerta de "pago com juros" só vale até 2x. Cartão aprovado cancela Pix pendente do pedido.
- Cross-sell "Aproveite e leve junto": até 3 cards por pedido, vindos de `private.checkout_sugestoes` (categoria do pedido, conversa dos últimos 30 dias, histórico de compras pagas e quantidade parecida). Adicionar usa `calcular_preco` (planilha, com piso) e atualiza orçamento e PDF; só os itens do checkout podem ser removidos.
- Resumo completo: itens, subtotal, desconto, frete grátis, total, entrega, previsão, validade do link e como pagar (Pix, 1x ou 2x sem juros).
- Confirmação: atualiza sozinha (consulta o status a cada 4 s), mostra "Pagamento confirmado!", forma (Pix ou 2x de R$ X sem juros) e o próximo passo da arte com botão de WhatsApp. A mensagem de confirmação no WhatsApp continua sendo a do `cliente-pago-avisar` (WF5).

## Mais upsell e pedido sempre atualizado
- **Quantidade**: card "Leve mais e pague menos por unidade" com as tiragens do mesmo produto e versão (`private.checkout_quantidades`, `checkout_trocar_quantidade`); preço sempre de `calcular_preco`.
- **Sugestões variadas (19/11/2026)**: 5 a 6 cards por pedido, SEMPRE de produtos diferentes e coerentes com o tipo do produto principal. As combinações ficam na tabela `checkout_combinacoes` (tipo de produto de origem, categoria sugerida, motivo e pontos; o admin edita). Pedido sem regra própria recebe sugestões gerais (cartão, adesivo, tags, sacolas, canetas, calendário, ímã). O item de cada categoria é escolhido por faixa de preço (complemento acessível, perto de 35% do pedido, entre R$ 50 e R$ 400), com variação entre pedidos, e nunca repete o material do item principal. Antes, o checkout sugeria sempre o mesmo cartão PVC. Até 5 itens extras.
- **Toda mudança** (arte, quantidade, item) atualiza na hora: itens do pedido, orçamento e PDF (`private.checkout_sincronizar_orcamento`), valor do link ativo e histórico do pedido. Um Pix pendente com o valor antigo é cancelado no Mercado Pago. Teste: `supabase/tests/checkout_melhorias.sql` (termina em "OK").
- Sem banner de cookies na página de pagamento.

## Lembrete no WhatsApp
Regra `PAG_CHK` (`followup_regras`, referência `checkout_aberto`): quando o cliente abre o checkout e passa 15 minutos sem pagar, a fila de follow-up manda uma mensagem no WhatsApp dele (texto livre na janela de 24 h, template `pagamento_pendente` fora dela; só das 8h às 20h; some se o cliente responder ou pagar). Um por pedido; substitui o PAG_20M pendente e não roda se outro lembrete de pagamento saiu nos últimos 30 minutos.

## CRM
Aba Pagamento do pedido: "Atividade do cliente no checkout" (abriu, preencheu, escolheu arte, trocou quantidade, gerou Pix, cartão aprovado ou recusado, erro técnico).

## Apple Pay e Google Pay
Não entram no Payment Brick automaticamente. O Apple Pay do Mercado Pago (Brasil) é um Brick à parte e exige conta Apple Developer, verificação do domínio e certificado de comerciante (feitos pelo dono); o Google Pay não consta na documentação do Mercado Pago para o Brasil. Fica como próxima etapa quando o dono tiver a conta Apple Developer.

## Alertas ao dono (popup no app e WhatsApp)
Tudo entra em `alerta_criar('pagamento_problema', 'alta')`, que já faz push e WhatsApp mesmo no silêncio:
- cartão recusado (já existia via `mp_registrar_pagamento`);
- 2 ou mais recusas em 30 min no mesmo pedido: "chame no WhatsApp e ofereça o Pix";
- erro técnico ao cobrar (Mercado Pago sem resposta, credencial inválida, 5xx) e checkout sem configuração;
- Pix criado sem código copia e cola;
- cliente pagou parcelado COM JUROS (conta do Mercado Pago sem 2x sem juros ativo).
A linha do tempo fica em `checkout_eventos` (aberto, dados salvos, arte, Pix gerado, recusa, erro).

## Segredos e variáveis
Só falta a chave PÚBLICA do aplicativo do Mercado Pago, como segredo da Edge Function (não precisa de variável no front):
- `MP_PUBLIC_KEY_PRODUCAO` (e `MP_PUBLIC_KEY_TESTE` para o modo teste). A chave pública é feita para o navegador; o `checkout-dados` a entrega à página conforme `MP_MODO`.
- Sem ela o Pix funciona e a aba Cartão mostra aviso.
- Os demais segredos (`MP_ACCESS_TOKEN_*`, `MP_WEBHOOK_SECRET_*`, `MP_MODO`) já existem.

## Publicar (nesta ordem)
1. Migration `20261218000012_checkout_proprio.sql` (já aplicada no banco).
2. Segredo `MP_PUBLIC_KEY_PRODUCAO`.
3. Deploy das funções: `supabase functions deploy checkout-dados --no-verify-jwt`, `checkout-mp-processar --no-verify-jwt`.
4. Merge na `main` para publicar a loja (a rota `/pagar/<token>` precisa estar no ar).
5. SÓ DEPOIS: `supabase functions deploy mp-criar-link --no-verify-jwt` (a partir daí todo link novo da Laura vai para `/pagar`). Antes disso os links antigos do Checkout Pro seguem funcionando.
6. Conferir no painel do Mercado Pago (Seu negócio > Parcelamento) que 2x sem juros está ativo.

## Teste ponta a ponta
1. Gere um link de um pedido de teste (`mp-criar-link`) e abra em janela anônima no celular.
2. Pix: gere o QR, pague um valor baixo real e confira o pedido em Pago e a mensagem no WhatsApp.
3. Cartão 2x: pague um pedido de teste com o cartão de teste do Mercado Pago (nome do titular `APRO`) e confira "2x de R$ X sem juros" na confirmação.
4. Recusa: titular `OTHE`; confira o alerta no app.
Testes automáticos: `npm run test:checkout` (regras puras) e `supabase/tests/checkout_proprio.sql` (banco, termina em "OK").
