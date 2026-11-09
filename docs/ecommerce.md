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
| 2 | Ficha técnica, acabamentos, gabaritos e fotos de cada produto a partir da origem interna (`produto_fotos_mapa`, com a tabela de cache de raspagem que já existe no banco), com robots e limite de taxa; nunca citar a origem | próxima |
| 4 | API `/api/v1` (busca, cotação, cálculo com frete, preferência do Mercado Pago) como route handlers chamando RPCs | pendente |
| 5 | Vitrine, página de produto com configurador, serviços de arte (R$ 14,90 / R$ 39,90), "Cobrimos qualquer orçamento" via condição especial G2, prompt da Laura com o endereço público | pendente |
| 6 | Bling: colunas fiscais (NCM, CFOP, bling_*), `preco_marketplace`, `bling-webhook` (sem disparos) | pendente |
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
