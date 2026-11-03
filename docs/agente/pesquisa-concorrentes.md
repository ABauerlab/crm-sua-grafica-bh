# Pesquisa de mercado: estado real, Silcor e catálogo público do fornecedor (Etapa 8C)

Verificado em 02/11/2026. Só leitura de páginas públicas, com o identificador `GBH-PrecoBot/1.0`, 1 pedido a cada poucos segundos, sem login, sem carrinho e sem API privada.

## 1. O que realmente funciona hoje na pesquisa de preço

| Peça | Estado real | Evidência |
|---|---|---|
| SearXNG | **Responde** (45 resultados para "cartao de visita 500 unidades preco"). Mas está em endereço **público** (`searxng-...sslip.io`, porta 80, sem senha), não na rede interna como o `infra-busca.md` previa. Qualquer pessoa pode usar a API JSON. | `curl` do dia 02/11 |
| Workflow `GBH \| FERRAMENTA \| pesquisar_preco_mercado` | **Falha no primeiro nó**: `Consultar cache`, `Reservar acesso ao domínio` e `Registrar pesquisa no banco` estavam sem a credencial Supabase ("Credentials not found"). A pesquisa devolve `origem: erro` e o preço sai só pela fórmula de custo com travas, sem mercado. | execução 5735 (01/11) |
| Domínios liberados em `fontes_pesquisa` | Só `www.alfacards.com.br` (robots ok, termos em branco). A busca devolve sobretudo marketplaces, que o workflow descarta de propósito. | consulta ao banco |

Correção feita: a credencial foi religada nos 3 nós **no rascunho** do workflow (versão nova). **Falta publicar** (precisa da sua autorização, é workflow de produção). Sem publicar, nada muda em produção.

Pendências de segurança da infraestrutura (não resolvidas aqui):
1. SearXNG público: colocar na rede interna do Coolify (como o doc manda) ou exigir senha no proxy. Enquanto isso o `searxng_url` do workflow aponta para o endereço público.
2. Há workflows `GBH |` que o MCP salvou sem credencial nos nós HTTP. Confirmar nó a nó antes da liberação (item "credenciais dos 25 workflows").

## 2. Gráfica Silcor (https://www.graficasilcor.com.br/)

- Plataforma Nuvemshop. `robots.txt` bloqueia só áreas de loja (`/admin/`, `/checkout/`, `/search/`, `/comprar/`, `/frete/`); **`/produtos/` está liberado**. Sitemap com ~1.400 URLs, **846 páginas de produto**.
- Termos ("termos-para-prestacao-de-servicos"): não há cláusula contra leitura automatizada. `termos_ok` pode ser marcado pelo dono depois de ler.
- **Estrutura ótima para comparar produto equivalente sem JavaScript**: cada produto é uma especificação fechada no próprio endereço (ex.: `cartoes-de-visita-couche-250g-verniz-uv-total-frente-91x51mm-4x0`) e a página traz o atributo `data-variants` com JSON de todas as variações (`sku`, `price_number`, `option0` = quantidade, `available`). Dá para casar papel, gramatura, acabamento, tamanho e cores com o catálogo oficial e ler o preço da quantidade exata.
- Recomendação: **incluir como fonte prioritária** junto da Alfacards, com `intervalo_s` de 15 s, e ler pelo sitemap (846 URLs, uma vez por semana) em vez de depender da busca. Não substitui a regra do `calcular_preco` (mercado + âncora + travas); só alimenta `precos_mercado`.
- Passo seguinte (precisa publicar workflow): nó de leitura `data-variants` no workflow de pesquisa e linha em `fontes_pesquisa` (`www.graficasilcor.com.br`, `robots_ok = true`, `termos_ok` depois da sua conferência).

## 3. Catálogo público do fornecedor (só para entender a estrutura)

Regra do dono: o nome e o endereço do fornecedor nunca ficam no repositório. O endereço foi informado por ele na conversa e não é registrado aqui; o leitor recebe o endereço por configuração (`app_settings`), como a origem das fotos.

- `robots.txt`: `Allow: /` para todos os robôs. HTML renderizado no servidor (página de listagem com cerca de 2,6 MB).
- A estrutura de categorias é por **caminho**: `/home/categoria/<categoria>/<subcategoria>/<tipo>/...` (ex.: `adesivos`, `panfletos-flyers-e-folhetos`, `postais`, `comunicacao-visual`, `linha-acrilico`, e até 6 níveis em canecas e vestuário). Os níveis finais carregam as variações (material, tamanho, acabamento).
- Uso previsto: **mapa de categorias, subcategorias e variações como referência de cobertura** (o que existe lá e ainda não está no catálogo oficial). Nunca troca nem altera o catálogo oficial, e nenhum preço entra por aqui.
- Passo seguinte: reaproveitar o leitor `infra/renderer` (ou HTTP direto, o HTML já vem pronto) num script que percorre `/home/categoria/` com 1 pedido a cada 5 s e grava só a árvore (nome, caminho, número de variações). Uma vez por mês.
