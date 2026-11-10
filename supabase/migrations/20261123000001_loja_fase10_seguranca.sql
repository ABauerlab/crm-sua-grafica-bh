-- E-commerce Fase 10: varredura de segurança. Aditiva e idempotente.
-- calcular_acabamento_seguro (SECURITY DEFINER) devolvia dias e CUSTO adicional de acabamento para qualquer chamador com a
-- chave pública. Nada a usa (ver docs/agente/progresso.md); fica só para a service role.
revoke all on function public.calcular_acabamento_seguro(text, text) from public, anon, authenticated;
grant execute on function public.calcular_acabamento_seguro(text, text) to service_role;
