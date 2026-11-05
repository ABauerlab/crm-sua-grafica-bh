-- Telemetria da Laura: a view v_funil_vendas_ia ganha total_rodadas_ia (denominador das taxas de ocupadas e erros).
-- Recriada a partir da migration 20261110000002. Colunas antigas iguais; a nova entra no fim.

create or replace view aceita isso).

create or replace view public.v_funil_vendas_ia as
 WITH diario AS (
         SELECT date_trunc('day'::text, (messages.created_at AT TIME ZONE 'America/Sao_Paulo'::text))::date AS data,
            count(DISTINCT messages.conversation_id) AS conversas_ativas,
            count(*) FILTER (WHERE messages.direction = 'in'::text) AS msgs_recebidas,
            count(*) FILTER (WHERE messages.direction = 'out'::text) AS msgs_enviadas
           FROM messages
          WHERE messages.created_at >= (now() - '30 days'::interval)
          GROUP BY (date_trunc('day'::text, (messages.created_at AT TIME ZONE 'America/Sao_Paulo'::text))::date)
        ), pedidos AS (
         SELECT date_trunc('day'::text, (o.created_at AT TIME ZONE 'America/Sao_Paulo'::text))::date AS data,
            count(*) AS pedidos_totais,
            count(*) FILTER (WHERE o.stage = ANY (ARRAY['pago'::text, 'producao'::text, 'pronto'::text, 'entregue'::text])) AS pedidos_pagos,
            COALESCE(sum(COALESCE(it.total_itens, 0::numeric)) FILTER (WHERE o.stage = ANY (ARRAY['pago'::text, 'producao'::text, 'pronto'::text, 'entregue'::text])), 0::numeric) AS faturamento_reais
           FROM orders o
             LEFT JOIN LATERAL ( SELECT sum(order_items.qty::numeric * order_items.unit_price) AS total_itens
                   FROM order_items
                  WHERE order_items.order_id = o.id) it ON true
          WHERE o.created_at >= (now() - '30 days'::interval)
          GROUP BY (date_trunc('day'::text, (o.created_at AT TIME ZONE 'America/Sao_Paulo'::text))::date)
        ), desempenho AS (
         SELECT date_trunc('day'::text, (agente_execucoes.iniciado_em AT TIME ZONE 'America/Sao_Paulo'::text))::date AS data,
            count(*) AS total_rodadas_ia,
            round(avg(EXTRACT(epoch FROM agente_execucoes.finalizado_em - agente_execucoes.iniciado_em) * 1000::numeric) FILTER (WHERE agente_execucoes.status = 'concluida'::text)) AS tempo_medio_resposta_ms,
            count(*) FILTER (WHERE agente_execucoes.status = 'ocupada'::text) AS rodadas_descartadas_ocupadas,
            count(*) FILTER (WHERE agente_execucoes.status = 'erro'::text) AS rodadas_com_erro,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (EXTRACT(epoch FROM agente_execucoes.finalizado_em - agente_execucoes.iniciado_em) * 1000::numeric)::double precision) FILTER (WHERE agente_execucoes.status = 'concluida'::text AND agente_execucoes.finalizado_em - agente_execucoes.iniciado_em < interval '10 minutes') AS tempo_p50_ms,
            percentile_cont(0.95::double precision) WITHIN GROUP (ORDER BY (EXTRACT(epoch FROM agente_execucoes.finalizado_em - agente_execucoes.iniciado_em) * 1000::numeric)::double precision) FILTER (WHERE agente_execucoes.status = 'concluida'::text AND agente_execucoes.finalizado_em - agente_execucoes.iniciado_em < interval '10 minutes') AS tempo_p95_ms
           FROM agente_execucoes
          WHERE agente_execucoes.iniciado_em >= (now() - '30 days'::interval)
          GROUP BY (date_trunc('day'::text, (agente_execucoes.iniciado_em AT TIME ZONE 'America/Sao_Paulo'::text))::date)
        )
 SELECT d.data,
    COALESCE(d.conversas_ativas, 0::bigint) AS conversas_ativas,
    COALESCE(d.msgs_recebidas, 0::bigint) AS msgs_recebidas,
    COALESCE(d.msgs_enviadas, 0::bigint) AS msgs_enviadas,
    COALESCE(p.pedidos_totais, 0::bigint) AS pedidos_totais,
    COALESCE(p.pedidos_pagos, 0::bigint) AS pedidos_pagos,
    COALESCE(p.faturamento_reais, 0::numeric) AS faturamento_reais,
    COALESCE(round(p.pedidos_pagos::numeric / NULLIF(d.conversas_ativas, 0)::numeric * 100::numeric, 1), 0::numeric) AS taxa_conversao_pct,
    COALESCE(dp.tempo_medio_resposta_ms, 0::numeric) AS tempo_medio_ms,
    COALESCE(dp.rodadas_descartadas_ocupadas, 0::bigint) AS rodadas_ocupadas,
    COALESCE(dp.rodadas_com_erro, 0::bigint) AS rodadas_com_erro,
    COALESCE(round(dp.tempo_p50_ms::numeric), 0::numeric) AS tempo_p50_ms,
    COALESCE(round(dp.tempo_p95_ms::numeric), 0::numeric) AS tempo_p95_ms,
    COALESCE(dp.total_rodadas_ia, 0::bigint) AS total_rodadas_ia
   FROM diario d
     LEFT JOIN pedidos p ON p.data = d.data
     LEFT JOIN desempenho dp ON dp.data = d.data
  ORDER BY d.data DESC;
