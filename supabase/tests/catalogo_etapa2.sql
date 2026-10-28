-- Testes da Etapa 2: catálogo com SKU (importação em duas fases, histórico, segurança) e SKU obrigatório em orçamento e pedido.
-- Um único bloco que se desfaz no final (nada fica gravado). O resultado SEMPRE aparece como mensagem de erro:
--   "OK: N testes passaram ..." = tudo certo;  "TESTES FALHARAM ..." = lista do que falhou.
-- Como rodar: supabase/tests/rodar-local.sh supabase/tests/catalogo_etapa2.sql   (Postgres local, catálogo fictício)
--   ou cole no SQL Editor do Supabase (usa os itens CFV02 e CFV10 reais; na produção também confere o custo de CFV02 = R$ 75,99).
do $$
declare
  v_falhas text; v_total integer;
  v_dono uuid := gen_random_uuid(); v_atend uuid := gen_random_uuid(); v_estranho uuid := gen_random_uuid();
  v_imp uuid; j jsonb; j2 jsonb; v_n integer; v_msg text; v_ok boolean;
  v_cfv02 record; v_cfv10 record;
  v_contact uuid; v_conv uuid; v_orc uuid; v_ord uuid; v_it uuid; v_texto text;
begin
  create temp table _res (n serial, nome text, ok boolean, detalhe text) on commit drop;
  grant all on _res to public;
  grant all on sequence _res_n_seq to public;
  create or replace function pg_temp.ck(p_nome text, p_ok boolean, p_detalhe text default null) returns void
  language sql as 'insert into _res (nome, ok, detalhe) values (p_nome, coalesce(p_ok, false), p_detalhe)';

  -- pessoas: dono (e-mail do dono), atendente (cadastrado, não é o dono) e um logado qualquer (sem perfil)
  insert into auth.users (id, email) values (v_dono, (select value ->> 'email' from public.app_settings where key = 'owner')), (v_atend, 'atendente@teste.local'), (v_estranho, 'estranho@teste.local');
  insert into public.profiles (id, name, role) values (v_dono, 'Dono', 'admin'), (v_atend, 'Atendente', 'agent');
  select * into v_cfv02 from public.catalogo where sku = 'CFV02';
  select * into v_cfv10 from public.catalogo where sku = 'CFV10';
  perform pg_temp.ck('fixture: CFV02 e CFV10 existem', v_cfv02.id is not null and v_cfv10.id is not null);

  -- ============ estrutura
  perform pg_temp.ck('catalogo tem os campos finais', (select count(*) = 17 from information_schema.columns where table_schema = 'public' and table_name = 'catalogo'
    and column_name in ('sku', 'categoria', 'descricao', 'cores', 'peso_g', 'quantidade', 'tamanho_mm', 'prazo_dias_uteis', 'custo', 'grupo_produto', 'especificacao_normalizada', 'status_venda', 'vendavel', 'permite_desconto', 'cabe_na_bike', 'origem_importacao_id', 'atualizado_em')));
  perform pg_temp.ck('products continua existindo como visão de compatibilidade', (select relkind = 'v' from pg_class where oid = 'public.products'::regclass));
  perform pg_temp.ck('preço base de custo preenchido nas linhas antigas', (select count(*) = 0 from public.catalogo where custo > 0 and (preco_base_custo = 0 or piso is null)));
  perform pg_temp.ck('prazo guardado BRUTO (calcular_prazo não altera o catálogo)', (select prazo_dias_uteis = 2 from public.catalogo where sku = 'CFV02') and (public.calcular_prazo('CFV02') ->> 'ok')::boolean);
  perform pg_temp.ck('sem SKU não pode ser vendável (constraint)', (
    select not exists (select 1 from pg_constraint where conname = 'catalogo_sku_vendavel_check' and not convalidated)));

  -- ============ cabe_na_bike e frete pelo peso do pedido todo
  j := public.verificar_frete('Centro', '[{"sku":"CFV02","quantidade":1}]'::jsonb, 200, false);
  perform pg_temp.ck('um pacote de cartão cabe na bike', (j ->> 'cabe_na_bike')::boolean and (j ->> 'frete_gratis')::boolean, j::text);
  j := public.verificar_frete('Centro', '[{"sku":"CFV02","quantidade":3}]'::jsonb, 400, false);
  perform pg_temp.ck('3 pacotes somam o peso e não cabem (cada um cabe sozinho)', not (j ->> 'cabe_na_bike')::boolean and (j ->> 'motivo') = 'nao_cabe_na_bike', j::text);
  j := public.verificar_frete('Centro', '[{"sku":"IMG01","quantidade":1}]'::jsonb, 400, false);
  perform pg_temp.ck('tamanho 0 x 0 é dimensão desconhecida (sem frete grátis)', (j ->> 'dimensao_desconhecida')::boolean and not (j ->> 'frete_gratis')::boolean, j::text);

  -- ============ importação: duas fases
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_dono::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_dono, 'email', (select value ->> 'email' from public.app_settings where key = 'owner'), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  v_imp := public.catalogo_importacao_iniciar('tabela-teste.pdf', 'catalogo-fornecedor/teste.pdf', 'abc', current_date, 12);
  v_n := public.catalogo_importacao_lote(v_imp, jsonb_build_array(
    jsonb_build_object('n', 1, 'sku', 'TST01', 'categoria', 'CARTÕES DE VISITA', 'descricao', 'PAPEL NOVO - 250g', 'cores', '4X0', 'peso_g', 900, 'quantidade', 500, 'tamanho_mm', '91 x 51', 'prazo', 2, 'custo', 40.00),
    jsonb_build_object('n', 2, 'sku', 'CFV02', 'categoria', v_cfv02.categoria, 'descricao', v_cfv02.descricao, 'cores', v_cfv02.cores, 'peso_g', v_cfv02.peso_g, 'quantidade', v_cfv02.quantidade, 'tamanho_mm', v_cfv02.tamanho_mm, 'prazo', 2, 'custo', 77.00),
    jsonb_build_object('n', 3, 'sku', 'CFV10', 'categoria', v_cfv10.categoria, 'descricao', v_cfv10.descricao, 'cores', v_cfv10.cores, 'peso_g', v_cfv10.peso_g, 'quantidade', v_cfv10.quantidade, 'tamanho_mm', v_cfv10.tamanho_mm, 'prazo', v_cfv10.prazo_dias_uteis, 'custo', v_cfv10.custo),
    jsonb_build_object('n', 4, 'sku', null, 'categoria', 'PDV', 'descricao', 'DISPLAY POLIONDA TESTE', 'cores', '4X0', 'peso_g', 1500, 'quantidade', 10, 'tamanho_mm', '300 x 400', 'prazo', 5, 'custo', 99.90),
    jsonb_build_object('n', 5, 'sku', null, 'categoria', 'PDV', 'descricao', 'DISPLAY POLIONDA TESTE', 'cores', '4X0', 'peso_g', 1500, 'quantidade', 10, 'tamanho_mm', '300 x 400', 'prazo', 5, 'custo', 99.90),
    jsonb_build_object('n', 6, 'sku', 'TST01', 'categoria', 'CARTÕES DE VISITA', 'descricao', 'PAPEL NOVO - 250g', 'cores', '4X0', 'peso_g', 900, 'quantidade', 500, 'tamanho_mm', '91 x 51', 'prazo', 2, 'custo', 40.00),
    jsonb_build_object('n', 7, 'sku', 'TST02', 'categoria', 'CARTÕES DE VISITA', 'descricao', 'PAPEL X', 'cores', '4X0', 'peso_g', 900, 'quantidade', 500, 'tamanho_mm', '91 x 51', 'prazo', 2, 'custo', 41.00),
    jsonb_build_object('n', 8, 'sku', 'TST02', 'categoria', 'CARTÕES DE VISITA', 'descricao', 'PAPEL X', 'cores', '4X0', 'peso_g', 900, 'quantidade', 500, 'tamanho_mm', '91 x 51', 'prazo', 2, 'custo', 45.00),
    jsonb_build_object('n', 9, 'sku', 'TST03', 'categoria', 'ADESIVOS', 'descricao', 'SEM CUSTO', 'cores', '4X0', 'peso_g', 10, 'quantidade', 100, 'tamanho_mm', '50 x 50', 'prazo', 2, 'custo', 0),
    jsonb_build_object('n', 10, 'sku', 'TST04', 'categoria', 'ADESIVOS', 'descricao', '', 'cores', '4X0', 'peso_g', 10, 'quantidade', 100, 'tamanho_mm', '50 x 50', 'prazo', 2, 'custo', 10),
    jsonb_build_object('n', 11, 'sku', 'TST 05', 'categoria', 'ADESIVOS', 'descricao', 'CODIGO COM ESPACO', 'cores', '4X0', 'peso_g', 10, 'quantidade', 100, 'tamanho_mm', '50 x 50', 'prazo', 2, 'custo', 10),
    jsonb_build_object('n', 12, 'sku', 'TST06', 'categoria', 'ADESIVOS', 'descricao', 'SEM PRAZO', 'cores', '4X0', 'peso_g', 10, 'quantidade', 100, 'tamanho_mm', '50 x 50', 'prazo', null, 'custo', 10)));
  perform pg_temp.ck('lote recebeu as 12 linhas', v_n = 12, v_n::text);

  j := public.catalogo_importacao_previa(v_imp, 20);
  perform pg_temp.ck('prévia: lidas = 12 e confere', (j ->> 'lidas')::int = 12 and (j ->> 'confere')::boolean, j::text);
  perform pg_temp.ck('prévia: total do arquivo confere (12 candidatas)', not (j -> 'alertas') ? 'total_nao_confere_com_o_arquivo', j::text);
  perform pg_temp.ck('prévia: 1 nova (TST01), 1 alterada (CFV02), 1 igual (CFV10)', (j ->> 'novas')::int = 1 and (j ->> 'alteradas')::int = 1 and (j ->> 'iguais')::int = 1, j::text);
  perform pg_temp.ck('prévia: 2 sem SKU (1 duplicada igual entre elas)', (j ->> 'sem_sku')::int = 2 and (j ->> 'duplicadas_iguais')::int = 2, j::text);
  perform pg_temp.ck('prévia: SKU repetido com dados diferentes vira conflito, sem sobrescrever', (j ->> 'conflitos')::int = 2 and (j -> 'alertas') ? 'sku_repetido_com_dados_diferentes', j::text);
  perform pg_temp.ck('prévia: rejeitadas com motivo (custo zero, sem descrição, código inválido, sem prazo)', (j ->> 'rejeitadas')::int = 4
    and (select count(*) = 4 and bool_and(motivo is not null) from public.catalogo_import_linhas where importacao_id = v_imp and resultado = 'rejeitada'), j::text);
  perform pg_temp.ck('prévia: nenhuma linha sem destino (soma de tudo = lidas)', (select count(*) = 12 from public.catalogo_import_linhas where importacao_id = v_imp and resultado <> 'pendente'));
  perform pg_temp.ck('prévia: alerta de CFV02 diferente de R$ 75,99', (j -> 'alertas') ? 'cfv02_diverge' and (j ->> 'cfv02_custo')::numeric = 77.00, j::text);
  perform pg_temp.ck('prévia: itens removidos contados e alerta de remoção em massa', (j ->> 'removidos')::int >= 40 and (j -> 'alertas') ? 'muitos_itens_removidos', j::text);
  perform pg_temp.ck('prévia: variação de preço calculada', (select variacao_pct = 1.3 from public.catalogo_import_linhas where importacao_id = v_imp and n = 2), (select variacao_pct::text from public.catalogo_import_linhas where importacao_id = v_imp and n = 2));
  perform pg_temp.ck('prévia: piso muda (1 item com custo alterado)', (j ->> 'pisos_que_mudam')::int = 1, j::text);

  -- alertas graves exigem confirmação do dono
  begin
    perform public.catalogo_importacao_aplicar(v_imp, 1000, false, true);
    v_ok := false; v_msg := 'aplicou sem confirmar';
  exception when others then v_ok := sqlerrm like '%alertas%'; v_msg := sqlerrm;
  end;
  perform pg_temp.ck('aplicar com alertas graves exige confirmação do dono', v_ok, v_msg);
  update public.precos_mercado set invalidado_em = null where sku = 'CFV02';
  insert into public.precos_mercado (sku, chave_especificacao, fonte, preco) values ('CFV02', 'teste', 'teste', 100), ('CFV10', 'teste', 'teste', 100);

  j2 := public.catalogo_importacao_aplicar(v_imp, 1, true, false);
  perform pg_temp.ck('aplica em lotes (1 por vez)', (j2 ->> 'aplicadas')::int = 1 and (j2 ->> 'restantes')::int = 2, j2::text);
  j2 := public.catalogo_importacao_aplicar(v_imp, 1000, true, false);
  perform pg_temp.ck('termina o lote e fecha a importação', (j2 ->> 'restantes')::int = 0 and (select status = 'aplicada' from public.catalogo_importacoes where id = v_imp), j2::text);
  reset role;

  perform pg_temp.ck('novo SKU inserido e vendável', (select vendavel and status_venda = 'vender' and piso > 0 from public.catalogo where sku = 'TST01'));
  perform pg_temp.ck('SKU repetido igual entrou uma vez só', (select count(*) = 1 from public.catalogo where sku = 'TST01'));
  perform pg_temp.ck('SKU em conflito NÃO foi gravado', not exists (select 1 from public.catalogo where sku = 'TST02'));
  perform pg_temp.ck('rejeitadas não foram gravadas', not exists (select 1 from public.catalogo where sku in ('TST03', 'TST04', 'TST 05', 'TST06')));
  perform pg_temp.ck('linha sem código importada como sem_sku, não vendável, uma vez só', (select count(*) = 1 and bool_and(status_venda = 'sem_sku' and not vendavel and sku is null) from public.catalogo where categoria = 'PDV' and descricao = 'DISPLAY POLIONDA TESTE'));
  perform pg_temp.ck('histórico guardou o custo e o prazo anteriores', (select custo_anterior = 75.99 and custo_novo = 77.00 and prazo_anterior = 2 from public.catalogo_historico h join public.catalogo c on c.id = h.catalogo_id where c.sku = 'CFV02' order by h.registrado_em desc limit 1));
  perform pg_temp.ck('piso recalculado para o item alterado', (select custo = 77.00 and piso > 77 from public.catalogo where sku = 'CFV02'));
  perform pg_temp.ck('cache de mercado invalidado só do item que mudou de custo', (select invalidado_em is not null from public.precos_mercado where sku = 'CFV02')
    and (select invalidado_em is null from public.precos_mercado where sku = 'CFV10'));
  perform pg_temp.ck('item igual não gerou histórico', not exists (select 1 from public.catalogo_historico where sku = 'CFV10'));
  perform pg_temp.ck('importação guardou o relatório', (select (relatorio ->> 'lidas')::int = 12 and relatorio ? 'inseridas' from public.catalogo_importacoes where id = v_imp));

  -- reimportar os mesmos dados é idempotente
  perform pg_temp.ck('sem SKU: reimportar não duplica (chave natural)', (
    select count(*) = 1 from public.catalogo where categoria = 'PDV' and sku is null));

  -- vendável é obrigatório para vender
  j := public.calcular_preco(null);
  perform pg_temp.ck('sku nulo não tem preço', not (j ->> 'ok')::boolean, j::text);
  update public.catalogo set status_venda = 'nao_vender' where sku = 'TST01';
  j := public.calcular_preco('TST01');
  perform pg_temp.ck('item nao_vender não é vendável (calcular_preco recusa)', j ->> 'erro' = 'item_nao_vendavel', j::text);
  update public.catalogo set vendavel = true where categoria = 'PDV' and sku is null;
  perform pg_temp.ck('linha sem SKU nunca vira vendável, nem forçando', (select not vendavel and status_venda = 'sem_sku' from public.catalogo where categoria = 'PDV' and sku is null));
  begin
    update public.catalogo set status_venda = 'vender', vendavel = true, sku = null where sku = 'CFV10';
    v_ok := (select not vendavel and status_venda = 'sem_sku' from public.catalogo where id = v_cfv10.id);
  exception when others then v_ok := true;
  end;
  perform pg_temp.ck('tirar o SKU de um item o torna não vendável', v_ok);

  -- ============ segurança: ninguém além do dono lê custo
  set local role anon;
  begin perform count(*) from public.catalogo; v_ok := false; exception when insufficient_privilege then v_ok := true; end;
  perform pg_temp.ck('anon não lê catalogo', v_ok);
  begin perform count(*) from public.products_priced; v_ok := false; exception when insufficient_privilege then v_ok := true; end;
  perform pg_temp.ck('anon não lê products_priced', v_ok);
  begin perform public.buscar_produto('cartao'); v_ok := false; exception when others then v_ok := true; end;
  perform pg_temp.ck('anon não executa buscar_produto', v_ok);
  reset role;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_atend::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_atend, 'email', 'atendente@teste.local', 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform pg_temp.ck('atendente (não dono) não lê catalogo', (select count(*) = 0 from public.catalogo));
  perform pg_temp.ck('atendente não lê products (visão antiga)', (select count(*) = 0 from public.products));
  perform pg_temp.ck('atendente não lê o histórico nem as importações', (select count(*) = 0 from public.catalogo_historico) and (select count(*) = 0 from public.catalogo_importacoes));
  begin perform public.catalogo_importacao_iniciar('x', null, null); v_ok := false; exception when others then v_ok := sqlstate = '42501'; end;
  perform pg_temp.ck('atendente não importa catálogo', v_ok);
  j := public.buscar_produto('cartao de visita', 1000);
  v_texto := lower(j::text);
  perform pg_temp.ck('atendente usa buscar_produto e recebe opções', jsonb_array_length(j -> 'opcoes') between 1 and 5, left(v_texto, 200));
  perform pg_temp.ck('buscar_produto NÃO devolve custo, piso, margem, lucro nem fornecedor', v_texto !~ '(custo|cost|piso|margem|lucro|fornecedor|supplier|chave_natural)', left(v_texto, 300));
  perform pg_temp.ck('buscar_produto devolve só os campos permitidos', not exists (
    select 1 from jsonb_array_elements(j -> 'opcoes') o, jsonb_object_keys(o) k where k not in ('sku', 'descricao_curta', 'quantidade', 'prazo_dias_uteis', 'preco', 'vendavel', 'quantidade_exata')));
  perform pg_temp.ck('buscar_produto traz no máximo 5 opções', jsonb_array_length(j -> 'opcoes') <= 5);
  j2 := public.agente_preco('CFV02', 1);
  perform pg_temp.ck('agente_preco devolve só o preço final', j2 ?& array['preco_total', 'preco_unitario'] and not (j2 ? 'piso') and not (j2 ? 'lucro_liquido') and not (j2 ? 'margem_liquida_pct'), j2::text);
  j2 := public.buscar_produto('CFV02');
  perform pg_temp.ck('atendente não consegue busca direta por SKU (só o dono)', coalesce((j2 ->> 'busca_por_sku')::boolean, false) = false, left(j2::text, 200));
  reset role;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_estranho::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_estranho, 'email', 'estranho@teste.local', 'role', 'authenticated')::text, true);
  begin perform public.buscar_produto('cartao'); v_ok := false; exception when others then v_ok := sqlstate = '42501'; end;
  perform pg_temp.ck('logado sem perfil não executa buscar_produto', v_ok);
  perform pg_temp.ck('logado sem perfil não lê catalogo', (select count(*) = 0 from public.catalogo));
  reset role;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_dono::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_dono, 'email', (select value ->> 'email' from public.app_settings where key = 'owner'), 'role', 'authenticated')::text, true);
  perform pg_temp.ck('dono lê catalogo', (select count(*) > 40 from public.catalogo));
  j := public.buscar_produto('CFV02');
  perform pg_temp.ck('dono faz busca direta por SKU', (j ->> 'busca_por_sku')::boolean, left(j::text, 200));
  reset role;

  -- item sem SKU aparece na busca como orientação (chamar o dono)
  perform set_config('request.jwt.claim.role', 'service_role', true);
  j := public.buscar_produto('display polionda teste');
  perform pg_temp.ck('busca que só acha item sem SKU orienta chamar o dono', (j ->> 'itens_sem_sku_encontrados')::int >= 1 and jsonb_array_length(j -> 'opcoes') = 0 and j ->> 'orientacao' = 'sem_sku_chamar_dono_alta', j::text);

  -- ============ conhecimento: revisão, vetor e variáveis
  perform pg_temp.ck('trechos da carga inicial nascem para revisar', (select count(*) >= 80 and bool_and(revisar) from public.conhecimento where fonte = 'carga inicial da Etapa 2'));
  update public.conhecimento set revisar = false where slug = 'pag-pix';
  perform pg_temp.ck('marcar revisado grava a data', (select not revisar and revisado_em is not null from public.conhecimento where slug = 'pag-pix'));
  update public.conhecimento set fatos = coalesce(fatos, '') || ' Texto novo.' where slug = 'pag-pix';
  perform pg_temp.ck('editar o conteúdo volta a pedir revisão', (select revisar from public.conhecimento where slug = 'pag-pix'));
  update public.conhecimento set fatos = fatos || ' Mais um.', revisar = false where slug = 'pag-pix';
  perform pg_temp.ck('editar e marcar revisado na mesma ação mantém revisado', (select not revisar from public.conhecimento where slug = 'pag-pix'));
  update public.conhecimento set embedding = array_fill(0.1::float4, array[384]) where slug = 'pag-pix';
  update public.conhecimento set resposta_pronta = resposta_pronta || ' Ok?' where slug = 'pag-pix';
  perform pg_temp.ck('editar título, quando usar ou resposta apaga o vetor (reindexação automática refaz)', (select embedding is null from public.conhecimento where slug = 'pag-pix'));
  perform pg_temp.ck('variáveis comerciais resolvidas em tempo de execução', (
    select public.conhecimento_resolver('{{arte_basica}} {{arte_frete}} {{pedido_minimo}} {{validade}}') ~ '^R\$ 39,90 R\$ 49,90 R\$ 150,00 7 dias$'), public.conhecimento_resolver('{{arte_basica}} {{arte_frete}} {{pedido_minimo}} {{validade}}'));
  perform pg_temp.ck('horário resolvido a partir dos parâmetros', public.conhecimento_resolver('{{horario}}') like 'segunda a quinta das 9h às 17h, sexta das 9h às 18h30%', public.conhecimento_resolver('{{horario}}'));
  j := public.buscar_conhecimento('qual o horario de funcionamento', null, 3, null, false);
  perform pg_temp.ck('FAQ responde sem modelo e já com variáveis resolvidas', j ->> 'via' = 'faq' and (j ->> 'resposta_direta') ~ 'segunda a quinta' and (j ->> 'resposta_direta') !~ '\{\{', j::text);
  j := public.buscar_conhecimento('zzxxyy qwerty blablabla', null, 3, v_conv, true);
  perform pg_temp.ck('pergunta sem trecho: encontrou = false, orienta confirmar e chamar o dono (baixa)', not (j ->> 'encontrou')::boolean and j ->> 'orientacao' like '%gravidade_baixa%', j::text);
  perform pg_temp.ck('a pergunta sem resposta vai para conhecimento_lacunas', exists (select 1 from public.conhecimento_lacunas where pergunta_norm like 'zzxxyy%'));
  j := public.buscar_conhecimento('zzxxyy qwerty blablabla', null, 3, v_conv, true);
  perform pg_temp.ck('pergunta repetida soma ocorrências, não duplica', (select ocorrencias = 2 and count(*) over () = 1 from public.conhecimento_lacunas where pergunta_norm like 'zzxxyy%'));
  j := public.buscar_conhecimento('aceita pix', null, 3, null, false);
  perform pg_temp.ck('busca devolve no máximo 3 trechos', jsonb_array_length(j -> 'trechos') <= 3, j::text);
  perform pg_temp.ck('a taxa de acerto conta as consultas', (public.conhecimento_taxa(30) ->> 'consultas')::int >= 2);

  -- ============ SKU obrigatório em orçamento e pedido
  insert into public.contacts (wa_id, name) values ('5531900000099', 'Teste SKU') returning id into v_contact;
  insert into public.conversations (contact_id) values (v_contact) returning id into v_conv;
  insert into public.orcamentos (contact_id, conversation_id) values (v_contact, v_conv) returning id into v_orc;
  begin insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_orc, null, 'sem sku', 1, 100); v_ok := false; exception when others then v_ok := true; end;
  perform pg_temp.ck('orçamento sem SKU falha', v_ok);
  begin insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_orc, 'NAO-EXISTE', 'inexistente', 1, 100); v_ok := false; exception when others then v_ok := true; end;
  perform pg_temp.ck('orçamento com SKU fora do catálogo falha', v_ok);
  begin insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_orc, 'TST01', 'nao vender', 1, 100); v_ok := false; v_msg := ''; exception when others then v_ok := sqlerrm like '%não está disponível%'; v_msg := sqlerrm; end;
  perform pg_temp.ck('orçamento com item não vendável falha', v_ok, v_msg);
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario) values (v_orc, 'CFV02', 'Cartão', 1, (public.calcular_preco('CFV02') ->> 'preco_total')::numeric);
  perform pg_temp.ck('orçamento com SKU válido e preço de calcular_preco entra', exists (select 1 from public.orcamento_itens where orcamento_id = v_orc));

  insert into public.orders (contact_id, conversation_id, title) values (v_contact, v_conv, 'Pedido teste SKU') returning id into v_ord;
  begin insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) values (v_ord, null, 'sem sku', 1, 10, 50); v_ok := false; exception when others then v_ok := sqlerrm like '%sem SKU%'; v_msg := sqlerrm; end;
  perform pg_temp.ck('pedido: item sem SKU falha', v_ok, v_msg);
  begin insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) values (v_ord, 'NAO-EXISTE', 'x', 1, 10, 50); v_ok := false; exception when foreign_key_violation then v_ok := true; end;
  perform pg_temp.ck('pedido: SKU fora do catálogo falha (chave estrangeira)', v_ok);
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price, lead_days) values (v_ord, 'CFV02', 'Cartão de visita', 1, 77, 160, 2);

  -- item legado sem SKU (inserido sem gatilhos, como os registros antigos)
  set local session_replication_role = replica;
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price) values (v_ord, null, 'Item antigo digitado à mão', 1, 5, 30) returning id into v_it;
  set local session_replication_role = origin;
  update public.orders set payment_status = 'aprovado', payment_confirmed_at = now() where id = v_ord;
  update public.orders set stage = 'pago' where id = v_ord;
  perform pg_temp.ck('pagamento confirmado nunca é bloqueado, mas pedido pago com item sem SKU alerta o dono (gravidade alta)',
    (select stage = 'pago' from public.orders where id = v_ord) and exists (select 1 from public.alertas where order_id = v_ord and tipo = 'item_sem_sku' and gravidade = 'alta'));
  update public.orders set art_status = 'aprovada' where id = v_ord;
  begin update public.orders set stage = 'producao' where id = v_ord; v_ok := false; v_msg := 'moveu'; exception when others then v_ok := sqlerrm like '%sem SKU%'; v_msg := sqlerrm; end;
  perform pg_temp.ck('Produção é recusada com item sem SKU', v_ok, v_msg);
  j := public.pedido_para_fabrica(v_ord);
  perform pg_temp.ck('Pedido para a fábrica lista todos os SKUs e avisa os itens sem SKU', jsonb_array_length(j -> 'itens') = 2 and (j ->> 'itens_sem_sku')::int = 1 and (j -> 'itens' -> 0 ->> 'sku') = 'CFV02', j::text);
  delete from public.order_items where id = v_it;
  update public.orders set stage = 'producao' where id = v_ord;
  perform pg_temp.ck('sem item sem SKU, Produção é liberada', (select stage = 'producao' from public.orders where id = v_ord));

  -- item fora do catálogo: registra e chama o dono (alta)
  delete from public.alertas where conversation_id = v_conv;
  j := public.registrar_item_sem_sku(v_conv, 'Porta-cartão de acrílico', 50, '{"obs":"cliente pediu"}');
  perform pg_temp.ck('registrar_item_sem_sku cria alerta alto e orienta não montar orçamento', (j ->> 'dono_avisado')::boolean and j ->> 'orientacao' = 'nao_montar_orcamento_nem_enviar_link'
    and exists (select 1 from public.itens_fora_catalogo where conversation_id = v_conv and status = 'sem_sku'), j::text);
  j := public.registrar_item_sem_sku(v_conv, 'Porta-cartão de acrílico', 50);
  perform pg_temp.ck('mesmo alerta na mesma conversa só uma vez em 30 minutos', not (j ->> 'dono_avisado')::boolean, j::text);

  select string_agg(format('%s (%s)', nome, coalesce(detalhe, '')), E'\n  ') into v_falhas from _res where not ok;
  select count(*) into v_total from _res;
  if v_falhas is not null then raise exception E'TESTES FALHARAM (% de %):\n  %', (select count(*) from _res where not ok), v_total, v_falhas; end if;
  raise exception 'OK: % testes passaram (o bloco desfaz tudo; nada ficou gravado)', v_total;
end $$;
