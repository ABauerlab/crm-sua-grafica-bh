-- Corrige "function public.agente_saida_base(uuid, text) is not unique":
-- existiam duas funções com o mesmo nome, (uuid, text) e (uuid, text, numeric[] DEFAULT '{}'),
-- e a chamada de 2 argumentos dentro de agente_saida_segura ficava ambígua, bloqueando toda resposta do agente.
-- A versão de 3 argumentos (validador por conversa) é mantida como está.
-- A de 2 argumentos (validador por execução) ganha nome próprio e o wrapper passa a chamá-la.

do $$
declare
  v_def text;
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'agente_saida_base' and p.pronargs = 2
  ) then
    alter function public.agente_saida_base(uuid, text) rename to agente_saida_base_execucao;
  end if;

  select pg_get_functiondef('public.agente_saida_segura(uuid,text)'::regprocedure) into v_def;
  v_def := replace(v_def, 'public.agente_saida_base(', 'public.agente_saida_base_execucao(');
  execute v_def;
end
$$;
