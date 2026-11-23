-- Teste de 14 dias do toque de anúncio (F2_AD3H): roda no banco REAL e desfaz tudo no fim (a transação termina em exceção com o resultado).
-- Sem Gemini e sem enviar nada. Esperado: 0_teste_ativo true; 1_agendados >= 0; cada linha de 2_linhas é F2_AD3H com orçamento ou pedido;
-- 3_montar acao 'enviar', via 'livre', texto com número do orçamento, quantidade, valor e validade, terminando em pergunta;
-- 4_f2_template (com um template simulado como APROVADO e UTILITY) usa template 'orcamento_lembrete_pedido' com 6 parâmetros.
do $$
declare r jsonb := '{}'::jsonb; v_n integer; m jsonb; v_id uuid; v_f2 uuid;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  r := r || jsonb_build_object('0_teste_ativo', private.fu_teste_ad() is not null);
  v_n := private.fu_agendar_ad3h(now());
  r := r || jsonb_build_object('1_agendados', v_n);
  select jsonb_agg(jsonb_build_object('regra', f.regra_codigo, 'quando', f.agendado_para::timestamp(0), 'com_orc', f.orcamento_id is not null, 'com_pedido', f.order_id is not null))
    into m from public.followup_fila f where f.regra_codigo = 'F2_AD3H' and f.criado_em > now() - interval '1 minute';
  r := r || jsonb_build_object('2_linhas', m);
  select f.id into v_id from public.followup_fila f where f.regra_codigo = 'F2_AD3H' order by f.criado_em desc limit 1;
  if v_id is not null then r := r || jsonb_build_object('3_montar', public.followup_montar(v_id, now())); end if;
  insert into public.templates_cache (name, language, category, status, body) values ('orcamento_lembrete_pedido', 'pt_BR', 'UTILITY', 'APPROVED', 'teste')
    on conflict (name, language) do update set status = 'APPROVED', category = 'UTILITY';
  select f.id into v_f2 from public.followup_fila f where f.regra_codigo = 'F2' and f.orcamento_id is not null order by f.criado_em desc limit 1;
  if v_f2 is not null then r := r || jsonb_build_object('4_f2_template', (public.followup_montar(v_f2, now() + interval '30 hours')) - 'texto'); end if;
  raise exception 'RESULTADO: %', r::text;
end $$;
