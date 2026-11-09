-- Blog: "papel" sozinho pegava "o papel do Brasil..."; troca por termos de papel gráfico.
update public.app_settings
   set value = jsonb_set(value, '{termos_setor}',
         (select jsonb_agg(t) from jsonb_array_elements_text(value -> 'termos_setor') t where t <> 'papel')
         || '["papelcartao", "papel couche", "papel kraft", "papel reciclado"]'::jsonb)
 where key = 'blog' and value -> 'termos_setor' ? 'papel';
