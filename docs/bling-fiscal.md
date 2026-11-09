# Bling ERP e nota fiscal (Fase 6: estrutura pronta, nada é enviado)

Objetivo: cada venda paga do CRM vira um pedido de venda no Bling (`POST /pedidos/vendas`) já completo, na loja **SUAGRÁFICABH**, para o operador só clicar em "Emitir nota". Nesta fase não há chamada ao Bling: o banco monta o payload e aponta o que falta.

## O que existe
- **Credenciais:** `BLING_CLIENT_ID` e `BLING_CLIENT_SECRET` ficam nos segredos das Edge Functions (Supabase), nunca no repositório. Os tokens OAuth (access/refresh), quando houver autorização, vão para `app_segredos`.
- **Configuração** (`app_settings.bling`): `ativo` (false), `webhook_processar` (false), `loja_nome` = SUAGRÁFICABH, `loja_id` (id numérico da loja no Bling, descobrir com `GET /lojas` depois da autorização), `uf_emitente` = MG, CFOPs e `servicos_na_nfe` = false.
- **`bling_pedido_payload(pedido)`**: devolve `{ ok, pendencias[], contato, pedido, servicos, cfop }` no formato da API v3. Só o dono ou a service role chamam.
- **Pendências conferidas:** pedido pago, nome, CPF/CNPJ (11 ou 14 dígitos), CEP, logradouro, número, bairro, município e UF, código IBGE, e-mail, NCM de cada item e o id da loja no Bling.
- **Contatos** ganharam: `tipo_pessoa` (F/J), `ie_indicador` (1 contribuinte, 2 isento, 9 não contribuinte), `inscricao_estadual`, `logradouro`, `numero`, `complemento`, `municipio`, `uf`, `codigo_ibge` (Belo Horizonte = 3106200) e `bling_contact_id`.
- **Pedidos** ganharam: `canal` (whatsapp, site, balcao, mercado_livre, shopee, tiktok, amazon, magalu, facebook), `marketplace_pedido_id` (único por canal), `bling_pedido_id`, `bling_enviado_em`, `bling_erro`. Pedido do site recebe `canal = site` sozinho.
- **Webhook** `bling-webhook`: confere a assinatura HMAC-SHA256 (`X-Bling-Signature-256`, com o client secret) e grava o aviso em `bling_eventos` (sem duplicar). Criar pedido no CRM a partir do aviso fica para quando os marketplaces forem ligados.

## NCM (sugestão: confirmar com o contador)
Tabela `fiscal_ncm_regras` (editável pelo dono) aplicada por categoria com `fiscal_aplicar_ncm()`. Todos os SKUs estão com `ncm_revisar = true` até o contador marcar a regra como `confirmado`.

| NCM | Uso |
|---|---|
| 4911.10.90 | Impressos publicitários: panfletos, folhetos, filipetas, folders, cartazes, encartes, wobblers |
| 4911.10.10 | Catálogos comerciais |
| 4911.99.00 | Outros impressos: cartões de visita, timbrados, convites, cardápios, certificados, ingressos |
| 4910.00.00 | Calendários |
| 4909.00.00 | Cartões postais |
| 4817.10.00 | Envelopes |
| 4821.10.00 | Etiquetas, tags e rótulos de papel |
| 3919.90.00 | Adesivos plásticos (vinil, BOPP) |
| 4820.10.00 / 4820.20.00 / 4820.30.00 | Blocos e talões / agendas e cadernos / pastas |
| 4901.99.00 | Livretos e revistas |
| 6912.00.00 | Canecas e azulejos de cerâmica |
| 6109.10.00 | Camisetas |
| 6307.90.90 | Bandeiras e faixas de tecido |
| 3926.90.90 | Placas, displays, totens e peças rígidas de plástico |
| 3924.10.00 | Copos, squeezes e utensílios plásticos |
| 9608.10.00 | Canetas |

**Correção em relação ao pedido original:** pela TIPI, 4911.10.10 é "catálogos comerciais"; impresso publicitário (panfleto, folheto) é **4911.10.90**. Calendário, postal, envelope, caneca e camiseta também têm NCM próprio. Origem da mercadoria: 0 (nacional).

## CFOP
- Dentro de MG: **5102** (revenda de mercadoria de terceiros, que é o caso: a produção é terceirizada).
- Fora de MG para contribuinte do ICMS (indicador 1): **6102**.
- Fora de MG para **não contribuinte** (consumidor final, indicador 9): **6108**. É o caso mais comum nas vendas do site e dos marketplaces; usar 6102 aqui gera rejeição ou recolhimento errado do DIFAL.
- 5101/6101 só se a Sua Gráfica BH passar a industrializar.

## Arte não entra na NF-e de mercadoria
Conferência e criação de arte são **serviço** (ISS, NFS-e da prefeitura de BH), não mercadoria. O payload separa esses itens em `servicos` e põe o aviso em `observacoesInternas`. Se o contador preferir outro tratamento, mudar `servicos_na_nfe`.

## Pontos para o contador
1. Regime tributário (Simples Nacional? CSOSN 102 ou 400) e alíquotas.
2. Conferir a tabela de NCM e marcar `confirmado`.
3. DIFAL nas vendas interestaduais a não contribuinte (EC 87/2015).
4. Emissão de NFS-e para os serviços de arte.

## Marketplaces
- `app_settings.marketplaces`: comissão e taxa fixa por canal (Mercado Livre 17% + R$ 6,75; Shopee 20% + R$ 4; TikTok 12% + R$ 2; Amazon 15% + R$ 2; Magalu 16% + R$ 5) e `prazo_extra_dias` = 2. **Conferir os valores vigentes de cada canal antes de anunciar.**
- `catalogo_marketplace` (só o dono): para cada SKU, o preço por canal calculado para **receber o mesmo que no site** depois da comissão e da taxa fixa (nunca abaixo do custo + lucro mínimo), e o prazo de fabricação = prazo de produção + 2 dias úteis. Ex.: CFV02 site R$ 151,90 → Mercado Livre R$ 191,90, Shopee R$ 194,90.
- `scripts/enrich-marketplace-ads.ts`: gera o CSV de anúncios (título de busca até 60 caracteres, descrição em tópicos, preço, prazo, NCM, peso e embalagem) por canal. O CSV não entra no repositório.

## Para ativar depois (quando o dono quiser)
1. Rodar a autorização OAuth do app no Bling (redirect `https://suagraficabh.com.br/`) e guardar os tokens em `app_segredos`.
2. `GET /lojas` → gravar o id da loja SUAGRÁFICABH em `app_settings.bling.loja_id`.
3. Cadastrar a URL do webhook no app do Bling: `https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/bling-webhook`.
4. Criar a função de envio (pedido pago sem pendências → `POST /contatos` e `POST /pedidos/vendas`) e ligar `ativo`.
