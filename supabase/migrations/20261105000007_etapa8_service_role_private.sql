-- Etapa 8: n8n e Edge Functions (service_role) chamam funções públicas (verificar_frete, calcular_preco...) que usam o schema private.
-- Sem USAGE: "permission denied for schema private" (verificar_frete falhou na primeira conversa real).
-- service_role é papel de servidor, nunca exposto ao front. Reverter: revoke usage on schema private from service_role; revoke execute on all functions in schema private from service_role.
grant usage on schema private to service_role;
grant execute on all functions in schema private to service_role;
