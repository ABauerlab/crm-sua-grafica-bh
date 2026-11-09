# Blog do site (E-commerce Fase 8)

Posts automáticos em `suagraficabh.com.br/blog`, escritos a partir de notícias do setor gráfico. A notícia é só a **pauta**: o texto é próprio, cita a fonte e termina com o link para a matéria original.

## Fluxo
1. Agendamento `blog-pautas` (07h, 12h e 17h de BH) chama a Edge Function `blog-pautas` com `x-cron-secret`. O botão "Buscar pautas agora" (CRM > Catálogo > Blog do site) faz o mesmo.
2. A função lê as fontes ativas de `blog_fontes` (feeds RSS públicos; NewsAPI só se `app_settings.blog.newsapi = true` e o segredo `NEWSAPI_KEY` existir) e grava em `blog_pautas` (uma por URL, só dos últimos 10 dias).
3. **Filtro 1 (código):** precisa de um termo de `termos_setor` e nenhum de `termos_proibidos` (política, esporte, crime, programas sociais...).
4. **Filtro 2 (Gemini, segredo `GEMINI_API_KEY`):** nota de relevância de 0 a 10 e o texto em JSON. Abaixo de `relevancia_minima` (7) a pauta é descartada com o motivo.
5. **Conferência (`_shared/blog.ts`, `validarPost`):** título, resumo e corpo no tamanho, crédito à fonte no texto, nenhum endereço de site, nenhum preço/desconto/promoção, nenhum trecho de 10 palavras copiado da fonte, nenhum termo bloqueado (inclui automaticamente a origem interna das fotos) e pelo menos uma categoria válida da loja. Travessão vira vírgula.
6. Links internos: o modelo só marca `[[slug|texto]]` com slugs da lista enviada; o servidor transforma em `/categoria/<slug>` e descarta o resto.
7. Publica sozinho em `blog_posts` até `posts_por_dia` (3) por dia de BH.

## Site
- `/blog` (lista paginada), `/blog/[slug]` (post, crédito "Pauta: fonte" com `rel="nofollow"`, produtos relacionados, CTA WhatsApp, JSON-LD `BlogPosting`). Sitemap inclui os posts.
- Leitura pública só por `loja_blog_lista`, `loja_blog_post` e `loja_blog_slugs` (somente publicados).

## Controle do dono
- CRM > Catálogo > **Blog do site**: lista, abrir no site, ocultar/mostrar, rodar agora.
- `app_settings.blog`: `ligado`, `posts_por_dia`, `avaliacoes_por_rodada`, `relevancia_minima`, `modelo`, `newsapi`, `termos_setor`, `termos_proibidos`, `termos_bloqueados`.
- Fontes: tabela `blog_fontes` (`ativo = false` desliga uma fonte; `ultimo_erro` mostra falhas de leitura).

## NewsAPI
O plano gratuito só permite uso em desenvolvimento e quase não traz notícias do setor em português. Por isso ela fica desligada. Para ligar: assinar um plano pago, cadastrar `NEWSAPI_KEY` nos segredos das Edge Functions e trocar `app_settings.blog.newsapi` para `true`. A chave nunca vai ao repositório.

Testes: `npm run test:blog`.
