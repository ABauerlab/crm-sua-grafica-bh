-- Etapa 8: followup_reservar, followup_montar e fu_agendar_pos usam extensions.unaccent, que não estava instalada em produção
-- (WF6 falhava a cada 15 minutos). Reverter: drop extension unaccent (derruba o follow-up).
create extension if not exists unaccent with schema extensions;
