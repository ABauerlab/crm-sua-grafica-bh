-- A carga inicial da planilha terminou: as funções de carga deixam de ser executáveis por anon
-- (eram liberadas só com token temporário). Daqui em diante: dono logado no CRM ou service role.
revoke execute on function public.importar_precos_planilha(jsonb, text) from anon;
revoke execute on function public.aplicar_planilha_precos(text) from anon;
revoke execute on function public.aplicar_planilha_precos_lote(text, integer, text) from anon;
