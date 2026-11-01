-- Etapa 5 (achado nos cenários reais): o Gemini 3 às vezes devolve como "resposta" o texto cru de uma chamada de ferramenta
-- ("Calling tools: ...", "control_token:default_api..."). A trava de saída passa a bloquear isso (sai a frase neutra e o dono é alertado).
-- Aditiva e idempotente: a função anterior vira agente_saida_base e a agente_saida_segura passa a envolvê-la.
do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'agente_saida_base') then
    alter function public.agente_saida_segura(uuid, text) rename to agente_saida_base;
  end if;
end $$;

create or replace function public.agente_saida_segura(p_execucao uuid, p_texto text) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  r jsonb := public.agente_saida_base(p_execucao, p_texto);
begin
  if coalesce(p_texto, '') ~* '(calling tools?\s*:|control_token|default_api|\mcall_[0-9]{4,}|tool_call)' then
    r := jsonb_set(r, '{ok}', 'false'::jsonb);
    r := jsonb_set(r, '{motivos}', coalesce(r -> 'motivos', '[]'::jsonb) || '"vazamento:chamada_de_ferramenta"'::jsonb);
  end if;
  return r;
end;
$$;

revoke execute on function public.agente_saida_base(uuid, text) from public, anon, authenticated;
grant execute on function public.agente_saida_base(uuid, text) to service_role;
revoke execute on function public.agente_saida_segura(uuid, text) from public, anon, authenticated;
grant execute on function public.agente_saida_segura(uuid, text) to service_role;
