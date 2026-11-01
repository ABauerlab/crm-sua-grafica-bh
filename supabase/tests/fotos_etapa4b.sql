-- Testes da Etapa 4B: fotos de produto (resolver grupo, cache de 30 dias, limites, bloqueio de marca, sigilo da origem).
-- Como rodar: supabase/tests/rodar-local.sh supabase/tests/fotos_etapa4b.sql
-- "OK: N testes passaram" = tudo certo; "TESTES FALHARAM" = lista do que falhou. Tudo é desfeito no final.
do $$
declare
  v_relatorio text; v_falhas text; v_total integer;
  v_staff uuid := gen_random_uuid(); v_c uuid; v_conv uuid; j jsonb; v_f1 uuid; v_f2 uuid; v_txt text;
begin
  create temp table _res (n serial, nome text, ok boolean, detalhe text) on commit drop;
  create or replace function pg_temp.ck(p_nome text, p_ok boolean, p_detalhe text default null) returns void
  language sql as 'insert into _res (nome, ok, detalhe) values (p_nome, coalesce(p_ok, false), p_detalhe)';
  create or replace function pg_temp.erro(p_sql text) returns text language plpgsql as
  $f$ begin execute p_sql; return null; exception when others then return sqlerrm; end $f$;

  insert into auth.users (id, email) values (v_staff, 'dono@teste.local');
  insert into public.profiles (id, name, role) values (v_staff, 'Dono Teste', 'admin');
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform public.sinonimos_carregar_categorias();
  insert into public.contacts (wa_id, name) values ('5531900009000', 'Cliente Foto') returning id into v_c;
  insert into public.conversations (contact_id) values (v_c) returning id into v_conv;

  -- 1. resolver o grupo
  j := public.foto_resolver_grupo('CFV10');
  perform pg_temp.ck('resolve pelo SKU', j ->> 'grupo' = 'CARTÕES DE VISITA' and (j ->> 'exato_por_sku')::boolean, j::text);
  j := public.foto_resolver_grupo('quero ver foto de panfleto');
  perform pg_temp.ck('resolve pelo termo (sinônimo)', j ->> 'grupo' = 'PANFLETOS, FLYERS E FOLHETOS', j::text);
  j := public.foto_resolver_grupo('xyzabc inexistente');
  perform pg_temp.ck('termo desconhecido não inventa grupo', not (j ->> 'ok')::boolean, j::text);
  perform pg_temp.ck('a resposta do resolvedor não traz origem', public.foto_resolver_grupo('CFV10')::text !~* 'url_origem|http');

  -- 2. cache de 30 dias
  j := public.foto_estado_grupo('ADESIVOS');
  perform pg_temp.ck('grupo novo não está no cache', not (j ->> 'fresco')::boolean and (j ->> 'aprovadas')::int = 0, j::text);
  v_f1 := public.foto_registrar('ADESIVOS', 'https://origem.interna/x/1.jpg', 'ab/abcdef.jpg', 1000, 1000, 100000, 'abcdef', true, 0);
  v_f2 := public.foto_registrar('ADESIVOS', 'https://origem.interna/x/2.jpg', 'cd/cdef01.jpg', 1000, 800, 90000, 'cdef01', false, 1);
  perform pg_temp.ck('mesma imagem (hash) não duplica', public.foto_registrar('ADESIVOS', 'https://origem.interna/x/1.jpg', 'ab/abcdef.jpg', 1000, 1000, 100000, 'abcdef', true, 0) = v_f1);
  perform pg_temp.ck('foto nasce pendente e não é enviada', (select status from public.produto_fotos where id = v_f1) = 'pendente' and public.foto_aprovadas('ADESIVOS', 3) = '[]'::jsonb);
  perform public.foto_decidir(v_f1, 'aprovada');
  perform public.foto_decidir(v_f2, 'bloqueada', 'logotipo visível');
  perform pg_temp.ck('bloqueada marca revisar', (select revisar from public.produto_fotos where id = v_f2));
  j := public.foto_aprovadas('ADESIVOS', 3);
  perform pg_temp.ck('só aprovadas saem', jsonb_array_length(j) = 1 and j -> 0 ->> 'arquivo' = 'ab/abcdef.jpg', j::text);
  perform pg_temp.ck('aprovadas não trazem url de origem', j::text !~* 'origem|http');
  perform public.foto_fechar_busca('ADESIVOS', 'ok');
  perform pg_temp.ck('depois da busca o grupo fica fresco por 30 dias', (public.foto_estado_grupo('ADESIVOS') ->> 'fresco')::boolean
    and (select expira_em from public.produto_fotos_grupos where grupo_produto = 'ADESIVOS') > now() + interval '29 days');
  perform public.foto_fechar_busca('POSTAIS', 'erro', 'site fora do ar');
  perform pg_temp.ck('erro de rede tenta de novo em 1 hora, não em 30 dias', (select expira_em from public.produto_fotos_grupos where grupo_produto = 'POSTAIS') < now() + interval '2 hours');
  perform public.foto_fechar_busca('BANDEIRAS', 'sem_foto');
  perform pg_temp.ck('sem foto fica no cache (não consulta a origem de novo)', (public.foto_estado_grupo('BANDEIRAS') ->> 'fresco')::boolean);

  -- 3. limites
  perform public.foto_registrar_envio(v_conv, v_c, 'ADESIVOS', 3, 250000, 'cache', 'enviada');
  j := public.foto_limites(v_conv, v_c);
  perform pg_temp.ck('limites contam pedido no último minuto e imagens do dia', (j ->> 'pedidos_ultimo_minuto')::int = 1 and (j ->> 'imagens_hoje')::int = 3, j::text);
  perform public.foto_registrar_envio(v_conv, v_c, 'ADESIVOS', 0, 0, 'cache', 'muito_rapido');
  perform pg_temp.ck('pedido recusado não conta como envio', (public.foto_limites(v_conv, v_c) ->> 'imagens_hoje')::int = 3);
  perform pg_temp.ck('log do agente sem origem', not exists (select 1 from public.agent_logs where ferramenta = 'enviar_foto_produto' and (detail::text ~* 'http|origem')));
  perform pg_temp.ck('log do agente registra grupo, quantidade, bytes e via', exists (select 1 from public.agent_logs where ferramenta = 'enviar_foto_produto' and detail ->> 'grupo' = 'ADESIVOS' and detail ->> 'via' = 'cache' and (detail ->> 'bytes')::int = 250000));

  -- 4. segurança
  perform pg_temp.ck('bucket de fotos é privado', (select coalesce(bool_and(not public), false) from storage.buckets where id = 'produto-fotos'));
  perform pg_temp.ck('anon não lê produto_fotos', not has_table_privilege('anon', 'public.produto_fotos', 'select'));
  perform pg_temp.ck('anon não executa foto_aprovadas', not has_function_privilege('anon', 'public.foto_aprovadas(text, integer, text)', 'execute'));
  perform pg_temp.ck('RLS ligada nas 3 tabelas', (select bool_and(relrowsecurity) from pg_class where oid in ('public.produto_fotos'::regclass, 'public.produto_fotos_grupos'::regclass, 'public.produto_fotos_envios'::regclass)));
  perform pg_temp.ck('configuração nasce sem origem no repositório', (select value ->> 'origem_base' from public.app_settings where key = 'fotos') = '');
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
  perform pg_temp.ck('quem não é do time não aprova foto', pg_temp.erro(format('select public.foto_decidir(%L, ''aprovada'')', v_f2)) ~* 'só o dono');
  perform pg_temp.ck('quem não é do time não vê o painel', pg_temp.erro('select * from public.fotos_painel()') ~* 'só o dono');
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  perform pg_temp.ck('painel lista os grupos do catálogo', (select count(*) from public.fotos_painel() where false) = 0);

  -- 5. mapa código -> imagem, candidatas e cobertura
  perform pg_temp.ck('grava lote do mapa e liga ao grupo do catálogo pelo SKU', public.foto_mapa_gravar('[
    {"codigo":"adv01","topo":"black-friday","caminho":"black-friday/adesivos/x/ADV01","imagem":"G-BF-1"},
    {"codigo":"ADV01","topo":"adesivos","caminho":"adesivos/vinil-brilho/redondo/ADV01","imagem":"G-REG-1"},
    {"codigo":"ADV02","topo":"adesivos","caminho":"adesivos/vinil-fosco/quadrado/ADV02","imagem":"G-REG-2"},
    {"codigo":"PFL01","topo":"panfletos","caminho":"panfletos/couche/A5/PFL01","imagem":"G-PF-1"},
    {"codigo":"","topo":"x","caminho":"x","imagem":"G"}]'::jsonb) >= 3);
  perform pg_temp.ck('categoria regular vence a promocional para o mesmo SKU', (select imagem from public.produto_fotos_mapa where sku = 'ADV01') = 'G-REG-1');
  perform public.foto_mapa_gravar('[{"codigo":"ADV01","topo":"black-friday","caminho":"black-friday/adesivos/x/ADV01","imagem":"G-BF-2"}]'::jsonb);
  perform pg_temp.ck('promocional depois não troca o regular', (select imagem from public.produto_fotos_mapa where sku = 'ADV01') = 'G-REG-1');
  perform pg_temp.ck('SKU entra em maiúsculas e com grupo', (select grupo_produto from public.produto_fotos_mapa where sku = 'ADV01') = 'ADESIVOS');
  j := public.foto_candidatas('ADESIVOS', 'ADV02', 'adesivo quadrado', 8);
  perform pg_temp.ck('candidata do SKU exato vem primeiro', j -> 0 ->> 'imagem' = 'G-REG-2' and (j -> 0 ->> 'exato')::boolean, j::text);
  j := public.foto_candidatas('ADESIVOS', null, 'vinil brilho', 8);
  perform pg_temp.ck('sem SKU, o termo ordena', j -> 0 ->> 'imagem' = 'G-REG-1', j::text);
  perform pg_temp.ck('candidatas só do grupo pedido', not (public.foto_candidatas('ADESIVOS', null, null, 20)::text like '%G-PF-1%'));
  perform pg_temp.ck('cobertura por grupo lista os SKUs sem imagem', (select skus_com_imagem from public.fotos_cobertura() where grupo_produto = 'ADESIVOS') = 2
    and (select skus from public.fotos_cobertura() where grupo_produto = 'ADESIVOS') >= 2);
  perform pg_temp.ck('SKUs sem imagem são listados', exists (select 1 from public.fotos_skus_sem_imagem('CARTÕES DE VISITA')) and not exists (select 1 from public.fotos_skus_sem_imagem('ADESIVOS') where sku in ('ADV01','ADV02')));
  v_f1 := public.foto_registrar('ADESIVOS', 'https://origem.interna/x/9.jpg', 'ee/ee01.jpg', 640, 540, 30000, 'ee01', false, 0, true, 'site', 'adv02');
  perform public.foto_decidir(v_f1, 'aprovada');
  j := public.foto_aprovadas('ADESIVOS', 3, 'ADV02');
  perform pg_temp.ck('foto do SKU exato sai primeiro e sem aviso de ilustrativa', j -> 0 ->> 'arquivo' = 'ee/ee01.jpg' and not (j -> 0 ->> 'aproximada')::boolean, j::text);
  perform pg_temp.ck('foto de outro SKU do grupo sai como ilustrativa', (public.foto_aprovadas('ADESIVOS', 3, 'ADV01') -> 0 ->> 'aproximada')::boolean);
  perform pg_temp.ck('baixa qualidade fica marcada', (public.foto_aprovadas('ADESIVOS', 3, 'ADV02') -> 0 ->> 'baixa_qualidade')::boolean);
  perform pg_temp.ck('mapa é privado ao dono', not has_table_privilege('anon', 'public.produto_fotos_mapa', 'select'));

  select count(*), string_agg(format('%s %s%s', case when ok then 'OK    ' else 'FALHA ' end, nome, case when ok then '' else ' => ' || coalesce(detalhe, '') end), E'\n' order by n),
         string_agg(nome || ' => ' || coalesce(detalhe, ''), E'\n' order by n) filter (where not ok)
    into v_total, v_relatorio, v_falhas from _res;
  if v_falhas is not null then
    raise exception E'TESTES FALHARAM (nada foi gravado):\n%\n\nRelatório completo:\n%', v_falhas, v_relatorio;
  end if;
  raise exception E'OK: % testes passaram. Esta mensagem de erro é proposital, desfaz tudo o que o teste criou (nada foi gravado).\n%', v_total, v_relatorio;
end $$;
