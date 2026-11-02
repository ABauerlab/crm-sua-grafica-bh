-- Etapa 8C: o link de pagamento só sai depois que o cliente aprova DEPOIS do PDF. Tudo é desfeito no fim (exception).
-- Rode no SQL do Supabase como postgres. Esperado: o erro final "OK: ..." (a exceção desfaz os dados de teste).
do $$
declare c uuid; s text; o jsonb; oid uuid; r1 jsonb; r2 jsonb;
begin
  select sku into s from public.catalogo where coalesce(status_venda, '') not in ('bloqueado', 'nao_vender') order by sku limit 1;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';
  perform public.ingest_inbound_message('55000099991', 'TESTE_link', 'wamid.e2e.link.1', 'text', 'quero cartoes', null, now() - interval '10 minutes', null);
  select id into c from public.contacts where wa_id = '55000099991';
  update public.contacts set is_teste = true where id = c;
  o := public.montar_orcamento(c, jsonb_build_array(jsonb_build_object('sku', s, 'quantidade', 1)), '{"teste": true}'::jsonb);
  oid := (o ->> 'orcamento_id')::uuid;
  update public.orcamentos set pdf_enviado_em = now() - interval '2 minutes', status = 'enviado' where id = oid;
  r1 := public.preparar_link_pagamento(oid);
  if r1 ->> 'motivo' is distinct from 'aprovacao_do_cliente_pendente' then raise exception 'FALHA: sem aprovação deveria bloquear, veio %', r1; end if;
  perform public.ingest_inbound_message('55000099991', 'TESTE_link', 'wamid.e2e.link.2', 'text', 'APROVADO', null, now(), null);
  r2 := public.preparar_link_pagamento(oid);
  if not coalesce((r2 ->> 'ok')::boolean, false) then raise exception 'FALHA: com aprovação deveria liberar, veio %', r2; end if;
  raise exception 'OK: link bloqueado sem aprovação e liberado depois de APROVADO';
end $$;
