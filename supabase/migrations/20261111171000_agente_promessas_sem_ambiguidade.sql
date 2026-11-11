-- Mesmo problema da migration anterior, agora em agente_promessas_indevidas:
-- (uuid, text) por execução e (uuid, text, text[] DEFAULT, text[] DEFAULT) por conversa.
-- A chamada de 2 argumentos em agente_saida_segura ficava ambígua ("is not unique").
-- A versão por conversa é mantida; a por execução ganha nome próprio e o wrapper passa a chamá-la.

do $$
declare
  v_def text;
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'agente_promessas_indevidas' and p.pronargs = 2
  ) then
    alter function public.agente_promessas_indevidas(uuid, text) rename to agente_promessas_indevidas_execucao;
  end if;

  select pg_get_functiondef('public.agente_saida_segura(uuid,text)'::regprocedure) into v_def;
  v_def := replace(v_def, 'public.agente_promessas_indevidas(', 'public.agente_promessas_indevidas_execucao(');
  execute v_def;
end
$$;
