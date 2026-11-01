# Definição dos indicadores (painel Comercial)

Fonte única: função `public.painel_comercial(de, ate)` (só o dono). Todos os números excluem pedidos de teste e pedidos excluídos. Datas em America/Sao_Paulo. Faturamento e lucro são **separados**.

| Grupo | Indicador | Definição |
|---|---|---|
| Aquisição | Contatos novos | contatos criados no período |
| | Vindos de anúncio | contatos novos com `first_referral` (clique para o WhatsApp) |
| | Gasto em anúncios | soma de `ad_daily.spend` (Meta, Windsor) mais `ad_manual_spend` no período |
| Conversão | Orçamentos enviados | orçamentos originais com PDF enviado no período (versões por condição especial não contam em dobro) |
| | Pedidos pagos | pedidos com `payment_status = aprovado` e `paid_at` no período |
| | Perdidos por motivo | orçamentos com `motivo_perda` registrado no período |
| Rentabilidade | Faturamento | soma do total dos pedidos pagos (`order_financials.total`) |
| | Lucro líquido | soma de `net_profit` dos pagos, com imposto, **taxa real do Mercado Pago** (quando conhecida) e custo |
| | Ticket médio | faturamento / pedidos pagos |
| | Lucro menos anúncios | lucro líquido - gasto em anúncios |
| | Custo por pedido | gasto em anúncios / pedidos pagos |
| | ROAS (faturamento) e ROAS (lucro) | faturamento / gasto e lucro / gasto. **A atribuição é por lucro, não por número de mensagens** |
| Fidelização | Clientes que recompraram | clientes com 2 ou mais pedidos pagos (`contact_stats`) |
| Operação | Pedidos atrasados | `pedido_esta_atrasado`: em produção, não entregue e fora do prazo útil |
| | Urgentes abertos | pedidos com selo de urgência ainda não entregues |
| | Alertas não lidos | `alertas` sem `lido_em` |

Para bater CRM, n8n, Mercado Pago e anúncios: o CRM é a referência de pedido e lucro; o Mercado Pago confirma o recebimento (`pagamentos`); os anúncios entram por `ad_daily` (Meta e Windsor) ou manual; a ligação entre anúncio e pedido é `orders.origin_ad_id` (view `atribuicao_pedidos`: campanha, conjunto, anúncio, criativo, origem e data do primeiro contato). UTM: o clique para o WhatsApp não traz UTM; o que existe é o `source_id` do anúncio, e dele vêm campanha e conjunto.
