-- Etapa 4 (origem do cliente): roda no banco REAL e desfaz tudo no fim (a transação termina em exceção com o resultado).
-- Não usa Gemini. Esperado: 1_tem_diretriz true, 2_perguntada true, 2_perguntar_depois false, 4_declarada indicacao (fonte laura),
-- 5_continua indicacao, 6_perguntar false, 6_tem_diretriz false; e na leitura por texto: a_sem_palavra null, b_declarada instagram (fonte texto),
-- c_terceira_resposta_ignorada null.
do $$
declare v_ct uuid; v_cv uuid; r jsonb := '{}'::jsonb; ctx jsonb; x record;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select c.id, v.id into v_ct, v_cv from public.contacts c join public.conversations v on v.contact_id = c.id
   where (private.origem_contexto(c.id) ->> 'perguntar')::boolean limit 1;
  if v_ct is null then raise exception 'SEM ELEGIVEL'; end if;
  ctx := public.agente_contexto(v_cv);
  r := r || jsonb_build_object('1_tem_diretriz', (ctx #> '{regras_comerciais,diretrizes_closer}') ? 'origem_do_cliente');
  insert into public.messages (conversation_id, direction, type, body, created_at) values (v_cv, 'out', 'text', 'E só pra eu saber, como você conheceu a Sua Gráfica?', now() - interval '2 minutes');
  r := r || jsonb_build_object('2_perguntada', (select origem_perguntada_em is not null from public.contacts where id = v_ct),
                               '2_perguntar_depois', (private.origem_contexto(v_ct) ->> 'perguntar'));
  insert into public.messages (conversation_id, direction, type, body, created_at) values (v_cv, 'in', 'text', 'Bom dia, pode ser', now() - interval '90 seconds');
  select origem_declarada into x from public.contacts where id = v_ct;
  r := r || jsonb_build_object('a_sem_palavra', x.origem_declarada);
  insert into public.messages (conversation_id, direction, type, body, created_at) values (v_cv, 'in', 'text', 'Vi vocês no Instagram', now() - interval '60 seconds');
  select origem_declarada, origem_fonte into x from public.contacts where id = v_ct;
  r := r || jsonb_build_object('b_declarada', x.origem_declarada, 'b_fonte', x.origem_fonte);
  perform public.agente_salvar_contato(v_ct, '{"origem":"indicação","origem_detalhe":"Maria"}'::jsonb);
  select origem_declarada, origem_fonte into x from public.contacts where id = v_ct;
  r := r || jsonb_build_object('4_declarada', x.origem_declarada, '4_fonte', x.origem_fonte);
  perform public.agente_salvar_contato(v_ct, '{"origem":"google"}'::jsonb);
  r := r || jsonb_build_object('5_continua', (select origem_declarada from public.contacts where id = v_ct));
  ctx := public.agente_contexto(v_cv);
  r := r || jsonb_build_object('6_perguntar', ctx #> '{contato,origem,perguntar}', '6_tem_diretriz', (ctx #> '{regras_comerciais,diretrizes_closer}') ? 'origem_do_cliente');
  raise exception 'RESULTADO: %', r::text;
end $$;
