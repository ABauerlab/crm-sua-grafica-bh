# API pública da loja (`/api/v1`)

Rotas do Next.js em `ecommerce/app/api/v1/`. Elas só repassam para funções do banco (chave publicável) ou para a Edge Function `loja-checkout`. Preço, prazo, frete e trava de lucro são os mesmos do CRM e da Laura (`calcular_preco` com a planilha oficial, `calcular_prazo`, `verificar_frete`, `montar_orcamento`, `validar_margem`). O produto é identificado pelo `ref` público da vitrine (nunca pelo SKU). Nenhuma resposta tem custo, piso, margem, SKU nem detalhe interno de entrega.

Erros sempre como `{ "error": "mensagem pronta para o cliente" }` com o status HTTP adequado. Limite por IP: 60 por minuto nas leituras e 5 por minuto no checkout. O banco ainda limita o checkout a 3 por WhatsApp a cada 10 minutos e 30 por hora no site inteiro.

## GET `/api/v1/products/search?q=&limite=12&categoria=`
Busca sem acento e por radical ("cartao" acha "Cartões"); entende A3 a A7 pelas medidas e ignora palavras como "de" e "com". Agrupa as opções de quantidade de cada produto.
```json
{ "total": 141, "produtos": [ { "produto_slug": "...", "titulo": "...", "categoria": "...", "categoria_slug": "...", "impressao": "Colorido Frente e Verso",
  "formato": "91 x 51 mm (9,1 x 5,1 cm)", "foto": "loja-produtos/ab/abc.jpg", "a_partir_de": 72.9, "parcela_2x_a_partir_de": 36.45, "prazo_dias_uteis": 3,
  "opcoes": [ { "ref": "332e31afceaf", "quantidade": 50, "preco": 72.9, "parcela_2x": 36.45 } ] } ] }
```
A foto é um caminho no Storage público: `https://<projeto>.supabase.co/storage/v1/object/public/<foto>`.

## GET `/api/v1/products/:ref/quote?arte=pronta|conferencia|criacao&cep=30160040`
Preço da opção, arte (pronta R$ 0, conferência técnica R$ 14,90, criação R$ 39,90 com +1 dia útil), total, pagamento (Pix e 2x sem juros), prazo com data e frase do corte das 10h30, e frete quando o CEP vem.

## POST `/api/v1/quotes/calculate`
```json
{ "itens": [ { "ref": "332e31afceaf", "quantidade": 2 } ], "arte": "conferencia", "cep": "01310100" }
```
`quantidade` é o número de lotes da opção (2 x 50 un = 100 un). Devolve itens, subtotal, arte, total, pagamento, o prazo mais longo e o frete.

Frete público: sempre retirada grátis no balcão da Praça Sete; na região central, entrega grátis (com pedido mínimo); no resto da Grande BH, entrega por aplicativo com valor confirmado no WhatsApp; fora da Grande BH, envio para todo o Brasil com frete calculado no checkout (SuperFrete entra na Fase 9).

## POST `/api/v1/checkout/create-preference`
```json
{ "cliente": { "whatsapp": "(31) 97561-8243", "nome": "Maria da Silva", "email": "maria@exemplo.com", "documento": "529.982.247-25" },
  "itens": [ { "ref": "332e31afceaf", "quantidade": 1 } ],
  "opcoes": { "arte": "pronta", "entrega": "retirada", "cep": null } }
```
Cria ou completa o contato pelo WhatsApp (nunca sobrescreve o cadastro), monta o orçamento com a trava de lucro, gera o pedido (origem `site`, etapa Aguardando pagamento) e devolve o link do Mercado Pago:
```json
{ "ok": true, "numero": 230, "total": 166.8, "prazo": "...", "data_prevista": "2026-11-13", "link_pagamento": "https://..." }
```
Pix copia e cola direto na tela entra na Fase 9.

## Para o n8n e a Laura
A Laura continua usando as mesmas funções do banco pelas ferramentas que já existem; os números batem com o site porque a fonte é a mesma. Se um fluxo externo precisar cotar por HTTP, use as rotas acima.
