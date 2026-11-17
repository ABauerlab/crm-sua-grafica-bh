-- Falha leve do agente e trava de saída não geram alerta (só agent_logs); o vigia de silêncio avisa apenas
-- depois de 15 minutos sem resposta. Aplicada pelo conector (marcas: falha_silenciosa, vigia_15min).
select 1;
