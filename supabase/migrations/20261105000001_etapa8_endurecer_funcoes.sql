-- Etapa 8 (auditoria): endurecimento achado pelos advisors. Aditiva e reversível.
-- Reverter: grant execute on function public.rls_auto_enable() to anon, authenticated, public;
--           alter function public.atualizar_orcamento_atualizado_em() reset search_path;
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
alter function public.atualizar_orcamento_atualizado_em() set search_path = '';
