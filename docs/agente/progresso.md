# Progresso do agente de IA

## Primeira venda automática: lições e correções (12/11/2026, branch `claude/laughing-ride-6sslzd`)
Cliente TEIA (sacolas), pedido pago. O que a conversa mostrou: PDF enviado 1 minuto depois de uma pergunta sem resposta; sacola 4x0 orçada para quem pediu frente e verso, com a afirmação inventada "cobre frente, verso e laterais"; tamanho da ARTE planificada (465 x 285) apresentado como tamanho do produto (`catalogo.tamanho_mm` é o da arte; o tamanho final não existe no catálogo); resumo do PDF e pedido de APROVADO repetidos depois do "aprovado".
- **Causa no prompt**: regra 19 do WF2 ("COTE LOGO") mandava cotar e enviar o PDF na mesma resposta, e a regra 1 mandava "fechamento assumido".
- **Feito (produção)**: migration `20261130000001` (`orcamento_gate_qualificacao`: bloqueia PDF com pergunta sem resposta, conversa curta demais, frente e verso pedido para item 4x0, embalagem sem tamanho final dito pelo cliente); sub-workflow `GBH | FERRAMENTA | gerar_pdf_orcamento` chama a trava antes do envio e devolve a orientação ao agente (falha da trava não bloqueia a venda); WF2 com regras 1, 19, 22 e 23 novas (publicado). Cenários `e11-01` e `e11-02` em `testes_conversa`. Teste SQL: `supabase/tests/gate_qualificacao.sql`.
- **Não feito**: conferência ao vivo no site do fornecedor (contêiner com Chrome logado na VPS, ferramenta `conferir_origem`); colunas `tamanho_final` e `tamanho_arte` no catálogo; export de `n8n/` atualizado (o MCP do n8n não grava no repositório: reexportar WF2 e `gerar_pdf_orcamento`).
- **Observado**: `agente_salvar_contato` grava `marketing_consent` booleano em coluna texto; a regex de aprovação de `preparar_link_pagamento` aceita "sim", "ok", "beleza", "certo" como aprovação.

## E-commerce/CRM Fase 16: Kanban por canal e catálogo por SKU atômico (11/11/2026, branch `feat/ecommerce-kanban-catalogo-atomico`)
- Kanban com abas Todos os Pedidos, WhatsApp (Laura) e E-commerce / Site. Os dois canais continuam no mesmo pipeline e nas mesmas travas de pagamento/arte/produção.
- Checkout passa a gravar `origin_label = 'ecommerce'`; trigger padroniza `canal = 'ecommerce'`. Valores legados `site` continuam aceitos nas funções de status e cobrança.
- Loja: cards separados por `produto_slug`, cada página lista tiragens/SKUs individuais com preço e prazo em dias úteis por opção. Ficha mostra material, gramatura, código de cores, acabamentos e prazo usando campos do catálogo. Acesso rápido às cinco categorias solicitadas.
- Migration `20261128000002_ecommerce_kanban_catalogo_atomico.sql` atualiza RPCs e trigger. **Pendente**: executar typecheck/testes/build, revisar PR e aplicar migration em produção somente após aprovação.

## E-commerce Fase 15: menu fixo, filtros na barra, ordem e cards compactos (10/11/2026, branch `claude/funny-ride-s51uyy`)
- Menu lateral fixo com rolagem própria, filtros em barra acima da lista (acompanha a rolagem), ordem por quantidade e impressão (4x0, 4x1, 4x4), cards e cabeçalho mais compactos. Migration `20261128000001` (aplicada). Detalhes em `docs/ecommerce.md` (Fase 15). Conferido em 390, 820, 1366 e 1920 px, sem rolagem lateral.

## E-commerce Fase 14: menu em etapas e departamentos completos (10/11/2026, branch `claude/funny-ride-s51uyy`)
- Menu e filtros agora abrem fechados e o cliente vai destrinchando; busca de categorias e tipos no menu e sugestões no cabeçalho; página `/departamentos` com tudo; gaveta "Departamentos" no cabeçalho; meta do Google Search Console. Detalhes em `docs/ecommerce.md` (Fase 14). Conferido em 390, 768 e 1366 px, sem rolagem lateral.
- Chaves: o dono já cadastrou `SUPERFRETE_TOKEN` e `GEMINI_API_KEY` no Supabase. Falta só o Pixel da Meta (`META_PIXEL_ID`, `META_CAPI_TOKEN` e `NEXT_PUBLIC_META_PIXEL_ID`). Falta testar o envio nacional (SuperFrete) com um CEP de fora de BH.

## E-commerce Fase 13b: duplicidade, títulos e PDF no servidor (10/11/2026)
- **Wind Banner repetido**: causa e correção em `docs/ecommerce.md` (Fase 13b). 0 opções ativas repetidas depois da correção; 1.246 variantes ocultas (257 de preço igual, 989 com preço maior) listadas por `select sku, oculto_motivo from ecommerce_products where oculto`. Rotina `private.loja_dedup` a cada 15 min; teste em `supabase/tests/loja_duplicidade.sql`.
- **Títulos crus** padronizados na origem (`titulo_vitrine`) e **PDF obrigatório** agora recusado pelo servidor (`validar_antes_de_cobrar`).
- **Não feito**: trocar as fotos com o carimbo "TEXTURA" (está dentro da imagem de origem; só dá para refazer com outra foto ou edição de imagem por IA, que não rodei em milhares de arquivos); nomear as variantes ocultas (depende do dono).

## E-commerce Fase 13: navegação em 4 níveis, tudo em uma página, PDF no checkout e Laura (10/11/2026, branch `claude/funny-ride-s51uyy`)
- **Laura (n8n, publicado)**: regra 3 do agente agora usa a frase exata de cobertura de preço quando o cliente pede desconto, acha caro ou diz que vai pesquisar (G2 só com a proposta); o nó `Montar prompt` deixou de mandar usar "vc" e o texto do corte virou "pedidos pagos até 10h30 começam a ser produzidos no mesmo dia". Export atualizado em `n8n/GBH-WF2-Agente.json`. O clone `GBH | TESTE | Agente (clone do WF2)` NÃO foi alterado. Falta rodar os cenários `e5-*` e um teste "achei caro, vou pesquisar" com o modelo real.
- **Loja**: categoria > subcategoria (cards) > opção > tamanhos; lista completa em uma página (rolagem infinita); cards com nome completo, etiquetas e quantidade; menu e filtros na home; PDF obrigatório no checkout. Detalhes em `docs/ecommerce.md` (Fase 13).
- **Banco (aplicado)**: migrations `20261126000001` a `20261126000005` (desagrupar, famílias, funções, facetas rápidas, cache das facetas da home). Edge Function `loja-arquivo` publicada.
- **Chaves e pendências para finalizar (dono)**: Hostinger tem só `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` e `NEXT_PUBLIC_SITE_URL`; falta `NEXT_PUBLIC_META_PIXEL_ID` (e novo build). Supabase (Edge Functions > Secrets), conferir: `SUPERFRETE_TOKEN` (envio nacional), `GEMINI_API_KEY` (blog e verificação de marca), `META_PIXEL_ID` e `META_CAPI_TOKEN` (Purchase no servidor). Também: "Leaked password protection" no Supabase, Search Console e o teste real de Pix pelo site.
- **Não feito**: acabamentos extras com preço no carrinho; títulos crus de ~3 mil opções (ficam sem subcategoria); o PDF no checkout só é exigido no navegador (a API não recusa pedido sem arquivo); validação de resolução do PDF (300 dpi) é só orientação.

## E-commerce Fase 12: taxonomia e filtros (10/11/2026, branch `claude/funny-ride-s51uyy`)
- **Banco (aplicado)**: migrations `20261125000001` a `20261125000005` (verticais, 572 subcategorias do fornecedor, atributos materializados com atualização a cada 15 min, `loja_facetas`, `loja_modelos_f`, `loja_arvore`, `loja_interpretar_busca`). Conferido: 8 verticais, 17.231 de 20.381 opções com subcategoria, filtro combinado responde rápido. A migration 4 foi aplicada pelo dono no SQL Editor (a confirmação do conector expirava).
- **Loja**: menu por verticais com mega menu, filtros facetados com contadores e chips, busca com sinônimos, selos de acabamento nos cards, rotas `/api/v1/taxonomia`, `/facetas` e `/modelos`. Sem rolagem lateral em desktop e celular (prints conferidos). `npm run test:loja` cobre a leitura dos filtros da URL.
- **Detalhes e o que fica**: `docs/ecommerce.md` (Fase 12) e `docs/api-v1.md`.
- **Laura (NÃO alterado no n8n)**: o WF2 publicado já tem cérebro, lista de itens, frete dos 7 bairros e tom sem "vc" repetitivo (nó do agente). Faltam dois ajustes, em `docs/agente/laura-ajustes-fase12.md`: a frase exata de cobertura de preço quando o cliente pede desconto, acha caro ou diz que vai pesquisar, e remover do nó `Montar prompt` a linha que manda usar "vc" (conflita com o agente). Exigem reescrever o workflow pelo SDK do n8n e testar com o modelo real; deixei fora desta fase para não arriscar o atendimento em produção.
- **Observado**: ~3 mil opções com título cru (sem subcategoria); filtro Express vazio (menor prazo é 2 dias úteis).

## CRM no celular: usabilidade (10/11/2026)
- **Zoom ao tocar nos campos**: o iPhone dá zoom em campo com fonte menor que 16 px. Agora todo campo tem 16 px no celular (`src/index.css`) e o `Textarea` usa `text-base`.
- **Conversa**: cabeçalho em uma linha (voltar, nome, status IA/Você, Detalhes e menu ⋯ com assumir/devolver, atenção e abrir pedido); etiquetas em uma fileira que rola; compositor com abas Responder/Nota, atalhos PDF e Link, campo que cresce com o texto e respeita a área segura do iPhone.
- **Navegação**: barra inferior (Conversas com contador, Kanban, Pedidos, Contatos, Mais); some com a conversa aberta, como no WhatsApp.
- **Kanban**: indicadores em uma fileira com rolagem lateral (antes ocupavam metade da tela).
- Telas conferidas com o simulador (`docs/telas/conversa-celular.png`, `kanban-celular.png`). Próximos candidatos: lista de conversas, Contatos e gaveta do pedido.

## Fase 11: vitrine em modelos, CRM e cérebro da Laura (10/11/2026, branch `claude/funny-ride-s51uyy`)

- **Banco (aplicado)**: migrations `20261124000001` (`loja_modelos`, SKU em `loja_buscar` e `loja_produto`, `irmaos`, `acabamentos_extras`, `loja_acabamentos`) e `20261124000002` (cérebro da Laura). Conferido: `loja_modelos` devolve 45 modelos de cartões, `anon` executa as funções novas e não lê a tabela de acabamentos.
- **Loja**: menu lateral, cards de modelo com SKU, home com vitrines por departamento, hero rotativo, configurador com tiragem e impressão, "Compre junto", Open Graph. Sem rolagem lateral em desktop e celular. **Falta publicar na Hostinger**: o deploy sai do merge na `main` (auto-deploy).
- **CRM**: coluna Pronto (aviso ao cliente em um clique: texto livre na janela, senão template `aviso_operacional_pedido`), botão para reabrir a janela de 24 h no chat, gaveta inferior de detalhes no celular, pedido manual com nome, WhatsApp, e-mail, CPF/CNPJ e endereço.
- **Laura (WF2 publicado)**: tom sem "vc" repetitivo, regra de lista de itens (um orçamento com todos), frete só nos 7 bairros por `verificar_frete` (a mesma regra do site) e bloco CÉREBRO. O cérebro é recalculado no banco a cada mensagem, sem modelo.
- **Decisões que mudei e preciso que confirme**: SKU público na loja (regras em `CLAUDE.md` e `AGENTS.md` atualizadas); a Laura continua sem citar SKU.
- **Não feito**: extração logada rodou só como código (precisa do login e do CAPTCHA do dono); acabamentos extras no carrinho; foto de perfil do WhatsApp (a API não fornece); testes com o modelo real da Laura (só validei a sintaxe da expressão do prompt).
- **Fotos (feito no banco, 10/11/2026)**: auditoria das 3.377 imagens de `loja-produtos`: 0 produtos sem foto, 729 abaixo de 1000 px (a origem só tem a imagem pequena, sem versão maior). As 729 foram ampliadas com Lanczos, limpeza de ruído e nitidez, e reenviadas no mesmo caminho (URLs inalteradas); os originais ficam em `loja-produtos/originais/`. Depois: 3.377 de 3.377 com 1000 px ou mais, a maior com 306 KB. Ampliar não cria detalhe novo; foto de produto realmente melhor só vem de uma imagem maior da origem ou de ampliador por IA. `scripts/melhorar-fotos.ts` repete a auditoria quando entrarem fotos novas.
- **Extração logada do fornecedor**: ainda sem dados (0 acabamentos e 0 gabaritos nas 20 páginas de teste, que eram abridores); falta o HTML real para ajustar os seletores. Fila lida agora em páginas (3.829 produtos).
- **Observado, não corrigido**: `agente_salvar_contato` grava `marketing_consent` como booleano, mas a coluna é texto (`none`/`opted_in`/`opted_out`); quando o cliente responde sobre promoções a gravação pode falhar. Vale um teste.

**Próximo passo:** teste real de pagamento pelo site (Pix de valor baixo, só com autorização do dono) e as pendências do dono listadas na Fase 10. O roteiro do e-commerce (Fases 1 a 10) está concluído. Ver `docs/ecommerce.md`.

## E-commerce Fase 10: loja no ar e varredura de segurança (10/11/2026)

- DNS propagado e site `suagraficabh.com.br` no ar com HTTPS (certificado vitalício, redirecionamento ligado). Conferido no domínio real: 8 rotas e um produto em desktop e celular, sem rolagem lateral, JSON-LD presente, tempo de resposta cerca de 0,7 s.
- Migration `20261123000001` (aplicada): `calcular_acabamento_seguro` fechada para `anon` e `authenticated` (vazava custo de acabamento). `npm audit` da loja: 0 vulnerabilidades (`overrides.postcss`).
- Detalhes, avisos que ficam e o que sobra para o dono em `docs/ecommerce.md` (Fase 10).
- **Visto uma vez e não reproduzido**: erro de hidratação do React (#418) numa rota no celular, em uma passada de teste; em duas voltas completas seguintes não voltou. Se aparecer no console de um cliente, investigar a página.
- **Pendente do dono**: `SUPERFRETE_TOKEN`, `GEMINI_API_KEY`, Pixel e token da Meta, "Leaked password protection" no Supabase, Search Console, imagem Open Graph. **Decisões**: follow-up de carrinho abandonado e a Laura usar `loja-frete`.
- **Não feito**: teste real de Pix e de cartão pelo site (cobrança real exige autorização).

## E-commerce Fase 9: checkout, frete, Pix e site no ar (09/11/2026)

- Migrations `20261122000001` e `20261122000002` (aplicadas): `cep_bairros`, `verificar_frete` por bairro, `loja_frete_base`, `carrinhos_abandonados` + `loja_carrinho_salvar/fechar` + `v_carrinhos_recuperar`, `loja_pedido_status`, método de entrega `correios`. Edge Functions `loja-frete` (nova) e `loja-checkout` (Pix, envio, troca de pagamento) publicadas.
- Loja: `/checkout` em 3 passos, carrinho enxuto, rotas `/api/v1/frete`, `/carrinho`, `/checkout/pay`, `/pedido/status`.
- **Site publicado na Hostinger** (`suagraficabh.com.br`, site novo criado na conta). A publicação só funcionou com Output Directory `.next`. **Falta o DNS**: o domínio usa o DNS do Registro.br e a raiz não tem registro A; o MX e o SPF da Hostinger já existem e devem ser mantidos.
- Validado: regra dos 7 bairros no banco (Savassi e Centro de BH grátis, Santo Antônio e "Centro" de São Paulo não), `loja-frete` ao vivo (CEP de BH e de SP), recusas do checkout, `npm test`, build, prints desktop e celular sem rolagem lateral.
- **Não testado ponta a ponta**: geração real do Pix e do link pelo site (evitei pedido real em produção; conferir o primeiro pedido no Kanban, título "Site SG-..."); SuperFrete sem token.
- **Pendências do dono**: DNS no Registro.br; `SUPERFRETE_TOKEN`; `GEMINI_API_KEY`; Pixel da Meta. **Decisões**: ligar o follow-up de carrinho abandonado (template de utilidade na Meta e consentimento); a Laura passar a usar `loja-frete` para o frete grátis.

## E-commerce Fase 8: blog e central de ajuda (09/11/2026)

- Migrations `20261121000001` e `20261121000002` (aplicadas): `blog_fontes` (7 feeds do setor + NewsAPI desligada), `blog_pautas`, `blog_posts`, funções públicas `loja_blog_*`, `app_settings.blog`, agendamento `blog-pautas`. Edge Function `blog-pautas` publicada.
- Primeira rodada real: 8 fontes lidas sem erro, 60 notícias, 46 barradas pelo filtro de assunto, 14 na fila.
- **Pendente do dono:** o segredo `GEMINI_API_KEY` não existe nas Edge Functions (as fotos também rodavam sem ele). Sem ele as pautas ficam guardadas e nenhum post é escrito. NewsAPI: o plano gratuito não permite produção; fica desligada (ver `docs/blog.md`).
- Loja: `/blog`, `/blog/[slug]`, `/ajuda` nova (6 categorias com busca e FAQPage). CRM: Catálogo > Blog do site.

## E-commerce Fase 7: Meta Pixel e Conversions API (09/11/2026)

- Migrations `20261120000001` e `20261120000002` (aplicadas): fila `meta_eventos`, `meta_evento_registrar`, gatilho de Purchase, lote e resultado para a função, agendamento `meta-conversions`. Edge Function `meta-conversions-api` publicada.
- Loja: Pixel (só com consentimento), aviso de cookies, eventos com `event_id` compartilhado e rota `/api/v1/eventos`.
- **Não existe Pixel na conta nem no Business da Sua Gráfica BH** (conferido pela API da Meta) e as ferramentas daqui não criam um: a fila guarda os eventos até `META_PIXEL_ID` e `META_CAPI_TOKEN` existirem.
- **Incidente corrigido na hora:** a primeira versão do gatilho de Purchase tinha um erro (faltava um valor no insert) que faria a confirmação de pagamento falhar. O teste pegou antes de qualquer pagamento (conferido: nenhum aviso do Mercado Pago no intervalo, conferência de 10 min normal). A correção também faz o gatilho nunca bloquear o pagamento por causa da medição.

## E-commerce Fase 6: estrutura fiscal do Bling e marketplaces (09/11/2026)

- Migrations `20261119000001` e `20261119000002` (aplicadas). NCM sugerido em 20.390 SKUs (todos `ncm_revisar` até o contador confirmar a regra). Payload `bling_pedido_payload` conferido num pedido pago real: monta contato e pedido e lista as pendências (CPF, CEP, endereço, IBGE, e-mail, id da loja no Bling).
- Edge Function `bling-webhook` publicada: recusa aviso sem assinatura (401) e grava os válidos em `bling_eventos`.
- `catalogo_marketplace`: CFV02 sai a R$ 191,90 no Mercado Livre e R$ 194,90 na Shopee para receber os mesmos R$ 151,90 do site.
- Nada foi enviado ao Bling. Estudo fiscal, pontos para o contador e passos de ativação em `docs/bling-fiscal.md`.
- Incidente evitado: a primeira versão de `fiscal_aplicar_ncm` recalculava as categorias a cada linha e travou por minutos; as duas sessões foram canceladas antes de afetar a operação e a função foi refeita (CTE materializado, 20 mil linhas em segundos).

## E-commerce Fase 5: vitrine, produto, carrinho (09/11/2026)

- Loja navegável de ponta a ponta: home, categorias, busca, produto com configurador e carrinho que fecha o pedido pelo checkout da Fase 4. Migration `20261118000001` (aplicada): `loja_categorias`, `loja_produto`, `loja_slugs`.
- Conferido com prints (desktop e celular, sem rolagem lateral): configurador recalcula preço, arte, prazo e frete; "Comprar agora" pede o WhatsApp e leva ao carrinho.
- **Não feito:** carrinho abandonado no banco e follow-up (Fase 9); títulos de produtos ainda sem ficha seguem crus até a fila da Fase 2 terminar.

## E-commerce Fase 4: API `/api/v1` (09/11/2026)

- Migrations `20261117000001` a `20261117000004` (aplicadas): `arte_conferencia_valor` (R$ 14,90), `loja_buscar` (com coluna `busca` pré-calculada e índice trigrama; responde em ~40 ms no banco), `loja_cotar`, `loja_calcular`, `loja_checkout_preparar`, filtros privados de frete e prazo.
- Edge Function `loja-checkout` publicada; rotas Next em `ecommerce/app/api/v1/` com limite por IP.
- Testado: busca, cotação (pronta, conferência e criação), cálculo com CEP central, Grande BH e fora de MG; checkout validado no banco dentro de transação desfeita (pedido origem `site`, item "Conferência e ajuste técnico do arquivo", total R$ 166,80 para CFV02 + conferência); recusas da função publicada (400 e 409).
- **Não testado ponta a ponta:** a geração real do link do Mercado Pago pelo site (evitei criar pedido de verdade em produção). O caminho é o mesmo `mp-criar-link` que já funciona no CRM. Primeiro pedido real pelo site: conferir no Kanban (título "Site SG-...").
- Contratos em `docs/api-v1.md`.

## E-commerce Fase 2: fichas técnicas e fotos (09/11/2026)

- Função `loja-fichas` e fila `loja_fichas` (migrations `20261116000001` e `20261116000002`, aplicadas). Lote de teste com 3 produtos: ficha, título de balcão e foto aplicados na vitrine. A fila completa (3.829 produtos) roda sozinha a cada minuto, cerca de 3 h.
- Leitor e glossário de balcão em `supabase/functions/_shared/ficha-origem.ts`; testes em `scripts/test-loja.ts` (`npm run test:loja`, dentro do `npm test`).
- **Não feito:** acabamentos opcionais com preço e gabaritos (exigem login na origem). Verificação de marca por IA desligada, como nas fotos do WhatsApp.
- **Como conferir:** `select loja_fichas_resumo()` logado como dono; abrir uma foto em `/storage/v1/object/public/loja-produtos/<caminho>`.
- Dono autorizou mesclar os PRs com testes verdes (registrado em `CLAUDE.md` e `AGENTS.md`).

## E-commerce Fases 1 e 3: base da loja e preço pela planilha (branch `claude/funny-ride-s51uyy`, 09/11/2026, pronto para revisão)

Decisões do dono: a planilha oficial de preços de venda substitui a pesquisa de mercado; endereço do balcão passa a ser público; loja em Next.js na Hostinger (`ecommerce/`); um PR por fase. Roteiro completo em `docs/ecommerce.md`.

### O que foi feito
- **Planilha conferida** (não versionada): 20.381 SKUs, 140 categorias, 0 duplicados, todos terminam em ,90, todos >= custo x 1,5, lucro bruto >= R$ 65 e nenhum com prejuízo. Com imposto e taxas, 5.841 (Pix) a 7.596 (cartão 2x) ficam com lucro LÍQUIDO abaixo de R$ 65: por isso a trava do modo planilha usa o lucro bruto, como a própria planilha.
- **Banco (aplicado em produção):** migrations `20261115000001` a `20261115000004`. `calcular_preco` lê `catalogo.preco_venda` (mesmo formato de retorno, `regra = planilha`); fórmula antiga em `private.calcular_preco_mercado` para SKU sem preço; `validar_margem` e `montar_opcoes` com lucro bruto mínimo no modo planilha; `lucro_liquido_minimo` 60 -> 65; horário do balcão 08:00. Staging, carga em lotes e relatório. Vitrine `ecommerce_products` (pública, sem SKU, custo nem piso).
- **Carga feita:** 20.381 SKUs com preço da planilha, 0 barrados, 0 custos alterados; 5 SKUs numéricos (planilha "0001", catálogo "1") casados por `private.sku_planilha`. 9 SKUs do catálogo não estão na planilha e seguem a fórmula antiga: CORD20MM, ETIQ-BAG, SQZ-500, CAM-DRY, BONE-AR, CART-A5, CV-LONA100-OP, SOB-CRED-100X148, SOB-CORD-825X20. Vitrine com 20.381 itens, 3.462 produtos e 140 categorias. Token temporário apagado.
- **n8n:** `GBH | FERRAMENTA | montar_orcamento` sem o nó de pesquisa (publicado); `GBH | FERRAMENTA | pesquisar_preco_mercado` despublicado. JSONs em `n8n/` atualizados.
- **CRM:** botão "Importar planilha de preços" em Catálogo > Produtos (confere no navegador, envia e aplica em lotes de 2.000 para caber no limite de 8 s). Textos de preço atualizados.
- **Loja (`ecommerce/`):** Next.js isolado; home, /categorias e /ajuda iniciais com dados reais da vitrine; cabeçalho, rodapé com crédito Bauerlab, botão do WhatsApp por contexto, selos, JSON-LD da empresa, robots e sitemap.
- **Testes:** `npm run typecheck`, `npm test`, `npm run build` e `npm run build:ecommerce` verdes; teste novo do leitor da planilha em `scripts/test-rules.ts`.

### O que NÃO foi feito (honestidade)
- `npm run test:sql` não roda: o executor local falha em funções que só existem em produção (drift anterior a esta etapa). Os testes SQL foram feitos direto em produção com conferência de resultado.
- Prompt da Laura ainda não cita o endereço do balcão (fica para a Fase 5).
- Títulos da vitrine ainda vêm da descrição do catálogo ("Couche Brilho - 300g"); a tradução de balcão completa e a ficha técnica entram na Fase 2. `traduzir_especificacao` chama de "papel fino" itens que não são papel (ex.: chaveiro UV 10g): revisar na Fase 2.
- Condição especial G2 continua calculando a "gordura" pelo piso líquido; em itens de margem apertada ela pode não oferecer desconto. Decidir se passa a usar o piso bruto.

### Como testar
1. CRM > Catálogo > Produtos: o preço de venda de CFV02 deve ser R$ 151,90.
2. Pedir um orçamento de cartão pelo WhatsApp de teste: o valor deve bater com a planilha.
3. `npm run dev:ecommerce` com `ecommerce/.env.local` (chave publicável) e abrir http://localhost:3001.

## Auditoria do relatório de aprimoramento (04/11/2026)

Conferência de cada item do relatório contra o banco de produção, os workflows exportados em `n8n/` e o código. Status: **OK** (verificado), **Parcial** (existe, mas diverge do relatório) e **Pendente** (não existe).

| # | Item | Status | Evidência e observação |
|---|---|---|---|
| 1 | Deadlock do debounce (WF1) | OK | Nó "Separar mensagens do grupo" emite item vazio controlado; `agente_finalizar` é chamada. |
| 1b | Lock com TTL | Parcial | Concorrência por `agente_execucoes` com janela de 3 min. O relatório pede 90 s. Reduzir pode gerar resposta duplicada se a rodada passar de 90 s, então não foi alterado. |
| 2 | Normalização de medidas (WF1) | OK | Regex `(\d+)\s*([×X*]|por)\s*(\d+)` gera `NxM`. |
| 3 | Ingestão contextual de mídia | Parcial | Documento entra no CRM e é transcrito/lido. A separação "referência de orçamento" x "arte pós-pago" está no fluxo de arte (`arte_receber`), não foi confirmada no export do WF1. |
| 4 | Abertura adaptativa (WF2) | OK | Proibida a pergunta genérica quando o cliente já especificou o pedido. |
| 5 | Pergunta-filtro antes das opções (WF2) | OK | Prompt exige a variável-chave (ex.: 4x0 x 4x4) antes de `enviar_foto_produto`. Filtro aplicado no prompt, não na busca. |
| 6 | SDR closer e nichos (WF2) | OK | Captura segmento (barbearia, restaurante/delivery, estética etc.) e orienta o cross-sell. |
| 7 | Cut-off das 10h30 (WF2) | OK | Prompt usa 10h30 em dias úteis. |
| 8 | Medidas técnicas com sangria de 3 mm (WF2) | OK | Prompt exige tamanho refilado e tamanho com sangria. |
| 9 | Regra da casa (WF2) | OK | Fotos de mostruário antes do pagamento; prova digital só depois. |
| 10 | Pix direto na conversa | Pendente | Não há geração de Pix copia e cola no `mp-criar-link` nem na ferramenta `gerar_link_pagamento`. Hoje sai só o link do Checkout Pro. |
| 11 | Realtime em `messages` e `conversations` | OK | Publicação `supabase_realtime` confirmada; front atualiza o cache pelo payload. |
| 12 | Mensagem automática ao assumir conversa | OK | Texto do relatório, enviado pelo `whatsapp-send` só na passagem IA para humano. |
| 13 | `/resetchat` com auditoria | OK | Migration aplicada; grava `reset_chat` com operador em `agent_logs`. |
| 14 | Nota de áudio transcrita | OK | WF1 baixa o áudio (`whatsapp-media`) e transcreve (Groq `whisper-large-v3-turbo`). |
| 15 | Calcular preço só com SKU e quantidade | OK | `calcular_preco(sku, 1, '{}')` retorna `ok` (testado com rollback). |
| 16 | Preço livre (override) no pedido | Parcial | Campo de total do item e preço manual quando a busca falha. O piso duro continua bloqueando, por regra do projeto. Preço livre abaixo do piso exige decisão do dono. |
| 17 | Normalização dos SKUs | OK | Migration `20261109000002_normalizar_skus_catalogo` aplicada em 04/11/2026: 32 SKUs normalizados, 0 colisões, 0 vínculos órfãos, 9 FKs recriadas com o mesmo estado de validação. |
| 18 | Mensagem consolidada em um balão (4.5) | Pendente (decisão) | O fluxo atual divide a resposta em mensagens curtas ("Dividir em mensagens curtas"). O relatório pede um único balão. Mudança de comportamento em produção: precisa de decisão do dono. |
| 19 | Auditoria noturna às 23h30 com Gemini | Pendente | Não existe a tabela `knowledge_audit_logs` nem o job. É construção nova. |

**Decisões do dono (04/11/2026):** preço abaixo do piso continua bloqueado (item 16). Normalização dos SKUs autorizada e aplicada (item 17).

**Pendências do dono:** itens 10 (Pix direto), 18 (mensagem em um balão) e 19 (auditoria noturna).

**Tempo real (04/11/2026):** o log do Supabase mostrou que o streaming do Realtime caía quando o cliente desconectava (celular em segundo plano, PWA) e não voltava sozinho, então a tela parava de receber mensagens até o F5. Correção no `useRealtimeSync`: estado do canal observado com reconexão automática, atualização completa ao voltar para o app (visibilidade, foco e rede) e, como rede de segurança, polling de 8 s nas mensagens da conversa aberta e de 10 s na lista de conversas. O polling pausa com a aba em segundo plano.

## Correções aplicadas direto nos workflows do n8n (produção, 04/11/2026)

Aplicadas no n8n pelo MCP, sem passar por este repositório. Os workflows exportados em `n8n/` ainda não refletem estas mudanças (ver pendências no fim desta seção).

**GBH | WF1 (entrada e debounce)**
- **Deadlock no debounce:** o nó "Separar mensagens do grupo" emite um item vazio controlado quando o array chega zerado. Assim `agente_finalizar` é sempre chamada. Corrige o travamento de 27 minutos sem resposta no WhatsApp.
- **Normalização de medidas:** regex converte variações (`50×50`, `50X50`, `50*50`, `50 por 50`) para o formato canônico `50x50`.
- **Ingestão contextual de mídia:** PDF e imagem deixam de ser tratados como arte pós-pago. Se a conversa está na fase de orçamento, viram modelo ou referência técnica para a dúvida.

**GBH | WF2 (agente de atendimento)**
- **Abertura adaptativa:** proibida a pergunta genérica "O que você precisa produzir hoje?" quando o cliente já chega com pergunta específica (ex.: caso impressão A1). A IA responde a dúvida técnica de imediato.
- **Pergunta-filtro antes das opções:** a IA qualifica as variáveis mestras (ex.: frente ou frente e verso) antes de disparar opções de catálogo com foto, para não enviar opções irrelevantes.
- **SDR closer e nichos:** qualificação ativa por nicho (barbearia, restaurante, estética), gravada no CRM para orientar upsell cirúrgico.
- **Cut-off operacional:** horário limite para produção no mesmo dia ajustado de 12h00 para 10h30.
- **Medidas técnicas obrigatórias:** tamanho final refilado e tamanho da arte com sangria de 3 mm.
- **Regra da casa:** fotos de mostruário físico antes do pagamento. Montagem formal da arte personalizada só depois do pagamento.
- **Checkout ágil Pix:** emissão de Pix direto pelo Mercado Pago na conversa, para pedido de balcão, sem exigir PDF prévio.

**Exportação (resolvido em 04/11/2026):** `n8n/GBH-WF1-Entrada-e-roteamento.json` (61 nós) e `n8n/GBH-WF2-Agente.json` (28 nós) foram reexportados da instância, sem credenciais (o campo `credentials` foi removido de cada nó e não há segredos no arquivo).

## Comando /resetchat (04/11/2026)

- **O que faz:** no chat do CRM, o operador digita `/resetchat` (só no modo resposta). A mensagem não vai ao cliente. O sistema:
  1. Chama a RPC `resetar_contexto_conversa`: grava `conversations.contexto_desde`, limpa `summary` e `collected_data`, devolve a IA (`ai_handled = true`) e grava em `agent_logs` a ação `reset_chat`, com `operador_id` e `operador_nome` de quem executou (só staff).
  2. Envia a saudação inicial pelo `whatsapp-send`.
- **Como o agente "esquece":** `agente_contexto_base` ignora mensagens e orçamentos anteriores a `contexto_desde`. Os pedidos e orçamentos continuam no banco, só saem do contexto.
- **Migration:** `supabase/migrations/20261109000001_resetchat_contexto.sql` (aditiva; recria `agente_contexto_base`).
- **Status:** migration `resetchat_contexto` aplicada em produção em 04/11/2026 (coluna, RPC e grants conferidos). `whatsapp-send` precisa estar na versão atual.

## Pós-liberação (03/11/2026)

- **Laura respondendo ao vivo:** o dono testou de outro WhatsApp e confirmou a resposta.
- **Modelo:** `agente_config.modelo_padrao`, `modelo_forte` e `modelo_resumo` = `gemini-flash-latest`, o mesmo modelo e a mesma credencial (`Google Gemini(PaLM) Api account`) do workflow da Iracema, que já funcionava. Modelo único: o Pro nunca é chamado. Mudança só de configuração no banco. Voltar ao anterior: `update public.agente_config set modelo_padrao='gemini-3-flash-preview', modelo_forte='gemini-3-flash-preview', modelo_resumo='gemini-3-flash-preview' where id=1;`
- **Pesquisa de mercado:** Gráfica Silcor (`www.graficasilcor.com.br`) registrada em `fontes_pesquisa` como prioridade 1 (AlfaCards prioridade 2) e incluída nos nós "Montar buscas" e "Escolher páginas" do workflow `pesquisar_preco_mercado`. robots.txt conferido (libera produto); termos de uso ainda por conferir (`termos_ok` vazio).
- **Conversa em modo humano:** conversas atendidas manualmente (ex.: negociação em andamento) são ignoradas pela IA de propósito (`agente_execucoes.motivo = modo_humano`). Teste sempre com um número sem conversa.
- **Pendência de segurança:** `public.e2e_exportar` é executável por `anon` (exige token); revogar depois do lançamento se o executor de testes não precisar.

- **Limpeza dos pedidos de teste (03/11/2026):** removidos os 148 pedidos dos contatos de teste (`TESTE_...` e `Teste_...`, todos de 02/11, sendo 48 com pagamento simulado) pela rotina `public.e2e_limpar`, que só apaga contatos marcados `is_teste` e o que depende deles (orçamentos, conversas, alertas, filas). Sobraram 7 pedidos reais; um com flag de teste e 2 contatos de teste cujo nome não começa com "teste" ficaram de fora de propósito (pedido do dono foi pelo nome).

## MVP final (03/11/2026): liberação formal pelo dono

Decisão do dono (proprietário), registrada por escrito nesta sessão: liberar o atendimento ao público, ciente de que o relatório do PR #43 (`docs/agente/e2e-relatorio.md`) trazia o ciclo 1 com média 7,7 e condução e recuperação abaixo de 8, e de que o registro das 3 repetições do funil não foi localizado no repositório. Nenhuma bateria de teste nova foi rodada por ordem do dono.

**Migration `20261108000001_mvp_final_orcamento_limites_piso.sql` (aplicada em produção; versão renomeada para vir DEPOIS da `20261107000004`, que reinstalaria a trava de R$ 5.000 em um banco novo):**
- `montar_orcamento`: até 100 pacotes por linha (cabe 500 + 250 + 50); teto de 50.000 unidades no total (`quantidade_irreal`); SKU fora do catálogo continua bloqueado com `sku_nao_encontrado` (agente não informa valor e chama o dono); trava de R$ 5.000 removida; acima de R$ 10.000 o orçamento sai normal e o dono recebe alerta só no WhatsApp (`orcamento_valor_alto`, sem push); sub-lotes do mesmo produto viram uma linha no PDF (`itens_exibicao`, ex.: 800 un., unitário médio, total). Limites em `app_settings.orcamento_agente` (`valor_alerta`, `unidades_max`, `pacotes_max_linha`).
- `calcular_preco`: sem dado de mercado nem histórico, o preço nunca fica abaixo de custo + R$ 1,80 por bloco (`parametros_comerciais.markup_minimo_bloco`); o piso de lucro (R$ 60 por orçamento) e o piso duro continuam valendo.
- Verificado em produção dentro de transação desfeita: 500 + 250 + 50 de sacolas = 1 linha de 800 un., total R$ 16.799,70 e 1 alerta de valor alto; SKU inexistente = `sku_nao_encontrado`; 100 x SAC1OX1000 = `quantidade_irreal`.

**n8n:** `GBH | FERRAMENTA | pesquisar_preco_mercado` publicado só com SearXNG e Playwright (Tavily, Serper, Firecrawl e os seletores de fonte removidos). Fontes prioritárias na lista `PRIORITARIOS` do nó "Escolher páginas" e `SITES` do nó "Montar buscas". **Falta:** o domínio da Gráfica Silcor (não consegui localizá-lo) e a conferência de robots/termos antes de acrescentá-lo também em `public.fontes_pesquisa`. O modelo do WF2 NÃO foi mexido: o dono seleciona e ativa direto no n8n.

**Liberação:** `agente_config.piloto_ativo = false` aplicado depois do merge; a Laura passa a responder qualquer número assim que o modelo do WF2 estiver ativo no n8n. Reverter: `update agente_config set piloto_ativo = true where id = 1;` (o piloto volta a valer só para `piloto_wa_ids`).

## Etapa 8C: clone de teste do WF2, ciclos de correção e pendências do CRM (em andamento, 02/11/2026)
Decisão do dono: NÃO publicar a versão `9621c5c2` do WF2 em produção; testar num clone isolado. Público segue fechado, nada de produção foi publicado, piloto intacto.
- **Clone isolado (publicado só ele e a entrada de teste):** `GBH | TESTE | Agente (clone do WF2)` (`UApV4FFAqpNsATyz`) e `GBH | TESTE | Entrada de teste (clone)` (`zTm85cM0ueX1hUvo`, webhook com caminho secreto). Isolamento provado: o clone só roda com `teste=true` (o nó `Montar prompt` lança erro se não for), a entrada de teste não tem gatilho da Meta nem nó de envio ao WhatsApp (só RPCs do banco e o clone), o despachante simula PDF, foto, link de pagamento e arte quando `teste=true`, só existem contatos `is_teste`, follow-ups de contato de teste são `simular`, e (novo, migration `20261107000001`) `alerta_criar` grava alerta de contato de teste com push e WhatsApp `desligado` (antes o alerta de uma conversa simulada podia chegar ao dono).
- **Executor dentro do banco (migration `20261107000002`):** `e2e_enfileirar`, `e2e_avancar` (pg_cron a cada 10 s + pg_net), `e2e_exportar` (leitura por token, para `tests/e2e/exportar.ts`). Uma rodada de 70 conversas leva uns 20 minutos e custa ~R$ 3. Sem subagentes executores; o juiz continua sendo agente independente.
- **Ciclo 2 (rascunho de prompt do ciclo 1, formulação 1):** zero críticas automáticas, 1 crítica do juiz (prazo "sexta-feira" sem data), média 7,41 (tom 6,84, condução 6,10, exatidão 6,91, honestidade 8,0, sigilo 9,4, personas 8,33, recuperação 6,30). Pior que o ciclo 1 (7,71): o juiz agora vê o estado de preparo e a regra 5 ("peça o número da opção") atrapalhou "pode fechar" e "APROVADO".
- **Ciclo 3 (em execução):** regras reescritas no clone (aprovação, uma pergunta, datas, orçamentos independentes, exceções), `agente_config.historico_mensagens` 6 para 10, contexto com lista de orçamentos abertos (migration `20261107000003`).
- **Achados fora do prompt:** (1) `pesquisar_preco_mercado` falhava no primeiro nó por falta de credencial Supabase (a pesquisa nunca chegou a rodar; corrigido só no rascunho, falta publicar); (2) SearXNG funciona mas está em endereço público sem senha; (3) Silcor tem páginas com `data-variants` (preço por quantidade) e robots liberado: ver `pesquisa-concorrentes.md`; (4) o simulador não grava as mensagens de "opções com foto" no histórico, então cenários de escolha por posição subestimam a nota.

**Etapa 8B (teste ponta a ponta, 02/11/2026): medição feita, liberação NÃO aprovada.** Relatório em `docs/agente/e2e-relatorio.md`, plano de liberação em `e2e-liberacao-gradual.md`, roteiro manual em `e2e-roteiro-manual.md`. Branch `claude/ecstatic-lamport-5ko2nc`.

### Em andamento (passagem de bastão da 8B)
- **Feito:** `tests/e2e/` (70 cenários x 3 formulações, personas, verificações automáticas, juiz independente, executor, `npm run e2e`, `npm run test:e2e` no `npm test`); migrations aditivas `20261106000001` a `04` (flag `contacts.is_teste`, `e2e_mensagens`, funções `e2e_*`, preparo multi-turno em `agente_teste_preparar`, correção do `agente_debounce` que estourava os 8 s do PostgREST e deixava o cliente sem resposta); ciclo 1 (70 conversas, formulação 1) julgado por 5 agentes independentes: média 7,7, condução 6,5, recuperação 6,8, 3 críticas apontadas (1 real, 2 artefato de preparo, já corrigido no juiz); `sql/tecnicos.sql` passa; botão Pausar IA testado (`ignorada:ia_pausada`); dados de teste limpos.
- **Falta:** publicar a versão rascunho `9621c5c2-a21a-41f4-900a-e76ab72c819a` do WF2 (correções de prompt em `e2e-prompt-wf2-ciclo1.md`). A publicação foi negada pelo classificador de permissões e **depende de autorização do dono**. Depois: ciclo 2 (mesmos 70 cenários), formulações 2 e 3, e duas rodadas completas seguidas aprovadas (zero críticas, média 9 ou mais, nenhum critério abaixo de 8). Também: atualizar critérios antigos de `testes_conversa` (`e5-04`, `e5-07`, `e5-21`, `e8-fluxo-1/2`), rodar concorrência de 20 conversas e o reinício do n8n.
- **Arquivos tocados:** `tests/e2e/*`, `supabase/migrations/20261106*`, `docs/agente/e2e-*.md`, `.gitignore`, `package.json`. No n8n: só o rascunho do WF2 (nó `Agente de atendimento`, `options.systemMessage`, itens 6 a 15), sem publicar.
- **Nada foi ativado.** Estado de produção confirmado: workflows publicados, `ia_ligada = true`, mas `piloto_ativo = true`, percentual 0, um número no piloto.

**Próximo passo: Etapa 8 (auditoria e ativação).** Roteiro completo e autorização do dono em `docs/agente/etapa8-roteiro-auditoria.md`. Tudo deve ser resolvido via MCP, sem ação do dono.

## Layout consolidado do orçamento em PDF (branch `claude/brave-cori-2xq21w`)

Migration `20261106000001_orcamento_exibicao_consolidada.sql` (aditiva): `orcamentos.itens_exibicao` e `orcamentos.alternativas`, usados por `orcamento_documento`; modelo `_shared/orcamento-html.ts` ganhou o quadro de alternativas e a nota de arredondamento; testes em `scripts/test-orcamento.ts`. **Falta (depende do dono):** aplicar a migration, publicar `orcamento-pdf` (bundle em `docs/agente/funcoes/`) e preencher os dois campos no orçamento SG-0234. Detalhes em `docs/orcamento-pdf.md`.

## Conversa completa como no WhatsApp (branch `claude/brave-cori-2xq21w`)

Migration `20261106000003_mensagens_whatsapp_completo.sql` (aditiva): `messages` ganhou `reply_to_wa_id`, `raw_type`, `meta`, `forwarded`, `sent_by`, `deleted_at`, `deleted_by` e os tipos `video`, `sticker`, `location`, `contacts`, `reaction`. O webhook passa a guardar todos os tipos (o que a Meta não repassa, como mídia de visualização única e enquete, aparece com aviso claro em vez de "[mensagem não suportada]" solto). `whatsapp-send` aceita imagem, vídeo, áudio, figurinha e documento (até 16 MB), resposta a uma mensagem, reação e apagar/restaurar no CRM. Tela: citação da mensagem respondida, reações, menu da mensagem (responder, reagir, copiar, dados, apagar no CRM), arrastar e soltar, colar imagem e gravar áudio. **Limites da API oficial:** não apaga nem edita mensagem já entregue ao cliente (apagar só esconde no CRM) e a gravação de áudio depende de o navegador gravar OGG ou M4A.

## Etapa 7C: banco de conhecimento v2, personas e fila da arte (branch `feat/agente-etapa7c-conhecimento`)

**Concluída (aguarda a Etapa 8) (02/11/2026).** Detalhes: `docs/agente/conhecimento-diferencas.md`, `conhecimento-testes.md`, `docs/agente-ia.md`.

**Aplicado em produção pelo MCP do Supabase (02/11/2026):** partes 1, 2 e 3 (`etapa7c_estrutura`, `etapa7c_importacao`, `etapa7c_personas_arte`). Os 83 trechos estão ativos: a regra de proteção tratou 50 como editados (todos os antigos tinham `revisado_em` posterior à criação), então foram aceitos depois comparando o conteúdo atual com o original da carga (iguais, ou seja, sem edição do dono). 0 sugestões pendentes, 113 trechos ativos. Teste de 40 perguntas em produção (texto): 40 de 40. Vetores dos 50 últimos entram pela reindexação automática (5 em 5 minutos).
**Edge Functions publicadas:** `orcamento-pdf` (v12), `mp-criar-link` (v17) e `cliente-pago-avisar` (v2), todas com `verify_jwt` desligado. Código publicado = bundles de `docs/agente/funcoes/` sem as funções não usadas.
**n8n (tudo DESATIVADO):** WF2 usa `persona.nome` e `fase` do contexto, prompt com apresentação, regra de reembolso e uso de `arte_receber` e `arte_baixa_ok`, com as duas ferramentas ligadas; o despachante chama `public.arte_receber` e `public.arte_baixa_ok` direto (HTTP com a credencial de serviço; confira a credencial nos dois nós novos). `encaminhar_setor` não existe no n8n: o prompt manda chamar o dono por `chamar_dono`.

### O que foi feito
- 83 trechos importados com equivalência, proteção do que o dono editou, sugestões e reversão.
- Variáveis novas resolvidas na hora: `persona_vendas`, `persona_pos_pagamento`, `cupom_percentual`, `cupom_teto`, `cupom_validade_dias`, `troca_prazo`.
- Configurações > Personas e política (nomes, automático pós-pagamento, política, parcelamento, setor de arte, cupom).
- Personas: `agente_persona`, fase decidida pelo pedido; o agente não para mais depois do pagamento (chave `personas.pos_pagamento_automatico`); para só em setor de arte ou dono.
- Setor de arte: `arte_receber`, `arte_baixa_ok`, `arte_aprovar`, `arte_fila`, `arte_varredura` (a cada 15 min), tela Fila da arte, alerta ao dono com resumo.
- Aba Conhecimento: usos, última vez, filtros (categoria, revisar, uso), ordenar, perguntas sem resposta com "criar trecho", sugestões da importação.
- Política no rodapé do PDF e na descrição do link; link mostra até 12 parcelas (2x sem juros, o resto com juros do cliente).
- Cupom de recompra: teto R$ 25, não acumula com condição especial, uso único; se não couber vira arte básica grátis (continua DESLIGADO até a simulação).
- Trava de saída: endereço liberado depois do pagamento; barra "vou te reembolsar" e variações.

### O que falta (honestidade)
1. Vetores: conferir `select count(*) filter (where embedding is null) from conhecimento where ativo;` = 0 (reindexação automática).
2. n8n: WF1 não precisou mudar (repassa `contexto` com `persona`); falta teste de conversa com o modelo real antes da Etapa 8.
3. Parcelas no Mercado Pago: dono confirmou que 2x sem juros já está ligado na conta; o link mostra até 12x.
4. Cupom de recompra: continua pela lógica própria da 7B com as mesmas travas (piso, gordura, `validar_margem`), não por `calcular_condicao_especial` literalmente.
5. Aviso ao cliente na aprovação da arte: feito pela tela Fila da arte (texto livre via `whatsapp-send`, só dentro da janela de 24 h; se fechada, a tela avisa o dono).
6. Decididos pelo dono: 2x sem juros já ligado no Mercado Pago; telefone da BauerLab (+55 31 99802-1169) confirmado e a indicação NÃO alerta mais o dono.


## Pendências para a auditoria (Etapa 8), herdadas da 7B

Registradas em 01/11/2026. As funções do Mercado Pago (`mp-webhook`, `mp-conferir`, `mp-criar-link`) já foram publicadas pelo dono. A proteção contra senhas vazadas não se aplica ao plano gratuito do Supabase (risco baixo: cadastro público desativado).

**n8n (ligação e ativação)**
- Ligar ao WF2 e ao despachante as ferramentas novas: `encaminhar_setor`, `bauerlab`, `montar_opcoes` e escolha de opção; passar os campos novos de `salvar_contato` (empresa, e-mail, documento, endereço, nota fiscal, consentimento, urgência).
- Aplicar o ajuste de tom no prompt do WF2 (`docs/agente/tom-e-vendas.md`).
- WF6 consultar `recuperacao_proximo_passo`; WF7 chamar `cupom_recompra_emitir`.
- Publicar o WF9 e ligá-lo a todos os workflows `GBH |`.
- Conferir credenciais nó a nó nos 26 workflows (`docs/credenciais-n8n.md`).
- Teste de conversa que tente arrancar cada promessa indevida (pagamento, arte, produção, conclusão, data, desconto, reembolso).

**Produto**
- Painel Comercial no front (usa `painel_comercial`), workflow `GBH | WF11 | Estudo diário`, recompra por comportamento (D2).
- PDF de uma página com as 3 opções de orçamento.
- Segundo link só de Pix e indicador "digitando" do agente.

**Infra e terceiros**
- SearXNG no Coolify (`docs/infra-coolify.md`) e teste de ponta a ponta com 5 especificações.
- Bloco C: fórmula ou tabela por m² do fornecedor e pontos de preço para os itens por dimensão (`docs/agente/preco-por-dimensao.md`).
- Bloco E: Análise de app da Meta antes do `GBH | WF10` (`docs/redes-sociais.md`).

**Decisões do dono**
- Taxa real do 2x sem juros (hoje 10,50% estimado), política de troca e reembolso, parcelamento acima de 2x, benefício de indicações, telefone da BauerLab, ligar ou não o cupom de recompra (após `cupom_recompra_simular`), apagar `private.bkp_products_etapa2`.

## Etapa 7B: melhorias consolidadas (blocos A, B, C a F entregues; ver pendências)

Decisões e inventário em `docs/agente/decisoes-e-melhorias.md`. Uma branch de trabalho (`claude/compassionate-ramanujan-s26vog`) com um PR por bloco.

### Bloco A: proteger a operação (concluído, 01/11/2026)
**Aplicado em produção pelo MCP do Supabase** (migrations `20261103000001` em 3 partes e `20261103000002`; cópias em `docs/agente/aplicar-etapa7b-a.sql` e `aplicar-etapa7b-a2.sql`). Advisors sem achado novo grave.

| # | Item | Resultado |
|---|---|---|
| A1 | Taxas por método | `taxas_pagamento` ganhou crédito 2x sem juros (10,50% **estimativa conservadora**, confirmar no Mercado Pago), débito, dinheiro e transferência. O piso usa a pior taxa (`metodo_piso = cartao_credito_2x`). Taxa real (`fee_details`, líquido, parcelas) gravada no pedido por `pagamento_taxa_real` (código em `mppay.ts`, **função ainda por publicar**) |
| A2 | Taxa por dentro | Já era "por dentro" (`receita_para_lucro`). Orçamento ignora método previsto (trava na pior taxa). Tabela interna de taxa e lucro por método em Pedido > Orçamentos (só o dono) |
| A3 | Link alinhado | `installments: 2` e boleto/lotérica excluídos em `_shared/mp.ts` (**publicar mp-criar-link**). Documentado em `docs/pagamento-mercadopago.md`. Pix direto: avaliado, adiado |
| A4 | Pedido manual | Método obrigatório (criar pedido, confirmar pagamento). `confirmar_pagamento_manual` recusa sem método. Taxa só do método escolhido; dinheiro e transferência 0%. Pedidos 18 e 19 de produção (pendentes, sem método) ficam com a taxa de pior caso: **nenhuma correção necessária** (não havia pedido manual pago com taxa indevida) |
| A5 | Exclusão | `pedido_excluir` (lógica com motivo e auditoria; teste some por completo; pago nunca apaga), `pedido_cancelar_ou_arquivar` (reembolso pendente + alerta alto). Tela: Pedido > Resumo > Zona de risco. Pago após exclusão restaura o pedido e alerta |
| A6 | Atraso e urgência | `pedido_esta_atrasado`/`pedidos_atrasados` (só em produção, regra única também em `pedidoAtrasado` no front). Selo URGENTE em cartão e lista, ordena a fila, `registrar_urgencia` não muda prazo |
| A7 | Trava de lucro | `supabase/tests/trava_lucro_caminhos.sql` (preço, orçamento, condição especial, link, pedido manual, importação) + simulação em massa da Etapa 3 (`npm run test:sql`); `test-rules.ts` confere que cada caminho está coberto |
| A8 | Sigilo do fornecedor | Detector com variações de grafia, mais extensões, e varredura dos textos gravados no banco |
| A9 | Credenciais do n8n | `docs/credenciais-n8n.md`. A credencial real é `Supabase account`; "GBH Supabase (service role)" nunca existiu |
| A10 | WF9 | Tipos de erro, ação por tipo (repetir, registrar, interromper e alertar), divergência de pagamento a cada hora, simulação testada. **Ligar o WF9 aos outros workflows exige publicá-lo (ativar), então fica para a Etapa 8** |
| A11 | Segurança | Senhas vazadas continua desligada (ação do dono). Backup `private.bkp_products_etapa2`: 20.381 linhas idênticas ao catálogo, sem dependências, 3,6 MB. Comando de remoção em `depende-de-voce.md` |
| A12 | Prazo | Uma só implementação (`private.prazo_data`), usada por pedido, orçamento e `calcular_prazo`; teste de igualdade |

Testes: `npm test` e `supabase/tests/*.sql` (melhorias 71, trava 12, preço 67, orçamento 56, regressão das Etapas 1 a 7 verde).

### Bloco B: agente, conversa e conversão (concluído no banco, 01/11/2026)
**Aplicado em produção** (migrations `20261103000003` a `20261103000005`, cópias em `aplicar-etapa7b-b.sql` e `-b2.sql`). Testes: `supabase/tests/melhorias_bloco_b.sql` (58). Tom e pesquisa web em `docs/agente/tom-e-vendas.md`.

| # | Item | Resultado |
|---|---|---|
| B1 | Debounce 10 s | `agente_config.debounce_segundos = 10`. `agente_debounce` espera até 20 s a mais (teto de 60 s) se a última mensagem parece incompleta; pergunta completa responde já. **A API oficial não avisa quando o cliente digita**: documentado |
| B2 | Tom humano | `docs/agente/tom-e-vendas.md` + trecho `tom-vendedor` no conhecimento. **O prompt do WF2 não foi alterado** (ver pendências) |
| B3 | Dados e CRM | `agente_salvar_contato` aceita empresa, e-mail, documento e endereço (só com nota fiscal ou entrega), devolve `falta`, consentimento de promoções em pergunta separada (data e origem `whatsapp`, nunca reverte `opted_out`), urgência |
| B4 | Pix primeiro, parcelamento | Conhecimento atualizado (`pag-formas`, `pag-pix`, `pag-parcelar`, `pag-nf`, `troca-politica` com `[CONFIRMAR]`) |
| B5 | Três opções | `montar_opcoes` (até 3 do mesmo grupo, margem validada no pior caso, diferenças reais), `orcamento_opcao_escolher`, view `opcoes_conversao`. **PDF de uma página com as 3 opções: não feito** |
| B6 | Setores | `conversations/tasks/alertas.setor`, `agente_encaminhar_setor` (comercial, arte, financeiro com resposta do sistema, dono com resumo, histórico, motivo e ação recomendada) |
| B7 | Promessas indevidas | `agente_promessas_indevidas` dentro de `agente_saida_segura`: pagamento, arte aprovada, produção, conclusão, data não dada, desconto fora da função e reembolso; 12 testes |
| B8 | Google e cupom | Avaliação sem benefício (trecho `google-avaliacao`). Cupom de recompra 5% incondicional **desligado**, com `cupom_recompra_simular`; não ligue antes de ver a simulação |
| B9 | Motivo da perda | `orcamentos.motivo_perda`, `estrategia_recuperacao` (condição especial sempre por último), `recuperacao_proximo_passo` (respeita optout). **WF6 ainda não consulta a função** |
| B10 | BauerLab | `agente_bauerlab` (uma vez, alerta baixo), `oportunidades_bauerlab`, config em `app_settings.bauerlab` (telefone **a confirmar por você**) |
| B11 | Validador | `pedido_pendencias` (cliente, itens, SKU, preço aprovado, pagamento, prazo, arte) |

**Ligação ao n8n (PARCIAL, honestidade):** as funções do banco estão prontas e testadas, mas o WF2 ainda não expõe ao modelo as ferramentas novas (`encaminhar_setor`, `bauerlab`, `montar_opcoes`, escolha de opção) nem os campos novos de `salvar_contato`, e o WF6/WF7 não chamam `recuperacao_proximo_passo` nem `cupom_recompra_emitir`. A trava de promessas, o debounce e o conhecimento já valem sem mudar o n8n. Editar o WF2 (26 nós) e o despachante fica para a Etapa 7C/8, com teste de conversa.

### Blocos C a F (01/11/2026): estrutura pronta, partes que dependem de você ou de terceiros ficam registradas
**Aplicado em produção** (migration `20261103000006`, cópia em `aplicar-etapa7b-cd.sql`). Testes: `supabase/tests/melhorias_bloco_cd.sql` (21).

- **C (preço por dimensão):** `catalogo_formulas` e `private.custo_por_dimensao` (só com fórmula validada, erro até 1%; sem ela não há oferta definitiva). Não consegui investigar o fornecedor (precisa do seu login e dos termos de uso). Passo a passo em `docs/agente/preco-por-dimensao.md`. O workflow de consulta automatizada **não foi criado** de propósito.
- **D (inteligência):** `painel_comercial` (cinco grupos de indicadores), `atribuicao_pedidos`, `rentabilidade_cliente` (só o dono), `produtos_complementares` + `complementar_sugerir`, `melhorias_sugeridas` (alvo crítico exige autorização, garantido por constraint) + `estudo_diario_coletar`, `experimentos` (só texto e momento; amostra pequena nunca declara vencedor), indicações (`indicacao_codigo`, `indicacao_registrar`, compra válida automática, **sem recompensa**). Definições em `docs/metricas.md`. **Faltam:** o painel Comercial no front, o `GBH | WF11 | Estudo diário` no n8n e a recompra por comportamento (D2), que continuam no backlog.
- **E (redes sociais):** Postiz lista Facebook, Instagram e Threads, mas só publica. Webhook de comentário exige Análise de app da Meta: `GBH | WF10` não foi implementado; roteiro em `docs/redes-sociais.md` e `docs/backlog.md`.
- **F (infra):** a VPS não aceita o gerenciador de Docker da Hostinger (Docker é do Coolify), então não instalei o SearXNG. Passo a passo em `docs/infra-coolify.md`. O teste de ponta a ponta com 5 especificações ficou pendente.

## Etapas concluídas

- Etapa 1: Fundação (PR mesclado, aplicada em produção).
- Etapa 2: **concluída** (PR #22 mesclado, aplicada em produção em 28/10/2026).
- Etapa 3: **concluída** (PR #24 mesclado, aplicada em produção em 28/10/2026).
- Etapa 4: **concluída e testada em produção** (29/10/2026). Banco (migrations 09 a 12), função `orcamento-pdf` e `mp-criar-link` publicadas pelo painel, Gotenberg no ar. PDF SG-0033 enviado e recebido no WhatsApp com o nome `Orcamento-SG-0033-29-10-2026.pdf`; segundo envio devolveu `ja_enviado` (sem mensagem duplicada). Pendente só para a auditoria final: botão Reenviar do CRM (ver abaixo).

- Etapa 4B: **concluída** (fotos de produto, aplicada em produção em 01/11/2026).
- Etapa 6: **concluída** (alertas, PWA e pós-pagamento, aplicada em produção em 01/11/2026; falta o teste no seu iPhone).
- Etapa 7: **concluída** (01/11/2026): banco e função publicados, workflows criados e desativados; falta a ativação (Etapa 8) e a ligação do WF9.
- Etapa 5: **concluída e validada** (agente WF1 e WF2, 01/11/2026). Migrations 01 a 03 aplicadas em produção; **21 de 21 cenários passam** com o modelo real; workflows desativados; funções Edge ainda por publicar (ver `depende-de-voce.md`).

## Etapa 7: follow-ups, pós-venda, status do pedido, painel de pedidos e observabilidade (concluída, 01/11/2026)

Branch da sessão `claude/magical-tesla-auylwy` (a pedida era `feat/agente-etapa7-followup-status`). Detalhes e decisões em `docs/agente-ia.md` (seção Etapa 7).

### O que foi feito e já está em produção
- **Banco** (migration `20261102000001`, aplicada em 3 partes pelo MCP; cópia em `docs/agente/aplicar-etapa7.sql`): `pedido_avisos`, colunas novas, 18 funções (`followup_*`, `pedido_*`, `recompra_*`, `fornecedor_*`, `agente_erro_registrar`, `observabilidade_checar`, `painel_agente`), gatilhos de subestatus e de entrega. Advisors de segurança sem achados novos graves (as funções novas seguem o padrão "executável por logado, conferem o dono por dentro"; as do n8n são só da service role).
- **Edge Function** `proativo-enviar` publicada (versão 1, só service role).
- **n8n** (pasta Sua Gráfica BH, tag `gbh`, desativados, exportados em `n8n/`): `GBH | WF6 | Follow-ups` (`ueCyozWur9Y5gs9c`), `GBH | WF7 | Pós-venda e recompra` (`OBHE31bWohDs2fQ4`), `GBH | WF8 | Status do pedido` (`h6Lviy09RV1coW6v`), `GBH | WF9 | Erros e observabilidade` (`vmaMVnZydmHpkW57`) e `GBH | FERRAMENTA | enviar_proativo` (`gZsE7enJOnpex8xv`). WF6, WF7 e WF8 foram executados uma vez em modo manual contra o banco de produção (fila vazia): credenciais e chamadas OK.
- **CRM**: página Pedidos, subestatus e avisos no cartão e no detalhe do pedido, Configurações > Follow-ups, Painel > Agente.
- **Testes**: `supabase/tests/followup_etapa7.sql` (**96 passam**) com cadência completa com e sem condição, janela aberta e fechada, `optout`, caçador, condição expirada, pagamento no meio, modo humano, IA pausada, horário, limite diário, falhas e tentativas, pós-venda, recompra, avisos de status, lista do fornecedor e observabilidade; regressão das Etapas 1, 3, 4, 5 e 6 verde; `npm test` (inclui `test:proativo`), typecheck e build verdes.

### O que NÃO foi feito (honestidade)
- **WF9 não está ligado aos outros workflows**: o n8n exige o fluxo de erro publicado e a regra é não ativar nada antes da Etapa 8. Fica para a ativação (publicar o WF9 e ligar nos 27 workflows `GBH |`).
- **Nenhum envio real** foi feito à Meta (nem a ninguém): a IA está desligada em produção e a lógica foi testada em SQL; `proativo-enviar` não foi executada contra a Meta (sem Deno aqui). Os templates 4 a 11 ainda precisam estar aprovados na Meta (a função recusa template não aprovado e tenta de novo).
- As telas novas passaram em typecheck e build, mas não foram conferidas no navegador com dados reais (ainda não há pedidos em Produção nem entregues).
- `whatsapp-webhook` com as novas palavras de descadastro ("não quero mais", "pare"): **foi republicado em 01/11/2026 (versão 29)**.
- Custos de template do painel são estimativas.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/followup_etapa7.sql supabase/tests/agente_etapa5.sql supabase/tests/alertas_etapa6.sql
```
No CRM: Pedidos, Painel > Agente, Configurações > Follow-ups; em um pedido pago em Produção, os botões Pronto, Saiu e Entregue.

## Etapa 6: alertas ao dono, PWA e confirmação de pagamento (concluída, 01/11/2026)

Branch `feat/agente-etapa6-alertas-pwa`. Detalhes e passo a passo do iPhone em `docs/pwa-e-notificacoes.md`.

### O que foi feito
- **Passo 0:** o CRM não tinha manifest, service worker nem push; `alertas` existia só como tabela e `chamar_dono` era um stub; "Marcar como pago" e o webhook já passavam por `private.confirmar_pagamento` (um só caminho) e gravavam `pagamento_confirmado`. Estendi tudo isso, sem recriar o pagamento.
- **Aplicado em produção (autorizado pelo dono):** migration `20261101000004` em 6 partes (`etapa6_alertas_push_parte1` a `5` e `etapa6_bloqueio_numero_do_dono`; o arquivo do repositório é a mesma coisa em um só), Edge Functions `alertas-enviar` e `cliente-pago-avisar` publicadas pelo conector (versão enxuta, sem comentários; o código completo está em `supabase/functions/` e em `docs/agente/funcoes/*.bundle.ts`). Advisors de segurança sem achados novos.
- **n8n (MCP, desativados, tag gbh, pasta Sua Gráfica BH):** `GBH | WF5 | Pagamento e alertas` (`rLER5HoORdxVy0S0`) e `chamar_dono` real (`TwvgUc15htbWkyDu`). Exportados em `n8n/`.
- **Testes:** 48 casos SQL novos (`alertas_etapa6.sql`), regressão das Etapas 1, 4 e 5 verde (54, 55 e 101), `npm test`, typecheck e build verdes.

### Decisões
- Fila única `alertas` com status por canal; gravidade baixa fica `agrupado` e sai no resumo de 2 h; "nova mensagem em modo humano" é só popup por padrão (WhatsApp ligável).
- Chaves VAPID: segredos de ambiente, ou geradas pela função e guardadas em `app_segredos` (assim você não precisa configurar nada).
- O agente nunca responde o número do dono (`numero_do_dono`), para o dono poder responder os alertas sem virar "cliente".
- WF5 por fila a cada minuto, com Database Webhook opcional para aviso imediato.

### O que NÃO foi feito (honestidade)
- **Teste real no iPhone:** não tenho o aparelho. Falta você instalar o PWA, ativar e tocar em "Enviar notificação de teste" (passo a passo no doc). O envio Web Push e o WhatsApp reais não foram executados daqui (sem Deno e sem acesso ao aparelho); a lógica foi testada em Node e em SQL e as funções estão publicadas.
- A simulação de pedido pago e do `chamar_dono` de ponta a ponta contra o WhatsApp só acontece com os workflows ativos (Etapa 8). Os 48 testes SQL cobrem o banco inteiro dessas duas rotas.
- Não existe `GBH | WF9 | Erros` na instância; os workflows novos não têm fluxo de erro global ainda.

### Pendências (dono)
1. Instalar no iPhone e fazer o teste (doc). 2. Opcional: Database Webhook para aviso imediato. 3. Ativação dos workflows só na Etapa 8.

## Etapa 5: o agente de atendimento (pronta para revisão, 01/11/2026)

Branch de trabalho da sessão `claude/admiring-einstein-apt8ei` (a pedida era `feat/agente-etapa5-agente`). **Atualização:** migration aplicada em produção em 01/11/2026 (autorizada). Funções Edge ainda não publicadas, workflows desativados. Detalhes em `docs/agente-ia.md` (seção Etapa 5) e testes em `docs/agente/etapa5-testes.md`.

### O que foi feito
- **Passo 0:** o receptor da Meta (`whatsapp-webhook`) já gravava a mensagem de forma atômica e idempotente; conversa nova nasce em modo humano; origem do anúncio já ficava em contato e conversa. Não criei outro webhook na Meta: o receptor passou a avisar o n8n com o id da mensagem.
- **Banco** (migration `20261101000001`, cópia em `docs/agente/aplicar-etapa5.sql`): `agente_execucoes` e 23 funções `agente_*` (ignorar sem chamar o modelo, debounce, trava por conversa, contexto enxuto, trava de saída, loop de ferramentas, tetos de tokens com alerta, primeiro contato, follow-up, modo de teste com avaliação automática) e 21 cenários.
- **Edge Functions:** `agente-enviar` (nova), `whatsapp-webhook` (gancho para o WF1) e `whatsapp-media` (aceita service role). Bundles em `docs/agente/funcoes/`.
- **n8n (MCP, desativados, tag gbh, pasta Sua Gráfica BH):** `GBH | WF1 | Entrada e roteamento`, `GBH | WF2 | Agente` (AI Agent Gemini com 11 ferramentas), `GBH | FERRAMENTA | despachar` e 6 ferramentas novas. Ver `docs/n8n-mapa.md`.
- **Testes:** 96 testes SQL passam, regressão das etapas 1 a 4B passa, `npm run test:agente` passa, e o despachante, o WF1 e o WF2 foram testados no n8n com os nós de rede fixados.

### Decisões
- **Despachante único** (`GBH | FERRAMENTA | despachar`): as 11 ferramentas continuam sub-workflows `GBH | FERRAMENTA | nome`, mas o WF2 as chama por um ponto só, que aplica loop, limpeza de custo e SKU, registro, aviso ao dono na falha e a conversa e o contato fixos (o modelo nunca escolhe).
- **Trava de saída em SQL** (`agente_saida_segura`): testável e única. Bloqueia vazamento e qualquer R$ que nenhuma ferramenta devolveu.
- **Tokens e custo são estimativas** (o n8n não expõe o uso real do Gemini): caracteres ÷ 3,5, marcado como estimativa no log.
- **Transcrição de áudio com Groq `whisper-large-v3-turbo`**, a opção mais barata já disponível na instância (cerca de R$ 0,002 por áudio de 1 minuto).
- **A IA assume o primeiro contato** de conversa nova (o CRM nasce em modo humano) e retoma quando o cliente responde um follow-up.
- Sem validação real do token do webhook (limitação do n8n sem variáveis de ambiente); a URL do webhook é longa e imprevisível e a rodada é idempotente. Ver `docs/n8n-mapa.md` para endurecer.
- `data_atual` (opcional) não foi criada: data e hora vão no prompt.

### O que NÃO foi feito (honestidade)
- **Os 21 cenários rodaram com o modelo real e passam** (relatório e custo médio em `etapa5-testes.md`). Para isso os 13 sub-workflows foram publicados só durante o teste (o `toolWorkflow` do n8n exige o sub-workflow publicado) e despublicados no fim. Na Etapa 8 será preciso publicar o despachante e as ferramentas junto com WF1 e WF2.
- Modelos: `gemini-3-flash-preview` (padrão) e `gemini-3.1-pro-preview` (forte); `gemini-2.5-flash` e `gemini-3-pro-preview` dão 404 na conta.
- A trava de saída não confere fatos numéricos soltos (ex.: "a partir de 100 unidades"), só R$ e vazamentos.
- Áudio (download e Groq), `agente-enviar` e o gancho do webhook não foram executados contra a Meta (sem Deno aqui; lógica testada em Node e SQL).
- Os JSONs dos 9 workflows desta etapa (WF1, WF2, despachante e 6 ferramentas) **não foram exportados para `n8n/`**: o retorno do MCP chega a mais de 100 KB e retranscrever à mão arrisca corromper o fluxo. Eles estão salvos no n8n (versionados) com os IDs de `docs/n8n-mapa.md`. Para exportar: n8n > workflow > Download, ou pedir a exportação em uma sessão com acesso à API do n8n.
- Edge Functions `agente-enviar`, `whatsapp-media` e `whatsapp-webhook` (com o gancho do agente) **publicadas**. Os segredos `N8N_WF1_URL` e `N8N_WF1_TOKEN` ficam para a Etapa 8: sem eles o webhook se comporta como antes.
- O prompt tem cerca de 890 tokens fixos (alvo de 700).

### Pendências (dono)
Ver `docs/agente/depende-de-voce.md`, seção Etapa 5.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/agente_etapa5.sql
```
Depois de aplicar: cenários de `docs/agente/etapa5-testes.md`.

## Etapa 4B: fotos de produto (pronta para revisão, 01/11/2026)

Branch de trabalho da sessão `claude/fervent-hawking-h6vgqf` (a pedida era `feat/agente-etapa4b-fotos`). Nada aplicado no Supabase, nenhuma função publicada, nenhum workflow ativado. Detalhes em `docs/fotos-de-produto.md`.

### O que foi feito
- **Passo 0:** o CRM não guardava imagens de produto. A origem (site público de terceiros, interna) tem `robots.txt` liberado e não tem página de termos de uso; páginas de categoria com 36 cartões, link terminando no SKU e imagem de até 1000 px.
- **Banco** (migrations `20261030000001` e `…02`, juntas em `docs/agente/aplicar-etapa4b.sql`): `produto_fotos`, `produto_fotos_grupos`, `produto_fotos_envios`, bucket privado `produto-fotos`, `app_settings.fotos`, 10 funções em `public` (a service role não alcança `private`), trecho de conhecimento `foto-produto`.
- **Edge Function `produto-fotos`** (bundle em `docs/agente/funcoes/`): busca na origem (1 req/s, 15 s, User-Agent identificável), reduz a 1000 px, JPEG sem metadados (meta 150 KB, teto 300 KB, descarta menor que 300 px), verificação de marca com modelo de visão (falha fechada), envio de imagem no WhatsApp, limites (3 por pedido, 1 pedido por minuto por conversa, 10 imagens por contato por dia), alerta de gravidade baixa quando não há foto, log sem origem.
- **CRM:** Catálogo > Fotos (aprovar, bloquear, trocar, buscar de novo, filtros "Para revisar" e "Sem foto", campo interno da origem, chave do aquecimento).
- **n8n (MCP, desativados, tag gbh, exportados em `n8n/`):** `enviar_foto_produto` (`ybnd6LjGjUO8dgTI`) e `Aquecer fotos de madrugada` (`MYEmz3rCIfhMhxxF`, opcional, desligado).
- **Testes:** `scripts/test-fotos.ts` (entra no `npm test`), `supabase/tests/fotos_etapa4b.sql` (**25 passam**), Etapas 1 a 4 contra o schema novo (54, 82, 67 e 55 passam), `npm test`, typecheck e build verdes. Teste real com 15 grupos: ver abaixo.

### Ajuste pedido pelo dono (01/11/2026): todo produto precisa de foto
- Varredura de todo o menu da origem (152 categorias): 26.639 itens, 18.808 códigos. Os 125 grupos do catálogo têm categoria equivalente (100% por grupo); por SKU, cerca de 90% com imagem própria (estimativa; o cruzamento exato sai na tela de Cobertura).
- Fotos pequenas (miniaturas) agora são aceitas, ampliadas e marcadas como baixa qualidade; o agente nunca diz ao cliente que não há foto.
- Migration `20261030000003` (mapa código -> imagem, candidatas, cobertura), ação `varrer` na função, botão "Mapear origem" na tela, `scripts/fotos-mapear-origem.ts` e `scripts/fotos-catalogo-pdf.ts` (reserva pelo PDF, 1.051 imagens extraídas no teste).
- 38 testes SQL de fotos passam.
- **Aplicado em produção em 01/11/2026 (autorizado pelo dono):** migrations da 4B (aplicadas pelo dono), função `produto-fotos` publicada pelo conector (versão 2; o pacote npm do `imagescript` não roda no Supabase, a função usa a versão Deno `deno.land/x/imagescript@1.3.0`), `app_settings.fotos.origem_base` preenchido, workflow `GBH | WF4 | Mapear fotos da origem` (`iLpTZUm9VLqNLXX1`) executado manualmente no n8n para gravar o mapa. Workflows seguem desativados.

### Decisões
- Domínio da origem fora do repositório: o `npm test` proíbe o nome do fornecedor em qualquer arquivo e o domínio contém esse nome. Fica em `app_settings.fotos.origem_base` (preenchido pelo dono) e o teste real recebe por variável de ambiente.
- Processamento na Edge Function (não no nó de imagem do n8n) para servir agente, tela e aquecimento com o mesmo código testado.
- Imagem sem verificação de marca fica pendente e nunca é enviada (falha fechada).

### O que NÃO foi feito (honestidade)
- A Edge Function não foi executada (sem Deno aqui), nem testada contra a Meta, o Storage real ou o modelo de visão; só a lógica pura e o processamento de imagem foram testados em Node com imagens reais.
- Os workflows foram validados, não executados (gatilho "Execute Workflow" não roda pelo MCP).
- Envio real de imagem e verificação de marca ficam para a auditoria da Etapa 8.

### Pendências (dono)
Ver `docs/agente/depende-de-voce.md`, seção Etapa 4B.

## Etapa 4: orçamento em PDF (concluída, aplicada em produção em 29/10/2026)

Branch `feat/agente-etapa4-orcamento`. Aplicado: migrations `…09` e `…10`, função `orcamento-pdf` (pelo painel, com o arquivo `docs/agente/funcoes/orcamento-pdf.bundle.ts`) e Gotenberg em `gotenberg.bauerlab.com.br`. Nenhum workflow do n8n foi ativado. Ajustes pedidos pelo dono no teste: página mais bem preenchida (passos "Como fechar seu pedido") e nome do arquivo `Orcamento-SG-0032-29-10-2026.pdf`. Detalhes em `docs/orcamento-pdf.md`.

### O que foi feito
- **Passo 0:** o CRM já tinha `orcamentos` e `orcamento_itens` (Etapa 1) e nenhum gerador de PDF de orçamento (só leitura de PDF do catálogo). Estendi as tabelas e unifiquei tudo no padrão novo. O trabalho da sessão interrompida nessa branch (migration com número repetido, funções sem autenticação que aceitavam piso e custo do chamador, provedor de pagamento genérico) foi **substituído**: removi os arquivos e arquivei no n8n os 4 workflows antigos.
- **Banco** (migration `20261029000009_etapa4_orcamento_pdf.sql`, aditiva e idempotente): `montar_orcamento` (preço, prazo, frete, arte, upsell por regra, `validar_margem`), `orcamento_documento` (só dados públicos + hash), `orcamento_renovar`, `preparar_link_pagamento`, `orcamento_registrar_link`, `validar_antes_de_cobrar` olhando a margem do orçamento, bucket privado `orcamentos`, colunas novas e tempo real em `orcamentos`.
- **Taxa do método e lucro real:** `validar_margem` já descontava a taxa do método previsto (Pix 0,99%, cartão 4,98%); agora, quando o pagamento chega, `confirmar_pagamento` grava a taxa real e o lucro líquido real no pedido (`taxa_pagamento_real_pct`, `lucro_liquido_real`) e passa o orçamento para `pago`.
- **PDF:** modelo HTML em `supabase/functions/_shared/orcamento-html.ts` (logo, paleta e Inter do CRM); Edge Function `orcamento-pdf` (Gotenberg, Storage, envio no WhatsApp, idempotente, vencido gera novo, trava de lucro antes de enviar). Infra em `infra/gotenberg/`.
- **n8n (MCP, desativados, tag gbh, exportados em `n8n/`):** `montar_orcamento`, `gerar_pdf_orcamento`, `gerar_link_pagamento`, `GBH | WF3 | Orçamento PDF`; o gancho de PDF de `condicao_especial` virou chamada real.
- **CRM:** Pedido > aba Orçamentos (número, status, valor, validade, margem, regra e confiança só do dono, abrir PDF, Enviar/Reenviar) e status do orçamento no cartão do kanban.
- **Exemplos:** 6 PDFs em `docs/exemplos-orcamento/` (catálogo fictício). Conferidos em tamanho de papel (A4) e de celular (390 px) e por texto: nenhum tem SKU, custo, margem, piso, fornecedor nem endereço de retirada; todos com 1 página e menos de 200 KB.
- **Testes:** `supabase/tests/orcamento_etapa4.sql` (**49 passam**), Etapas 1, 2 e 3 contra o schema novo (54, 82 e 67 passam), `npm test` (inclui `scripts/test-orcamento.ts`), typecheck e build verdes.

### Correção pós-aplicação (29/10/2026)
O banco de produção já tinha colunas da migration antiga da sessão interrompida (`orcamentos.avisos` e `orcamento_itens.especificacao` como `jsonb`), então `montar_orcamento` falhou com 42804. A migration `20261029000010_etapa4_compat_banco.sql` define o formato final (`avisos` jsonb, `especificacao` text), remove duas views sobras dessa tentativa e recria `montar_orcamento`. Testado em banco limpo e em banco com a migration antiga aplicada antes (49 + 67 + 54 + 82 passam). O erro foi reproduzido sem a correção.

### Correção 2 (29/10/2026, achada no teste de envio)
Nas Edge Functions a service role não alcança o schema `private`: `validar_margem` direto e a troca de status para `enviado` (trigger de lucro) falhavam com `permission denied for schema private`, e a função respondia "recusado pela trava de lucro" sem motivo. A migration `20261029000011` cria `orcamento_validar_margem` e `orcamento_marcar_enviado` (definer, só dono ou servidor) e a função passou a usá-los. Os testes locais rodam como administrador e não pegavam isso; agora há testes com `set role service_role` (51 passam). Lição: testar com o papel `service_role` sempre que uma Edge Function ou o n8n chamar uma função do banco.

### Regra do dono: entrega sem "bicicleta" (29/10/2026)
Para o cliente, a entrega grátis na região central é só "entrega grátis na região central, em horário comercial". A migration `20261029000012` troca os textos do orçamento e da ferramenta de frete, o código interno `bike_gratis` (o agente recebe `entrega_gratis`) e 4 trechos do conhecimento; o PDF e o seed foram ajustados e há testes que impedem a palavra. **Para a Etapa 5:** o prompt e os filtros do agente não podem citar bicicleta nem bike (`verificar_frete` ainda devolve campos internos como `cabe_na_bike` e `entrega_sugerida: bike`; o wrapper da ferramenta deve filtrar).

### Decisões
- O PDF é renderizado dentro da Edge Function (não no n8n) para o botão Reenviar do CRM funcionar sem o n8n e para o modelo ficar versionado e testado no repositório. O WF3 orquestra.
- O pedido (que o Mercado Pago cobra) nasce do orçamento na hora do link; arte entra como item "Criação de arte" (fora do catálogo, custo zero) e desconto vira `discount_pct` arredondado para baixo. Se um pedido já existente tiver valor diferente do orçamento, o link é recusado.
- Frete por Uber é por conta do cliente: não entra no total nem vira custo nosso. Entrega de bicicleta (grátis) entra como custo nosso no lucro.
- Texto livre nunca vira item: só SKU e quantidade. SKU e custo nunca saem para o agente.
- Os erros de preço (mercado abaixo do piso, `nao_competitivo`) ficam só nos campos protegidos do banco; o agente recebe só avisos públicos.

### O que NÃO foi feito (honestidade)
- **A identidade visual da pasta no seu computador (`G:\Meu Drive\...\SUA_GRAFICA_BH_BRANDKIT`) não estava acessível** a esta sessão (é uma pasta do Windows e o CRM roda em nuvem). Usei a paleta, o logo (mesmo do favicon) e a fonte Inter que o CRM já tem, que foram tirados do brand kit na Parte 1. **Compare um PDF de exemplo com o brand kit** (cores, fonte, logo) e me diga o que ajustar; é só o CSS do modelo.
- Gotenberg **não foi instalado** e a Edge Function não foi testada contra ele nem contra a Meta (sem acesso). Os PDFs de exemplo foram gerados com o Chromium local, o mesmo motor do Gotenberg.
- Os workflows do n8n foram validados pelo MCP, mas **não executados** (o gatilho "Execute Workflow" não roda pelo MCP). A lógica de preço, prazo, frete e travas foi testada no banco.
- Instagram (`@suagraficabh`) e site (`suagraficabh.com.br`) entram em `app_settings.company` por SQL (ver `depende-de-voce.md`); o PDF mostra só o que existir.

### Teste em produção (29/10/2026)
- Orçamento de teste criado por `montar_orcamento`, PDF gerado no Gotenberg (`gotenberg.bauerlab.com.br`), guardado no bucket privado, enviado como documento no WhatsApp a um número de teste (janela de 24 h aberta), recebido certinho. Segunda chamada de `enviar`: `ja_enviado: true`, sem mensagem repetida. `preparar_link_pagamento`: `ok` (pedido criado, valor igual ao do orçamento, link válido por 47,9 h). Chip "Orç. enviado" apareceu no cartão do kanban. Dados de teste apagados.
- **Para a auditoria final (Etapa 8):** testar o botão **Reenviar** na aba Orçamentos do pedido; testar `gerar_link_pagamento` ponta a ponta no n8n com o Mercado Pago em modo teste; republicar `mp-conferir` e `conhecimento` com o ajuste de autenticação da service role (hoje só `orcamento-pdf` e `mp-criar-link` têm); atribuir a credencial do n8n aos workflows da Etapa 3; sempre testar chamadas de função com o papel `service_role`.

### Pendências (dono)
Ver `docs/agente/depende-de-voce.md`, seção Etapa 4 (todas feitas em 29/10/2026, menos o que está em "Para a auditoria final" acima). Resumo: aplicar a migration (`docs/agente/aplicar-etapa4.sql`), rodar o teste SQL e os advisors, instalar o Gotenberg, criar os segredos `GOTENBERG_*`, publicar `orcamento-pdf`, atribuir a credencial do Supabase nos nós HTTP dos 4 workflows, conferir o PDF contra o brand kit e confirmar o prefixo do número do orçamento.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/orcamento_etapa4.sql supabase/tests/preco_etapa3.sql supabase/tests/agente_etapa1.sql supabase/tests/catalogo_etapa2.sql
npm run exemplos:orcamento -- docs/exemplos-orcamento     # refaz os 6 PDFs (Postgres local no ar)
```
No CRM (depois de aplicar): abra um pedido > aba Orçamentos > Enviar; o cartão do kanban mostra o status do orçamento.

## Etapa 3: preço inteligente e condição especial (concluída, aplicada em produção em 28/10/2026)

Branch de trabalho da sessão: `claude/etapa3-preco-desconto-julfis` (parte de `feat/agente-etapa3-preco`, que tinha o início do trabalho). Nada foi aplicado no Supabase, nada foi ativado no n8n, nada foi instalado no servidor.

### O que foi feito
- **Passo 0:** todo ponto que exibe ou grava preço foi listado e classificado em `docs/agente/mapa-crm.md` (seção 7). Tudo o que vai para cliente, orçamento, PDF ou link lê `calcular_preco`; o resto ficou rotulado "base de custo, sem pesquisa".
- **Banco** (migrations `20261029000006` e `20261029000007`, juntas em `docs/agente/aplicar-etapa3.sql`): cache e consultas de mercado, `fontes_pesquisa` (robots, termos e intervalo por domínio), `registrar_pesquisa_mercado` (outliers por desvio absoluto, mediana, confiança), `calcular_preco` com mercado, fator por grupo, âncora de vendas (3 ou mais em 90 dias, limitada pelo mercado), `nao_competitivo` e trava final no piso duro; `agente_preco` com orientação para o agente; `precos_praticados` alimentado por trigger; `aprender_precos_semana`; `oferecer_condicao_especial` (orçamento atualizado, pedido ligado, tudo ou nada), expiração com `pg_cron`, detector de caçador e de padrão incomum, relatório e resumo semanais, política com `simular_politica_desconto` e `salvar_politica_desconto`, edição manual de preço com piso duro e confirmação (`definir_preco_item_pedido`, `precos_manuais_log`), `skus_para_aquecer`. `aplicar_desconto` não existia no repositório nem no banco; o `drop` está na migration por segurança.
- **n8n (MCP):** 4 workflows criados na pasta Sua Gráfica BH, desativados e exportados em `n8n/` (ver `docs/n8n-mapa.md`). Lógica testada no n8n com dados simulados nos nós de rede.
- **Infra:** `infra/searxng` e `infra/renderer` prontos, com passo a passo em `docs/agente/infra-busca.md`.
- **CRM:** Catálogo > Saúde de preços completa (cobertura, margem, conversão, fator por grupo, fontes de cada preço, itens não competitivos, condições, resumo semanal, ajustes); Configurações > Política de desconto com simulação do pior caso e grupos sem desconto; pedido com lucro líquido, bloqueio e confirmação do dono ao editar preço.
- **Testes:** `supabase/tests/preco_etapa3.sql` (**67 passam**, inclui a simulação de **1.000 combinações sem nenhuma violação**), Etapas 1 e 2 contra o schema novo (54 e 82 passam), `npm test`, typecheck e build verdes. Relatório em `docs/agente/etapa3-validacao.md`.

### Decisões
- Fonte prioritária (alfacards.com.br): `robots.txt` libera, **não há página de termos** (ficou `termos_ok` vazio até o dono confirmar) e o preço só aparece com JavaScript e só para as opções padrão. Cobertura esperada baixa; as outras fontes e o cache completam.
- Mercado com 1 fonte é usado com confiança baixa e aviso; com 0 fontes vale a fórmula de custo.
- Aprendizado conta só orçamentos **encerrados** (ganho, perdido, expirado) dos últimos 30 dias, sem os de teste; o orçamento atualizado por condição conta como o original.
- A condição que levaria o orçamento atualizado a ser recusado pela trava de lucro vira "sem condição"; o agente nunca vê o motivo.
- Meta de margem do aprendizado: 20% (`meta_margem_liquida_pct`, para você revisar).
- O workflow de condição devolve o orçamento atualizado e o link novo; o **PDF** fica para o gancho da Etapa 4.

### Pendências
- Dono: aplicar `docs/agente/aplicar-etapa3.sql`, rodar `supabase/tests/preco_etapa3.sql` e os advisors, instalar a busca no Coolify, criar as credenciais no n8n, confirmar os termos de uso do concorrente (`docs/agente/depende-de-voce.md`).
- Etapa 4: PDF do orçamento atualizado e gravar nos itens do orçamento a fonte do mercado (`consulta_mercado_id`, `mercado_mediana`, `fontes_mercado`, `nao_competitivo`, `piso`, `piso_duro`, `lucro_liquido`, colunas já criadas).
- Etapa 5: mensagem curta de espera durante a pesquisa e G1 no WF2. Etapa 7: G2 e G3 nos follow-ups.
- `GBH | WF9 | Erros` ainda não existe (etapa 7/8); os workflows já usam retentativas e `continueRegularOutput`.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/preco_etapa3.sql supabase/tests/agente_etapa1.sql supabase/tests/catalogo_etapa2.sql
psql -h /tmp -p 54329 -U postgres -d gbh -f supabase/tests/tabela-etapa3.sql    # tabelas da validação
```
No CRM (depois de aplicar): Catálogo > Saúde de preços; Configurações > Política de desconto (mude um percentual e veja a simulação); Pedido > Itens (mude o preço de um item abaixo do piso).

## Etapa 2: Catálogo com SKU e banco de conhecimento (concluída, 28/10/2026)

### Aplicação em produção e fechamento (28/10/2026)
- Backup antes: cópia das 20.381 linhas em `private.bkp_products_etapa2` (área privada; apague quando quiser).
- Migrations 15 a 19 aplicadas pelo SQL Editor (`docs/agente/aplicar-etapa2.sql`). Conferido: `catalogo` com as mesmas 20.381 linhas, todas com piso calculado; `products` virou visão; CFV02 = R$ 75,99; 90 trechos; 12 perguntas no cache; 40 sinônimos; bucket `catalogo-fornecedor` privado; agendamento `conhecimento-reindexar` a cada 5 minutos; SKU obrigatório ligado.
- Edge Function `conhecimento` publicada (sem JWT; confere dono, service role ou `x-cron-secret`). Vetores `gte-small` funcionando (20 por rodada de 5 minutos, os 90 ficam prontos em cerca de 20 minutos).
- Segurança em produção: `anon` sem privilégio em `catalogo`, `products_priced`, `catalogo_importacoes` nem nas funções novas; RLS ligada em todas as tabelas novas; `buscar_produto` e `agente_preco` testadas com dados reais sem custo, piso, margem, lucro ou fornecedor na resposta.
- Advisors de segurança: nenhum alerta novo grave. As funções novas aparecem em "executável por usuário logado" por desenho (cada uma confere a permissão por dentro). Seguem os 2 antigos: `rls_auto_enable` executável por `anon` (função do próprio Supabase) e proteção contra senhas vazadas desligada no Auth.
- **A tabela do fornecedor passou a ser só Excel** (não mais PDF). A pré-visualização da importação mostrou que a planilha é **idêntica ao catálogo atual**: 20.381 linhas lidas, 20.381 iguais, 0 novas, 0 alteradas, 0 sem código, 0 conflitos, 0 rejeitadas, 0 removidas, CFV02 = R$ 75,99. Não havia nada a aplicar; a importação foi fechada como cancelada.
- **Linhas sem código: nenhuma.** As cerca de 590 linhas sem código eram do PDF, que foi descartado. Se uma tabela futura trouxer linhas sem código, a aba Sem código cuida delas.
- Os 90 trechos de conhecimento foram marcados como revisados a pedido do dono (que revisa depois). Os `[CONFIRMAR]` continuam escritos nos fatos de cada trecho como lembrete interno.

(O texto abaixo foi escrito antes da aplicação e fica como histórico.)

Branch da sessão `claude/optimistic-pasteur-9elhra` (pedida: `feat/agente-etapa2-catalogo-conhecimento`).

### O que foi feito
- Passo 0: o CRM já tinha upload do catálogo. Mapeei (tela, parser, tabela, colunas, preço) em `docs/agente/mapa-crm.md` e `docs/catalogo-e-sku.md`, listei as 11 lacunas e corrigi **na mesma tela**, mantendo as 20.381 linhas.
- Migrations 15 a 19 (aditivas, idempotentes): `products` virou `catalogo` com os campos finais, `catalogo_historico`, importação em duas fases (`catalogo_importacoes`, `catalogo_import_linhas`), bucket privado `catalogo-fornecedor`, SKU obrigatório (chaves estrangeiras `NOT VALID`, Produção bloqueada sem SKU, `itens_fora_catalogo`), `sinonimos`, `buscar_produto`, `agente_preco`, `kit_preco`, `pedido_para_fabrica`, banco de conhecimento v2 (`conhecimento`, `conhecimento_lacunas`, `conhecimento_consultas`, `faq_cache`), 90 trechos.
- Edge Function `conhecimento` (vetores `gte-small`, reindexação automática, busca para o n8n).
- Front: leitor de PDF, importação com pré-visualização e relatório, aba Sem código, SKU em destaque com copiar (catálogo, pedido, kanban, kit), aba "Pedido para a fábrica", Configurações > Conhecimento.
- Testes: `supabase/tests/catalogo_etapa2.sql` (**82 passam**), `agente_etapa1.sql` contra o schema novo (**54 passam**), recuperação (**37/40 = 92,5%**, só texto), `npm test` e `npm run typecheck` verdes.
- Documentos: `docs/catalogo-e-sku.md`, `docs/conhecimento.md`, `docs/agente/relatorio-importacao.md`, `docs/agente/relatorio-recuperacao.md`, `docs/agente/depende-de-voce.md`.

### Decisões
Ver `docs/agente/depende-de-voce.md` (renomear em vez de criar tabela nova; Pago nunca bloqueado; desativar em vez de apagar; limiares).

### O que NÃO foi feito (honestidade)
- **O PDF não foi anexado**, então a importação real e o relatório de linhas sem código **não existem ainda**.
- **Nada foi aplicado em produção.** Só consultei o banco de produção em modo leitura.
- A busca **vetorial** não foi medida (sem pgvector local); só a textual.
- Leiaute do PDF testado só com PDF fictício.
- Não rodei os advisors de segurança (dependem de aplicar).

### Pendências
Ver "O que depende de você". Resumo: PDF, aplicar migrations, deploy da função `conhecimento`, reindexar, advisors, códigos das linhas sem SKU, [CONFIRMAR] dos trechos.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/catalogo_etapa2.sql supabase/tests/conhecimento_recuperacao.sql supabase/tests/agente_etapa1.sql   # Postgres local descartável
```
No CRM (depois de aplicar): Catálogo e Kits > Importar tabela > Pré-visualizar; Pedido pago > aba Pedido para a fábrica; Configurações > Conhecimento.

## Etapa 1: Fundação (em revisão, 28/10/2026)

Branch `feat/agente-etapa1-fundacao`.

### O que foi feito
- Passo 0: mapa do CRM, do Supabase e do n8n em `docs/agente/mapa-crm.md` (conflitos e resoluções incluídos).
- Migrations 11 a 14 (aditivas e idempotentes): parâmetros comerciais, política de desconto, zonas de frete, configuração do agente, orçamentos, condições especiais, mercado, conhecimento (pgvector), follow-ups, alertas, testes de conversa, campos novos, endurecimento do `anon`.
- Funções `calcular_preco`, `calcular_prazo`, `verificar_frete`, `validar_margem`, `calcular_condicao_especial` e as travas de lucro no banco. Documentadas em `docs/agente-ia.md`.
- 54 testes SQL (`supabase/tests/agente_etapa1.sql`), executados em Postgres 16 local com as 14 migrations do projeto replicadas. `npm test` e `npm run typecheck` passam.
- 11 templates enviados à Meta (todos em análise), `docs/templates-whatsapp.md` e o painel de status em Configurações > WhatsApp e templates.

### Decisões
- Nomes que já existiam no CRM foram mantidos (`holidays`, `agent_logs`, `needs_human`, `summary`, `collected_data`); a tabela de mapeamento está no mapa.
- SKU = `products.code` por enquanto. A exigência de SKU em `order_items` fica desligada (`exigir_sku_pedidos`) até a Etapa 2 mudar a tela.
- Uma condição especial por orçamento (`max_condicoes_por_orcamento = 1`): se o F3 oferecer, o F4 não escala para o degrau 3. Para permitir a escalada, subir o parâmetro para 2.
- Zonas inativas (`ativo = false`) ficam cadastradas e não valem; só as 11 do dono e a faixa de CEP 30110-000 a 30199-999 valem.
- Taxa padrão do pedido passou de 1,5% para 4,98% (cartão de crédito) até o método real ser conhecido.

### Aplicação em produção (28/10/2026)
- Migrations 11 a 14 aplicadas no Supabase pelo SQL Editor (arquivo `docs/agente/aplicar-etapa1.sql`). Conferido: 15 tabelas, 5 funções, 6 triggers, 25 zonas (12 ativas), 11 regras de follow-up, 32 feriados, `anon` sem acesso a `products`.
- `supabase/tests/agente_etapa1.sql` rodado em produção: **54 testes passaram** (o bloco desfaz tudo, nada ficou gravado).
- Advisors de segurança: nenhum alerta novo. Os 2 que aparecem já existiam: `confirmar_pagamento_manual` executável pelo usuário logado (é o botão do dono, intencional) e proteção contra senhas vazadas desligada no Auth (ligar em Authentication > Policies).
- Observação: o histórico `supabase_migrations` de produção não registra estas 4 migrations (foram aplicadas pelo SQL Editor). Um futuro `supabase db push` as tentaria reaplicar; são idempotentes, então é seguro.

### Pendências
- Aprovação dos templates pela Meta.
- Ligar `exigir_sku_pedidos` e rotular o preço sugerido do catálogo na Etapa 2/3.
- Taxa real por método no lucro do pedido (Etapa 6).
- Ligar a proteção contra senhas vazadas no Auth.

### O que o dono deve revisar
1. **Feriados**: nacionais e de BH de 2026 e 2027 (tabela `feriados`, tela Prazos e feriados). Incluí 12/12 (aniversário de BH) para conferir; cai em fim de semana nos dois anos.
2. **Zonas de frete grátis**: lista abaixo. 11 bairros ativos e 13 candidatos inativos.
3. **`cabe_na_bike`**: 3.000 g e 600 mm. O peso do catálogo é o do pacote inteiro (soma de quantidades) e o lado é a maior medida de `size`. Banner de 1200 x 600 não cabe. Peso e tamanho vêm da planilha do fornecedor; itens sem medida entram como "dimensão desconhecida" e não ganham frete grátis.
4. **Parâmetros** marcados em `parametros_comerciais.campos_revisar`: validade do orçamento (7 dias), custo de WhatsApp (R$ 0,50) e de IA (R$ 0,30) por conversa, custo da bike (R$ 8,00) e do Uber (R$ 25,00), saídas de bike (2), pedido mínimo (R$ 150), tetos de tokens (40 mil por conversa, 1,5 milhão por dia), detector de caçador de desconto (4 orçamentos em 60 dias sem compra).
5. **Escada de desconto**: degrau 1 vantagem (frete grátis sem mínimo, senão arte grátis), degrau 2 até 4% (G1/G2), degrau 3 até 8% (G3), 60% da gordura, teto R$ 80, mínimo R$ 5, 24 h, 30 dias por contato.

### Zonas de frete grátis cadastradas

Ativas (carga inicial do dono): Centro, Santa Efigênia, Barro Preto, Lourdes, Funcionários, Savassi, Santo Agostinho, Floresta, Santa Tereza, Sagrada Família, Serra. Faixa de CEP ativa: 30110-000 a 30199-999 (aproximada).
Candidatas, inativas até confirmar: Santo Antônio, São Pedro, Sion, Carmo, Cruzeiro, Anchieta, Gutierrez, Lagoinha, Boa Viagem, Horto, Prado, Coração de Jesus, Santa Lúcia.

### Como testar
```bash
npm test && npm run typecheck
psql "$DATABASE_URL" -f supabase/tests/agente_etapa1.sql   # desfaz tudo; sucesso aparece como "OK: 54 testes passaram"
```
No CRM: Configurações > WhatsApp e templates mostra os 11 templates do agente e o status (clique em Sincronizar).

## Etapa 8 (auditoria) - 02/11/2026: relatório entregue, ativação aguardando autorização
- Relatório completo em `docs/auditoria-agente.md` (nota 7,5/10). Correções: custo real no item de pedido, gatilhos de pedido como definer, advisors, modo piloto da IA (`agente_config.piloto_*`). Reversões em `docs/rollback-etapa8.sql`.
- SearXNG ligado no Coolify e `searxng_url` do workflow de pesquisa atualizado. Workflows `GBH |` continuam DESATIVADOS: `publish_workflow` foi negado pelo ambiente; WF9 ainda sem ligação como `errorWorkflow`.
- Falta: ligar `encaminhar_setor`, `bauerlab` e escolha de opção no despachante e no WF2; testes de conversa com o modelo real (só possíveis com WF1 e WF2 ativos); Pix de R$ 1; segredos `N8N_WF1_URL` e `N8N_WF1_TOKEN`.
- Branch `claude/zealous-curie-n84wpk`; arquivos: `supabase/migrations/20261105000001..3`, `docs/auditoria-agente.md`, `docs/rollback-etapa8.sql`.

## Etapa 8 (auditoria) - FECHADA, aguardando Etapa 8B
- Relatório final: `docs/auditoria-agente.md` (seção 0 resume o estado). Branch `claude/zealous-curie-n84wpk`.
- Feito: correções de preço (custo real no item), gatilhos de pedido, `unaccent` (WF6), `service_role` no schema `private`, `conhecimento` v11, notificações só no push (WhatsApp só para problema de pagamento e cliente esperando humano), modo piloto, card no Kanban ao enviar orçamento, `buscar_produto` com opções reais e ficha traduzida, `produto-opcoes` (opções com foto), `orcamento-pdf` v16 (resumo e APROVADO), link só depois do PDF formal, sem teto de tokens, fluxo consultivo no WF2, 25 workflows ativos com WF9.
- Falta (Etapa 8B): teste ponta a ponta com o número de teste; ligar `encaminhar_setor`, `bauerlab` e escolha de opção; resumo automático separando pedido anterior e atual; SearXNG em rede interna; conferir credenciais nó a nó; decisões do dono (3 funções antigas do Supabase, `bkp_products_etapa2`, cupom de recompra, lembretes do pedido SG-0019 seguros em `followup_fila` com status cancelado).

## Sincronização com produção (04/11/2026, branch de trabalho)

- **Migration `20261104193000_ajustes_comerciais_producao.sql`:** reflete as funções já atualizadas em produção (`calcular_preco`, `montar_orcamento`, `calcular_prazo`, `private.inicio_contagem`, `public.agente_bloqueio`, `private.categoria_bate`, `public.add_business_days`). Conferido com hash normalizado (sem comentários e CR) dentro de transação revertida: as 7 funções batem com produção.
- **Divisão de custos m² (pendente de confirmação do dono):** 22 itens (ADESIVOS 15, BACKDROP 7) com quantidade 1 e custo acima de 500 ainda estão no valor original em produção. A migration divide por 100 uma única vez, com guarda em `app_settings.migracao_custo_m2_100x`. Não foi aplicada em produção.
- **Outros itens com custo ×100 fora dessas categorias (não alterados):** TÓTENS, LETRA CAIXA, DTF TÊXTIL, COMBOS e IMPRESSÃO SUBLIMÁTICA têm custo acima de 500 em quantidade 1. Confirmar com o dono se é o mesmo erro.
- **Comentários com o nome do fornecedor:** `calcular_preco`, `private.inicio_contagem` (e a migration) tinham o nome do fornecedor em comentários de SQL. Trocado por "fornecedor" na migration. Lógica inalterada.
- **Edge `orcamento-pdf`:** se a Meta recusar o PDF, manda resumo e link assinado em texto (`enviado_como: 'link'`). Com a janela de 24 h fechada, cria o alerta `janela_fechada_orcamento` (gravidade alta), marca a conversa com a tag `reabrir_janela` e responde `status: 'janela_fechada'`.
- **Edge `agente-enviar`:** texto acima de 1.500 caracteres é quebrado automaticamente em mensagens sequenciais, até 6.000 caracteres por envio. Acima disso, responde 400 claro.
- **Diretrizes (`AGENTS.md` e `CLAUDE.md`):** antes do pagamento, o agente pode citar a localização de referência (hipercentro de BH, próximo à Praça Sete). O endereço fabril completo continua proibido antes do pagamento. Fluxo de fechamento padrão: PDF formal, aceite "APROVADO", link do Mercado Pago com Pix.
- **Pendências:** deploy das Edge Functions `orcamento-pdf` e `agente-enviar`; o prompt do WF2 no n8n ainda diz que o endereço só vai depois do pagamento (mudar pelo MCP do n8n); aplicar a migration de custos m² só após confirmação do dono.

## Sincronização e telemetria da Laura (10/11/2026)

- **Migrations versionadas (já estavam em produção):** `20261110000001_motor_vendas_producao` (montar_orcamento, agente_debounce, agente_iniciar com teto de 60 s, agente_watchdog_reconciliar, private.order_items_validar, definir_preco_item_pedido, calcular_acabamento_seguro, pg_trgm e índice). Conferido por hash do corpo das funções (diferenças só de espaço no fim de linha).
- **Migrations novas, aplicadas em produção:** `20261110000002_v_funil_percentis` (P50/P95, rodadas de até 10 min), `20261110000003_webhook_fila_entrada` (tabela `webhook_eventos`), `20261110000004_v_funil_total_rodadas` (total de rodadas, denominador das taxas).
- **Pendência de segurança e de código:** `calcular_acabamento_seguro` consulta `public.acabamentos`, tabela que não existe em produção. Não é chamada por `montar_orcamento` (que usa `produto_acabamentos`). Revisar ou remover.
- **Webhook (fila de entrada):** grava o evento em `webhook_eventos`, responde 200 e processa em segundo plano; eventos pendentes são reprocessados nas chamadas seguintes; processados são apagados após 3 dias. Não usa BullMQ/Redis (não há Redis no Supabase Edge). **Não deployado:** precisa de deploy de `whatsapp-webhook` (e `_shared`), testado com um número real antes de ir ao ar.
- **Tela `/laura`:** KPIs (conversas, orçamentos, pedidos pagos, faturamento, conversão), latência (P50/P95), taxas de ocupadas e erros, gráfico e tabela diária, filtros hoje/7/15/30 dias.
- **n8n:** `n8n/GBH-WF2-Agente.json` reexportado (atualizado em 04/11 às 23h00). `n8n/GBH-WF1-Entrada-e-roteamento.json` continua da exportação anterior: a instância mostra atualização de 04/11 às 22h18, então precisa de nova exportação.

## Controles operacionais do pedido (11/11/2026)

- **Prazo combinado:** `PrazoCombinado` (drawer, aba Entrega, e barra lateral do chat). Escolher uma data grava `due_date` e `due_date_manual = true`, e o trigger `orders_set_due_date` deixa de mexer nela. Badge "Prazo manual / combinado" e botão "Recalcular pelo sistema" (desliga a marcação; o trigger refaz a conta quando o pagamento está confirmado).
- **Etapas da arte:** `ArtEtapas` (aba Arte e barra lateral do chat). Marcar "Arquivo recebido" grava `art_status = 'enviada'`, "Arte em montagem" grava `'em_criacao'` e "Arte aprovada" grava `'aprovada'`, e cada etapa grava a chave correspondente em `art_checklist`. "Liberado para produção" passa por `useMoveOrder`, com a trava do banco (pagamento e arte aprovada).
- **Ponto de atenção:** o rótulo `'enviada'` no sistema é "Enviada ao cliente", mas na etapa 1 ele representa "arquivo recebido do cliente". Vale alinhar o rótulo.
- **Edge `cliente-pago-avisar`:** o repositório não lê `prazo_manual` nem `art_status`. A v5 em produção lê. Sincronizar o código antes de qualquer novo deploy.

## Pedido alterado: link de pagamento acompanha o valor (11/11/2026)

- Ao salvar itens (incluindo a remoção de um item) ou os percentuais de desconto, imposto e taxa, o drawer gera um link novo com `mp-criar-link` (`forcar_novo`) quando o pedido já tem link e não está pago. O link antigo é expirado no Mercado Pago.
- **Pendente:** o PDF do orçamento é montado a partir do orçamento (`orcamento_documento`), e não dos itens do pedido. Editar o pedido não muda o PDF. Decisão necessária sobre qual é a fonte de verdade.

## PDF acompanha o pedido (11/11/2026)

- **Decisão do dono:** o pedido é a fonte dos itens e do desconto.
- **Migration `20261111000001_pedido_sincroniza_orcamento`** (aplicada em produção): `pedido_sincronizar_orcamento(p_order)` copia os itens do pedido para o orçamento ativo (rascunho, enviado ou aceito) e recalcula o desconto. Tudo ou nada: item sem SKU ou abaixo do piso duro recusa a operação inteira. Pedido sem orçamento ativo não muda nada.
- **Drawer:** salvar item, remover item ou alterar desconto, imposto ou taxa sincroniza o orçamento e depois renova o link de pagamento. Como o hash do documento muda, o próximo "Gerar PDF" ou "Reenviar" já sai com os valores novos.
- **Limite:** item manual (sem SKU) não entra no orçamento em PDF. A sincronização avisa o operador.

## Itens sem SKU no orçamento (migration 20261111000002)
- `orcamento_itens.sku` aceita vazio; item manual exige `custo_unitario` (check `orcamento_itens_sku_ou_custo`).
- Validador, financeiro e PDF tratam item manual; o custo vem de `order_items.unit_cost`.
- `pedido_sincronizar_orcamento` deixa de recusar item sem SKU e cria rascunho quando o pedido não tem orçamento ativo (não cria para pedido pago, cancelado ou excluído).
- Validado com transação revertida em pedido real: sync ok, custo gravado, financeiro e PDF com 3 itens.

## Orçamento perdido no Kanban (migration 20261113000001)
- `orcamento_registrar_perda(p_orcamento, p_motivo, p_obs)`: motivo obrigatório (preco, prazo, sumiu, decidiu_depois, abandonou_checkout, outro); observação obrigatória quando o motivo é outro; marca `status = 'perdido'`; recusa orçamento pago.
- Novo campo `orcamentos.motivo_perda_obs` (até 500 caracteres).
- Aba Orçamentos do pedido: botão "Marcar como perdido" com motivo e observação.
- Kanban: coluna "Orçamento perdido" (lista com motivo, observação e valor), fora do arrastar e soltar.
- `pedido_sincronizar_orcamento` não cria rascunho novo para pedido com orçamento perdido ou cancelado.
- Validado com transação revertida: motivo outro sem observação recusado; motivo válido marca perdido; sincronização não recria orçamento.

## Pedido perdido (migration 20261114000001)
- Novo estágio `perdido` no pedido, com `motivo_perda`, `motivo_perda_obs` e `motivo_perda_em`.
- Trava no banco (`orders_exigir_motivo_perda`): sem motivo não entra; motivo Outro exige observação; pedido pago não entra.
- Função `pedido_registrar_perda` usada pela tela. Validada em transação revertida.
- Kanban: arrastar para Perdido ou escolher "Mover para Perdido" no card abre a pergunta do motivo. A ficha do pedido também abre a pergunta e mostra o motivo.
- Pedido perdido pode voltar para qualquer etapa (o motivo fica guardado no histórico).

## Mensagem automática depois do pagamento mais curta
- Texto do cliente (`montarConfirmacaoCliente`, em `cliente-pago-avisar` e `_shared/alertas.ts`): confirmação, pedido, previsão, uma frase sobre a arte e uma sobre a retirada. Sem "assistente virtual".
- O template aprovado pela Meta (`pedido_pago_confirmacao`) não mudou. Só vale fora da janela de 24 h, e trocar o corpo exige nova aprovação.
- Funções `cliente-pago-avisar` e `alertas-enviar` precisam de deploy para o texto novo entrar em produção.

## Estabilização da Laura e exportação do n8n (11/11/2026)
- WF1, WF2 e `chamar_dono` reexportados para `n8n/` (versões publicadas, sem credenciais). Runbook completo em `docs/agente/runbook-laura.md` (causas, correções, como testar, riscos).
- Migrations de trava de saída aplicadas e mescladas (`20261111170000` a `20261111182000`). PR #88 (e-commerce, Kanban e catálogo atômico) mesclado.
- 21 cenários `e5-*` e `mvp-*` passaram na última rodada; 2 contatos de teste antigos ("Anderson", "Paulo", 02/11) permanecem.
- **Pendente:** exportar buscar_conhecimento, buscar_produto, salvar_contato, verificar_frete, agendar_followup e o clone do WF2; fixar versão do modelo Gemini; teste de ponta a ponta com pedido real no Mercado Pago.

## Fase 3: um SKU = um produto na loja (11/11/2026)
- Detalhes em `docs/ecommerce.md` (Fase 17). Migrations `20261129000001` a `20261129000005` aplicadas em produção. Loja: cards e páginas por SKU, sitemap com 20.381 produtos, redirecionamento dos links antigos. Nada oculto (1.246 SKUs voltaram; 1.779 com rótulo "Opção").
- Laura: `buscar_produto` devolve `link_produto` (workflow republicado) e o divisor do WF1 não corta link. Regressão: 21 `e5-*` e `mvp-A1/A2/B1` passaram. No e5-04 e no e5-12 a resposta foi a neutra ("Deixa eu confirmar isso certinho..."), que passa no critério mas é fraca.
- CRM: lista do Catálogo > Produtos não colapsa mais (altura mínima). `scripts/test-rules.ts` usa `fileURLToPath` (quebrava no Windows com acento no caminho); `test-conhecimento`, `test-orcamento` e outros scripts ainda usam `.pathname` e falham no Windows do dono (passam no Linux).
- **Não verificado:** a loja em produção (só local), o catálogo do CRM no navegador do dono (a correção é de layout, sem teste visual), e a Fase 3 com a referência logada (a extensão do Chrome não esteve disponível; usei páginas públicas).
