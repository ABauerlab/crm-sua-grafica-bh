# Orçamento em PDF (Etapa 4)

O cliente recebe no WhatsApp um PDF com a identidade da Sua Gráfica BH. O preço, o prazo, o frete e a condição especial já vêm calculados pelo banco; o PDF só mostra. **Sem custo, margem, piso, fornecedor, SKU nem endereço de retirada.**

## Peças

| Peça | Onde | O que faz |
|---|---|---|
| `montar_orcamento(p_contact, p_itens, p_opcoes)` | banco (migration `20261029000009`) | Recebe SKUs (nunca texto livre), chama `calcular_preco`, `calcular_prazo`, `verificar_frete` e `validar_margem`, grava `orcamentos`/`orcamento_itens` (rascunho, número SG-0001, validade de 48 h em `parametros_comerciais.validade_orcamento_horas`). Regra, confiança, margem e custo total ficam só no banco. Devolve JSON mínimo. Bloqueado: `status`, `motivo` e `alternativa` (sem piso nem custo). |
| `orcamento_documento(p_orcamento)` | banco | Documento público do PDF (só o que o cliente vê) e o `hash` usado para não gerar de novo sem mudança. O prazo é recalculado na hora. |
| `orcamento_renovar(p_orcamento)` | banco | Orçamento vencido vira um novo, recalculado (mesmo SKU e quantidade); o antigo fica `expirado`. |
| `preparar_link_pagamento(p_orcamento)` | banco | Defesa final antes de cobrar: recusa vencido, encerrado, pago, SKU inválido, piso duro e prejuízo (`validar_margem`); cria o pedido a partir do orçamento e confere que o valor do pedido é igual ao do orçamento. |
| `orcamento-pdf` | Edge Function | Renderiza `_shared/orcamento-html.ts` no Gotenberg, guarda no bucket privado `orcamentos`, registra o hash, passa o rascunho para `enviado` e envia o PDF como documento no WhatsApp (legenda = frase do agente). Ações: `gerar`, `enviar` (uma vez por versão do PDF), `reenviar` (botão do CRM). |
| n8n | `GBH | FERRAMENTA | montar_orcamento`, `gerar_pdf_orcamento`, `gerar_link_pagamento`, `GBH | WF3 | Orçamento PDF` | Ferramentas do agente e pipeline. Desativados até a Etapa 8. Ver `docs/n8n-mapa.md`. |

## Regras

* **Opções de arte:** R$ 39,90 só a arte (`parametros_comerciais.arte_valor`) e R$ 49,90 arte com frete grátis na região central (`arte_frete_valor`, sem exigir o pedido mínimo). Se a entrega não for elegível, a arte com frete vira só a arte e o agente recebe o aviso `arte_com_frete_indisponivel`. Sem arte definida, o PDF mostra as duas opções.
* **Frete:** `bike_gratis` (região central elegível), `uber_cliente` (por conta do cliente, não entra no total) ou `retirada`. A retirada grátis aparece sempre, sem endereço; o endereço e o horário só seguem depois do pagamento.
* **Upsell por regra:** cartão leva adesivo ou panfleto; segmento Barbearia, Delivery, Loja ou Lançamento leva o kit; compra sem arte leva o serviço de arte. Um por orçamento.
* **Prazo com data:** "Se pagar e enviar a arte até 12h de hoje, fica pronto em dd/mm". Vem de `calcular_prazo` (dias úteis do fornecedor + 1 de logística, corte às 12h, feriados).
* **Condição especial:** o orçamento atualizado (nova versão) mostra "Condição especial válida até dd/mm às hh:mm" e o valor final, sem piso, margem, custo nem como foi calculada. O link de pagamento anterior é invalidado por `mp-criar-link` (`forcar_novo`).
* **Vencido:** `orcamento-pdf` e `preparar_link_pagamento` nunca usam preço velho.
* **Taxa do método:** `validar_margem` desconta a taxa do método previsto (Pix 0,99%, cartão 4,98%; sem método conhecido vale o cartão, o pior caso). Quando o pagamento chega, `private.confirmar_pagamento` grava no pedido a taxa real (`taxa_pagamento_real_pct`) e o lucro líquido real (`lucro_liquido_real`).
* **Número:** o orçamento usa `SG-0001` (sequência própria). O pedido também exibe `SG-` com a numeração dele (referência do Mercado Pago). São sequências diferentes; ver pendências em `docs/agente/depende-de-voce.md`.

## Infra: Gotenberg

`infra/gotenberg/docker-compose.yml` (imagem `gotenberg/gotenberg:8`). Instale no Coolify e defina `GOTENBERG_USER` e `GOTENBERG_PASSWORD`. Segredos da Edge Function `orcamento-pdf` (Supabase > Edge Functions > Secrets): `GOTENBERG_URL`, `GOTENBERG_USER`, `GOTENBERG_PASSWORD` (e os de sempre: `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`). Deploy: `supabase functions deploy orcamento-pdf --no-verify-jwt`.

A fonte Inter vem do Google Fonts; se o Gotenberg não tiver internet, o PDF cai para Helvetica/Arial (continua correto, só muda a fonte).

## Exemplos e testes

`docs/exemplos-orcamento/` tem 6 PDFs gerados com o **catálogo fictício de teste** (não é o do fornecedor): cartão simples, kit de divulgação, com arte, entrega central grátis, fora da região com frete do cliente e condição especial. Para refazer: `supabase/tests/rodar-local.sh` e `npm run exemplos:orcamento`.

* `supabase/tests/orcamento_etapa4.sql` (49 testes): montagem, recusas, documento público, hash, vencido, link, travas, lucro real, permissões.
* `scripts/test-orcamento.ts` (`npm test`): modelo HTML (escape, arte, frete, condição especial, sem dado interno) e os 6 PDFs (até 2 páginas, leves, sem SKU, custo, margem, piso nem endereço).

## CRM

Pedido > aba **Orçamentos**: número, status, valor, validade, margem líquida, regra e confiança do preço (só o dono vê), abrir PDF e **Enviar/Reenviar**. Orçamento vencido vira um novo ao reenviar. O cartão do kanban mostra "Orç. enviado", "Orç. pago" etc.
