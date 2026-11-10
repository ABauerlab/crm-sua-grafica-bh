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

Frete público: sempre retirada grátis no balcão da Praça Sete; na região central, entrega grátis (com pedido mínimo); no resto da Grande BH, entrega por aplicativo com valor confirmado no WhatsApp; fora da Grande BH, envio para todo o Brasil com frete calculado no checkout (SuperFrete, Fase 9).

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

Fase 9: `opcoes` aceita também `entrega: "envio"` (com `cep` e `frete_servico: "pac"|"sedex"|"mini"`), `pagamento: "pix"` (padrão, exige `cliente.email`) ou `"cartao"` e `sessao` (id anônimo do carrinho). A resposta traz `pedido_id`, `metodo` e, no Pix, `pix: { copia_e_cola, qr_base64, expira_em }`; no cartão, `link_pagamento`.

## POST `/api/v1/frete`
`{ cep, itens: [{ ref, quantidade }], arte }` -> endereço do CEP, `frete_gratis`, `grande_bh`, `falta_para_frete_gratis` e `envio: { disponivel, motivo, opcoes: [{ servico, nome, valor, prazo_dias }] }`.

## POST `/api/v1/checkout/pay`
`{ pedido_id, metodo: "pix"|"cartao", email? }` troca a forma de pagamento de um pedido já criado.

## POST `/api/v1/carrinho`
Grava o carrinho para o follow-up de abandono. `GET /api/v1/pedido/status?id=<pedido_id>` devolve `{ ok, numero, pago }`.

## Taxonomia e filtros (Fase 12)
Organização para consulta: **vertical > categoria > subcategoria** (as subcategorias são as do menu do fornecedor, com nome de balcão, por exemplo "Couchê 250g"). Nenhuma rota devolve custo, piso ou margem.

### GET `/api/v1/taxonomia`
`{ verticais: [{ id, nome, descricao, modelos, categorias: [{ slug, nome, produtos, modelos, a_partir_de, foto, subcategorias: [{ slug, nome, modelos }] }] }] }`. Verticais: `papelaria`, `embalagens`, `rotulos`, `editorial`, `visual`, `brindes`, `festas` e `mostruario` (Kit de Mostruário).

### GET `/api/v1/facetas?categoria=cartoes-de-visita&q=&acab=soft-touch,uv&gram=encorpado`
`{ total, facetas: { sub, acab, tipo, material, gram, formato, prazo, preco: [{ valor, rotulo, n }] } }`. `n` conta MODELOS (um card por modelo, nunca por tamanho). Padrão de faceta: OU dentro da mesma faceta, E entre facetas; os contadores de uma faceta ignoram o filtro dela mesma. `categoria` aceita várias, separadas por vírgula.

| Faceta | Valores |
|---|---|
| `sub` | slug da subcategoria (um só) |
| `acab` | `hot-stamping`, `relevo`, `uv`, `soft-touch`, `fosca`, `brilho`, `holografica`, `padrao` |
| `tipo` | `liso`, `rustico`, `nobre`, `sintetico` |
| `material` | `couche`, `offset`, `duplex`, `kraft`, `reciclato`, `apergaminhado`, `supremo`, `pvc`, `bopp`, `acrilico`, `polionda`, `psai`, `neoplex`, `mdf`, `acm`, `vinil`, `tecido`, `lona` |
| `gram` | `leve` (menos de 150g), `medio` (150g a 250g), `encorpado` (251g a 350g), `extra` (acima de 350g) |
| `formato` | `retangular`, `quadrado`, `arredondado`, `faca-especial` |
| `prazo` | `express` (até 1 dia útil), `padrao` (2 a 4), `especial` (5 ou mais) |
| `preco` | `ate-50`, `50-150`, `150-500`, `500-mais` (preço "a partir de" da opção) |

### GET `/api/v1/modelos?categoria=&q=&acab=&ordem=menor_preco|maior_preco|relevancia&limite=24&pagina=1`
`{ total, modelos: [{ titulo, categoria, subcategoria, produto_slug, foto, a_partir_de, parcela_2x_a_partir_de, ref, sku, quantidade, variacoes, prazo_dias_uteis, acab }] }`.

### Banco
`loja_arvore()`, `loja_facetas(p_categorias, p_termo, p_filtros)`, `loja_modelos_f(...)` e `loja_interpretar_busca(termo)` (sinônimos: "papel grosso" vira `gram=encorpado`, "aveludado" vira `acab=soft-touch`, "metalizado/dourado" vira `acab=hot-stamping`, "papel marrom" vira `material=kraft`). Dados em `loja_verticais`, `loja_taxonomia`, `loja_subcategorias`, `loja_facetas_def` e `loja_sinonimos` (só o servidor lê). Os atributos de cada opção ficam em `private.loja_atributos`, recalculados a cada 15 min só quando a vitrine muda (`private.loja_atributos_atualizar(true)` força).

## Para o n8n e a Laura
A Laura continua usando as mesmas funções do banco pelas ferramentas que já existem; os números batem com o site porque a fonte é a mesma. Se um fluxo externo precisar cotar por HTTP, use as rotas acima.

## Famílias e tamanhos (Fase 13)
`/api/v1/modelos` devolve uma OPÇÃO por item (`familia`, `titulo`, `tags`, `tamanhos`, `quantidade`, `a_partir_de`), não um item por tamanho. Banco: `loja_familia(p_familia)` devolve `{ titulo, categoria, subcategoria, tags, tamanhos: [{ produto_slug, tamanho, impressao, a_partir_de, quantidade, prazo_dias_uteis, ref }] }`; cada tamanho aponta para `/api/v1/products/{ref}` e `/produto/[slug]`. `loja_arvore` traz foto e contagem de opções por subcategoria. `loja_facetas_home()` é a versão pré-calculada das facetas da loja inteira.
