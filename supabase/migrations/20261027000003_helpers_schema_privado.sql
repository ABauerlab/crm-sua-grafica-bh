-- Advisor: funções SECURITY DEFINER no schema public ficam expostas via /rest/v1/rpc.
-- Movê-las para um schema não exposto mantém as políticas de RLS funcionando.
create schema if not exists private;
grant usage on schema private to authenticated;

alter function public.is_staff() set schema private;
alter function public.is_admin() set schema private;
