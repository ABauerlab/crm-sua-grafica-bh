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
| 7 | Meta Pixel + Conversions API com deduplicação por `event_id`, aviso de cookies (LGPD), Purchase no servidor quando o pagamento é aprovado | **feito** (falta criar o Pixel e o token na Meta) |
| 8 | Blog automático (feeds do setor como pauta, texto próprio com crédito e link da fonte; NewsAPI opcional) e Central de Ajuda completa | feito |
| 9 | Checkout em 3 passos (`/checkout`), `carrinhos_abandonados`, frete grátis só nos 7 bairros centrais (CEP resolvido para bairro), SuperFrete (falta o token), Pix copia e cola | **feito** (site publicado na Hostinger; falta DNS) |
| 10 | JSON-LD de produto, sitemap dinâmico, varredura de segurança e PR final | **feito** (JSON-LD e sitemap já vinham da Fase 5; esta fase fechou a segurança e a verificação no domínio real) |

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

## Fase 7: Meta Pixel e Conversions API
- **Eventos:** PageView (toda página), ViewContent (produto), AddToCart (configurador), InitiateCheckout (carrinho), Lead (qualquer clique para o WhatsApp) e Purchase (no banco, quando o pedido vira pago; pedidos de teste não contam).
- **Deduplicação:** cada evento do navegador vai ao Pixel e ao servidor com o MESMO `event_id`; o Purchase usa `purchase-<pedido>` (um por pedido).
- **Caminho:** loja `POST /api/v1/eventos` -> `meta_evento_registrar` (só aceita os nomes previstos e dados pessoais já em SHA-256) -> fila `meta_eventos` -> Edge Function `meta-conversions-api` (a cada minuto, enquanto houver pendente; eventos com mais de 7 dias são descartados, limite da Meta).
- **Privacidade (LGPD):** o Pixel e os eventos do navegador só ligam depois do "Aceitar" no aviso de cookies. Telefone, e-mail e id do cliente vão sempre em SHA-256. O Purchase é enviado pelo servidor, também em hash; isso deve constar na política de privacidade.
- **Teste de eventos:** colocar o código de teste do Gerenciador de Eventos em `app_settings.meta_capi.test_event_code`; tirar depois.
- **Ativar:** criar o Pixel (conjunto de dados) no Gerenciador de Eventos do Business "Sua Gráfica BH", gerar o token da Conversions API e cadastrar `META_PIXEL_ID` e `META_CAPI_TOKEN` nos segredos do Supabase e `NEXT_PUBLIC_META_PIXEL_ID` nas variáveis da loja na Hostinger.

## Fase 8: Blog e Central de Ajuda
- **Blog:** detalhes em `docs/blog.md`. Edge Function `blog-pautas`, tabelas `blog_fontes`, `blog_pautas`, `blog_posts`, agendamento `blog-pautas` (07h, 12h e 17h). Publica sozinho até 3 posts por dia, só depois de passar no filtro de assunto e na conferência do texto.
- **Central de Ajuda (`/ajuda`):** 6 categorias (arquivos, prazos, entrega e retirada, pagamentos, cobrimos qualquer orçamento, garantia e pós-venda), busca no navegador sem acento, JSON-LD `FAQPage`, orçamento personalizado (`#orcamento`), balcão e mapa. Conteúdo em `ecommerce/lib/ajuda.ts`.
- Menu de topo e rodapé com link para o Blog; sitemap com `/blog` e os posts.

## Fase 9: checkout, frete e Pix
- **Checkout (`/checkout`)**: 1) dados (WhatsApp, nome, e-mail obrigatório, CPF/CNPJ opcional), 2) entrega (retirada, entrega local ou envio), 3) pagamento. Pix é o padrão: QR Code e copia e cola na tela, que consulta o pedido a cada 4 s e confirma sozinha. Cartão abre o link do Mercado Pago. Dá para trocar de Pix para cartão (o Pix pendente é cancelado).
- **Frete grátis só nos 7 bairros** ativos em `zonas_frete_gratis` (Barro Preto, Centro, Funcionários, Lourdes, Santa Efigênia, Santo Agostinho, Savassi), com pedido mínimo e cabendo na bike. O CEP vira bairro em `loja-frete` (ViaCEP, com BrasilAPI de reserva) e fica em `cep_bairros`; a cidade precisa ser Belo Horizonte ("Centro" existe em toda cidade). CEP que ainda não passou pelo site e é consultado pela Laura segue a faixa antiga 30110-30199 (mais larga): **melhoria pendente**, a Laura chamar `loja-frete` antes de prometer frete.
- **Grande BH fora dos 7 bairros**: entrega por aplicativo, valor confirmado no WhatsApp (não entra no pagamento do site). **Fora da Grande BH**: envio pelos Correios cotado no SuperFrete (PAC, SEDEX, Mini Envios); o frete entra no pedido como item com preço igual ao custo e a trava de lucro confere antes de cobrar. O valor é sempre recotado no servidor.
- **SuperFrete**: precisa do segredo `SUPERFRETE_TOKEN` (opcional `SUPERFRETE_USER_AGENT` e `SUPERFRETE_CEP_ORIGEM`, padrão 30160040). Sem o token o envio nacional aparece como "calculamos pelo WhatsApp" e nada é inventado. **Não testado com token real.**
- **Carrinho abandonado**: `carrinhos_abandonados` guarda o carrinho (valor recalculado no banco) e vira `recuperado` quando o pedido nasce. A view `v_carrinhos_recuperar` lista quem parou há 15 min a 24 h, com `consentiu` e `janela_aberta`. **O envio do follow-up não foi ligado**: marketing só com consentimento e fora das 24 h exige template aprovado pela Meta.
- **Pix direto**: `POST /v1/payments` do Mercado Pago com `external_reference` do pedido; o `mp-webhook` e o `mp-conferir` já reconhecem o pagamento pelo mesmo caminho do cartão.
- **Hostinger**: site Node.js `suagraficabh.com.br`, repositório `ABauerlab/crm-sua-grafica-bh`, branch `main`, Root Directory `ecommerce`, app `next`, Node 22, **Output Directory `.next`** (sem isso a publicação falha com erro 500 interno da Hostinger). Variáveis: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` (chave anon, também usada como Bearer) e `NEXT_PUBLIC_SITE_URL`. Depois de mudar variável `NEXT_PUBLIC_*` é preciso novo build.

## Fase 10: segurança e fechamento
- **Site no ar**: `https://suagraficabh.com.br` (DNS no Registro.br: `A` da raiz em 186.244.148.143 e `CNAME` do `www`; o MX do e-mail não mudou). Certificado vitalício ativo, `http` redireciona para `https`, `www` responde. Todas as rotas respondem 200, sem rolagem lateral em desktop e celular, JSON-LD de produto presente (`Product` e `LocalBusiness`) e `noindex` no checkout e no carrinho.
- **Varredura**: `anon` não lê `v_funil_vendas_ia`, `carrinhos_abandonados` nem `cep_bairros` e não chama `loja_frete_base` nem `loja_carrinho_fechar`. **Achado corrigido**: `calcular_acabamento_seguro` devolvia dias e custo de acabamento a qualquer chamador com a chave pública (migration `20261123000001`; nada a usava). `npm audit` da loja foi de 2 vulnerabilidades (postcss dentro do Next) para 0, com `overrides.postcss` em `ecommerce/package.json`.
- **Avisos que ficam (conferidos, sem exposição)**: `v_funil_vendas_ia` aparece como SECURITY DEFINER no linter, mas `anon` não tem permissão nela; tabelas internas com RLS e sem política (`cep_bairros`, `app_segredos`, `webhook_eventos`, `e2e_*`) são só da service role, de propósito; funções `loja_*` e `meta_evento_registrar` liberadas ao anônimo são a API pública. **Pendente do dono**: ligar "Leaked password protection" em Authentication no painel do Supabase (a API não liga).
- **Google**: enviar `https://suagraficabh.com.br/sitemap.xml` no Search Console (verificar a propriedade do domínio por DNS TXT) e conferir a cobertura depois de alguns dias.
- **Não feito**: imagem padrão de compartilhamento (Open Graph) da home e das páginas sem foto; precisa de uma arte 1200x630.

## Fase 11: vitrine em modelos, CRM e cérebro da Laura (10/11/2026)
- **Vitrine**: acabaram os cartões de contagem. `loja_modelos(p_categorias, p_termo, p_limite, p_offset)` devolve modelos reais (um por papel/acabamento, ex.: "Cartões de Visita Couchê 250g Laminação Fosca") com foto, SKU, preço a partir de e quantas opções de impressão existem. Home mostra 6 departamentos com 4 modelos cada; `/categorias` e `/categoria/[slug]` têm menu lateral por departamento (no celular vira "Departamentos e categorias") e paginação de 24.
- **Produto**: tiragem em lista com preço unitário e total, seletor de impressão (irmãos do mesmo modelo e tamanho, vindos de `loja_produto.irmaos`), arte (grátis, conferência R$ 14,90, criação R$ 39,90) e "Ref. / SKU" da tiragem escolhida. SKU público por decisão do dono; custo, piso e margem continuam fechados.
- **Banners e OG**: hero rotativo de 4 banners (corte 10h30, kits com 2x, cobrimos orçamento, retirada na Praça Sete); `ecommerce/public/og-image.jpg` 1200x630 gerada por `scripts/gerar-og-image.cjs` com fotos reais.
- **Compre junto**: sugestões por categoria (cartão + pasta, panfleto + banner...) com 1 clique no carrinho; o preço continua sendo recalculado no servidor.
- **Acabamentos extras (base pronta, sem uso no carrinho)**: `acabamentos_extras` guarda o custo (só dono) e a venda gerada = 3x o custo terminando em ,90; `loja_acabamentos` devolve só nome e venda. Falta ligar ao `loja_checkout_preparar` para cobrar de fato; por isso o site ainda NÃO mostra seletor de acabamento extra (mostrar sem cobrar seria prejuízo).
- **Extração logada do fornecedor**: `scripts/scrape-authenticated-fornecedor.ts` (modos `login` e `extrair`). Precisa rodar na máquina do dono (navegador visível, CAPTCHA). Seletores são heurísticos: rode com `--dry-run` e confira `scrape-debug/amostra.html`. Gabarito com a marca do fornecedor vai para `gabaritos-revisar/` e não é publicado (CDR/AI/PDF não se limpam por código com segurança).
- **Não feito**: a foto de perfil do WhatsApp (a API oficial não entrega foto do cliente; o CRM mostra a inicial); acabamentos extras no carrinho; gabaritos na vitrine.
- **Qualidade das fotos**: auditoria e correção feitas em 10/11/2026 (ver `docs/agente/progresso.md`). 100% dos produtos têm foto e 100% das fotos têm 1000 px ou mais. Originais guardados em `loja-produtos/originais/`.

## Fase 12: taxonomia, filtros facetados e menu por verticais (10/11/2026)
- **Menu do fornecedor conferido** (leitura do print): as 140 categorias da loja cobrem o menu. Não viram categoria porque repetem os mesmos produtos: Lançamentos, Ofertas de fim de ano, Linha Acrílico, Linha Laser, Linha Polionda, Linha Têxtil, Comunicação Visual (agregadora) e Brindes (agregadora). Pop Up Retrátil, Frame Backlight, Impressão DTF e Papel de Seda aparecem só como subcategoria ou item dentro de outras categorias.
- **Estrutura**: 7 verticais (as 5 pedidas mais "Brindes e Personalizados" e "Festas, Eventos e Delivery", porque o catálogo tem muito disso) e o canal Kit de Mostruário. Cada uma das 140 categorias pertence a uma vertical (`loja_taxonomia`). As 572 subcategorias vêm do menu do fornecedor; 85% das opções (17.231 de 20.381) já caem em uma. As demais têm título cru da origem e entram sem subcategoria.
- **Loja**: menu de topo com as verticais e mega menu (hover, só no desktop), canais fixos Kit de Mostruário e Projetos sob medida (WhatsApp), menu lateral vertical > categoria > subcategoria, página de categoria com barra de filtros (contadores, chips removíveis, ordenação; gaveta no celular), busca que entende sinônimos, selos de acabamento nos cards (sem carimbo por cima da foto).
- **Fica para depois**: configurador de acabamento na página do produto com preço (depende de `acabamentos_extras` no checkout), títulos padronizados para as ~3 mil opções com título cru, mockups fotorrealistas, filtro por tiragem mínima, faixa de cor do hot stamping.

## Fase 13: navegação em 4 níveis, tudo em uma página, PDF no checkout (10/11/2026)
- **Navegação**: vertical > categoria > subcategoria (cards com foto) > opção (família) > tamanho. Ex.: Comunicação Visual > Banners, Faixas, Lonas e Tecidos > Banners (6 opções) > Banners Front Light 240g > lista de tamanhos > produto. Página `/opcao/[familia]` lista os tamanhos; o card leva a ela quando há mais de um tamanho. Categoria sem subcategoria real (cobertura abaixo de 90%) vai direto à lista de opções com os filtros.
- **Família** (`private.loja_familias`, atualizada junto de `private.loja_atributos` a cada 15 min): título sem categoria, sem tamanho e sem acabamento; o acabamento, a impressão e "Produção 24h" viram etiquetas. 20.381 opções viram 2.447 famílias. Funções: `loja_familia`, `loja_modelos_f` (agrupa por família, até 2.000 por chamada) e `loja_facetas` (conta famílias).
- **Tudo em uma página**: sem "próxima". A lista mostra 48 e revela o resto sozinha ao rolar (`ListaModelos`).
- **Card**: nome completo (sem corte), etiquetas, "A partir de R$ X para N unidades" e, quando há, "N tamanhos". Sem carimbo por cima da foto (o carimbo "TEXTURA" de algumas fotos vem da própria imagem de origem).
- **Home e /categorias**: coluna da esquerda com departamentos e filtros desde o topo (`BarraLateral`); as facetas da loja inteira vêm de `loja_facetas_home` (cache no banco, cron `loja-facetas-home`).
- **Um item por categoria**: `loja_desagrupar` + gatilho `zz_loja_desagrupar` movem os itens de "Linha de Atacado" e "Promoções" para a categoria natural (643 de 739 e 0 de 9; o resto não tem categoria equivalente). Vale também para cargas futuras.
- **PDF no checkout**: só PDF em alta qualidade (300 dpi, sangria de 3 mm, textos em curva, CMYK). No passo de pagamento o cliente anexa o PDF (obrigatório quando a arte é "pronta" ou "conferência"; não quando a equipe cria). O pedido é criado, o PDF vai para a Edge Function `loja-arquivo` (confere `%PDF-` e `%%EOF`, até 50 MB) e só então o Pix ou o link do cartão aparece. A trava é do navegador; o pedido criado sem arquivo fica visível no CRM como "aguardando arte".
- **Texto do prazo**: "Pedidos pagos até 10h30 (dia útil) começam a ser produzidos no mesmo dia" no site e na Laura.
