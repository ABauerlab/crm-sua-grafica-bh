# E-commerce da Sua Gráfica BH (suagraficabh.com.br)

Roteiro aprovado pelo dono em 09/11/2026. Um PR por fase; cada fase para e espera validação.

## Decisões
- O preço de venda vem da **planilha oficial de preços de venda** (não há mais pesquisa de mercado). A planilha tem custo e NUNCA entra no repositório.
- Endereço do balcão é público (Rua Rio de Janeiro, 462, 22º andar, sala 2217, Edifício Helena Passig, Praça Sete), sempre como ponto de retirada agendada.
- Loja em Next.js na Hostinger (app Node.js, Base Directory `ecommerce/`). O CRM continua na raiz.
- O SKU do fornecedor é interno: a vitrine pública expõe só `ref` (código aleatório estável).

## Estado das fases
| Fase | Conteúdo | Situação |
|---|---|---|
| 1 | Pasta `ecommerce/` isolada, layout, rodapé com crédito Bauerlab, botão do WhatsApp por contexto, selos, JSON-LD da empresa, robots e sitemap inicial | **feito** |
| 3 | Planilha como fonte do preço (`calcular_preco`), carga em lotes, tela de importação no CRM, vitrine `ecommerce_products`, pesquisa de mercado desligada no n8n | **feito** (20.381 SKUs carregados) |
| 2 | Ficha técnica, acabamento padrão, texto e foto de cada produto a partir da página pública da origem interna (fila `loja_fichas`, função `loja-fichas`, uma página a cada 2 s, robots liberado), em linguagem de balcão e sem citar a origem | **feito** (fila rodando em produção) |
| 4 | API `/api/v1` (busca, cotação, cálculo com frete, checkout com link do Mercado Pago), route handlers chamando funções do banco e a Edge Function `loja-checkout`. Contratos em `docs/api-v1.md` | **feito** |
| 5 | Vitrine (home com mais vendidos e banners, categorias, busca), página de produto com configurador (quantidade, arte, CEP, prazo, Pix e 2x), 4 abas, variações, carrinho com fechamento pelo checkout da Fase 4, modal de WhatsApp antes de comprar, banner "Cobrimos qualquer orçamento" (proposta pelo WhatsApp; a Laura usa a condição G2), logo oficial do brandkit | **feito** |
| 6 | Bling: colunas fiscais (NCM sugerido por categoria, CFOP 5102/6102/6108), payload de pedido com pendências, `bling-webhook` (só grava), preço e prazo por marketplace, gerador de anúncios. Nada é enviado. Detalhes em `docs/bling-fiscal.md` | **feito** |
| 7 | Meta Pixel + `meta-conversions-api` com deduplicação por `event_id` | pendente |
| 8 | Blog (NewsAPI só como pauta, texto próprio com link da fonte) e Central de Ajuda completa | pendente |
| 9 | Checkout em 3 passos, `carrinhos_abandonados`, frete grátis só nos 7 bairros centrais, SuperFrete, Pix copia e cola | pendente |
| 10 | JSON-LD de produto, sitemap dinâmico, varredura de segurança e PR final | pendente |

## Banco (Fase 3)
- `catalogo`: `preco_venda`, `preco_mercado_ref`, `prazo_cliente_dias`, `peso_frete_kg`, `embalagem_cm`, `tipo_embalagem`, `estrategia_preco`, `preco_planilha_em`.
- `parametros_comerciais`: `fonte_preco` (`planilha` | `mercado`) e `lucro_bruto_minimo` (65). `lucro_liquido_minimo` subiu para 65.
- `planilha_precos_import` (staging privada), `importar_precos_planilha(linhas, token)`, `aplicar_planilha_precos_lote(depois, limite, token)`, `aplicar_planilha_precos(token)` (completa, só para SQL/service role por causa do tempo), `planilha_precos_relatorio()`.
- Carga: dono logado no CRM ou service role. O caminho por token temporário (`app_segredos.importar_precos_token`, 2 h) só serve para usuário logado; `anon` não executa mais as funções de carga (migration `20261115000005`).
- `ecommerce_products` (leitura pública sem a coluna `sku`), `ecommerce_sincronizar()`.
- No modo planilha, `validar_margem` e `montar_opcoes` exigem lucro BRUTO mínimo (como a planilha); prejuízo e piso duro continuam bloqueando sempre.

## Rodar
```bash
cp ecommerce/.env.example ecommerce/.env.local   # chave publicável
npm run dev:ecommerce                            # http://localhost:3001
npm run build:ecommerce
```

## Fase 2: fichas e fotos
- **Fonte:** a página pública de cada produto na origem interna (endereço só em `app_settings.fotos.origem_base`). Uma página por produto (caminho sem o último segmento, que é o SKU): 3.829 produtos para 18.995 SKUs.
- **Fila:** `loja_fichas` (`pendente`, `processando`, `ok`, `erro`; até 3 tentativas). Agendamento `loja-fichas` a cada minuto, 15 produtos por vez, uma página a cada 2 s (cerca de 4 h para tudo). Configuração em `app_settings.loja_fichas` (`ligado`, `por_execucao`, `intervalo_ms`, `verificar_marca`). Resumo: `select loja_fichas_resumo()` logado como dono.
- **O que entra na vitrine:** `ecommerce_products.ficha` (título, material, espessura, impressão, tamanho final, arte com sangria, acabamento e até 4 observações), `acabamentos` (o acabamento padrão) e `fotos` (caminho no bucket público `loja-produtos`, nome por hash). O título da ficha passa a ser o título da vitrine (gatilho `ecommerce_titulo_da_ficha`).
- **Sigilo:** frases com a marca da origem são descartadas e a ficha é conferida de novo antes de sair (`_shared/ficha-origem.ts`, testado em `npm run test:loja` com marca fictícia). O código do item da origem não vai para a ficha pública.
- **Fotos:** a foto leve (até 300 KB) só tem os metadados removidos, sem decodificar (`_shared/jpeg.ts`); a pesada é recomprimida, no máximo 2 por execução, porque decodificar imagem estourava o limite de CPU da função (erro 546). As que sobram voltam por `loja_fotos_pegar`; o agendamento continua rodando enquanto houver foto pendente (cerca de 120 fotos grandes por hora depois que as fichas acabarem). A verificação de marca por IA está desligada, como nas fotos do WhatsApp (decisão do dono: as fotos da origem não têm logo); dá para ligar com `verificar_marca = true` e o segredo `GEMINI_API_KEY`.
- **Não disponível na página pública:** acabamentos opcionais com preço e links de gabarito exigem login na origem. Tiragens e prazos já vêm da planilha. Se o dono quiser os opcionais e os gabaritos, a alternativa é ele exportar ou enviar os gabaritos por categoria, que entram no bucket `loja-produtos` e em `ecommerce_products.gabaritos`.

## Fase 5: vitrine e compra
- Páginas: `/` (mais vendidos, banners de campanha com fotos dos produtos), `/categorias`, `/categoria/[slug]` (filtro), `/busca`, `/produto/[slug]` (configurador, abas Descrição, Ficha técnica, Arquivo e arte, Prazo e entrega, outras opções, JSON-LD de produto), `/carrinho` (arte, entrega, dados, total e "Ir para o pagamento").
- Banco: `loja_categorias`, `loja_produto` (opções e variações), `loja_slugs` (sitemap com todas as categorias e produtos).
- Carrinho e cliente ficam no navegador (`localStorage`); o preço é sempre recalculado no servidor. O modal de WhatsApp aparece no primeiro "Comprar" ou "Adicionar". A gravação do carrinho abandonado (follow-up de 15 min) entra na Fase 9.
- Marca: símbolo oficial do brandkit (`ecommerce/public/marca/simbolo.svg`, cores #00A6D6, #E6007E, #FFD500); o nome é texto em Montserrat.
- A Laura já informa o endereço do balcão (prompt do WF2) e a trava de saída já o libera; nada mudou no n8n.
