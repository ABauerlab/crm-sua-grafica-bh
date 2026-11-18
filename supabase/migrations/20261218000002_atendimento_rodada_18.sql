-- Rodada 18/11/2026 (diário do tráfego pago de 17/11): G1 a G7. Tudo aplicado pelo conector em partes (nomes das migrations no histórico:
-- followups_recusa_vale_para_orcamento, fiscal_extrair_de_mensagem_do_cliente, fiscal_extrair_corrige_variaveis, fiscal_completar_endereco_pelo_cep,
-- fechamento_intencao_de_pagamento_e_condicao_fora_do_padrao, condicao_fora_padrao_evita_medida, saida_segura_promessas_nf_e_repeticao,
-- saida_travas_extra_corrige_array, buscar_produto_sem_opcoes_repetidas_por_orientacao, limite_de_ferramentas_por_rodada).
-- Este arquivo reúne o estado final, é idempotente e aditivo.

-- ====================================================================================================================
-- G1: recusa explícita também encerra os lembretes F1 a F4 e impede reativação do orçamento recusado
-- ====================================================================================================================
do $m$
declare
  d text; n text;
  rx text := $q$(n[aã]o,? *(n[aã]o|obrigad[oa]|valeu)|^\W*obrigad[oa]\W*$|^\W*valeu\W*$|n[aã]o (quero|preciso|tenho interesse|faz sentido|vou (querer|seguir|fechar|precisar))|sem interesse|deixa (pra l[aá]|quieto|assim)|desist|j[aá] (fechei|resolvi|comprei|contratei)|era s[oó] isso|por enquanto n[aã]o|n[aã]o por enquanto|talvez (depois|mais pra frente)|fica (pra|para) (depois|outra vez)|j[aá] tenho (gr[aá]fica|fornecedor)|n[aã]o,? obrigad)$q$;
  a1 text := $q$then v_motivo := 'cliente_recusou'; /* cliente_recusou */$q$;
  b1 text := $q$and not exists (select 1 from public.orders x where x.contact_id = oc.contact_id and x.excluido_em is null and x.payment_status = 'aprovado'$q$;
begin
  select pg_get_functiondef('public.followup_reservar(text,integer,timestamptz)'::regprocedure) into d;
  if position('f_recusou' in d) = 0 then
    if position(a1 in d) = 0 then raise exception 'âncora cliente_recusou não encontrada'; end if;
    n := replace(d, a1, a1 || $q$
    elsif v_cadencia and f.regra_codigo ~ '^F[1-4]$' and exists (
        select 1 from (select m.body from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.body is not null and m.deleted_at is null order by m.created_at desc limit 2) z
         where z.body ~* '$q$ || rx || $q$') then v_motivo := 'cliente_recusou'; /* f_recusou */$q$);
    execute n;
  end if;
  select pg_get_functiondef('private.followup_orcamentos_abertos(timestamptz)'::regprocedure) into d;
  if position('f_recusou' in d) = 0 then
    if position(b1 in d) = 0 then raise exception 'âncora do orçamento aberto não encontrada'; end if;
    n := replace(d, b1, $q$and not exists (select 1 from (select m.body from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.body is not null and m.deleted_at is null order by m.created_at desc limit 2) z where z.body ~* '$q$ || rx || $q$') /* f_recusou */
       $q$ || b1);
    execute n;
  end if;
end
$m$;

-- ====================================================================================================================
-- G3: dados fiscais enviados pelo cliente depois de pago (inclusive em modo humano) são salvos pelo banco
-- ====================================================================================================================
create or replace function private.fiscal_extrair(p_msg uuid) returns text[]
language plpgsql security definer set search_path = '' as $f$
declare
  m record; c public.contacts%rowtype; t text; v_doc text; v_cep text; v_mail text; v_num text; v_nome text; v_f text[] := '{}'; v_cache record; v_primeira text;
begin
  select ms.body, ms.direction, cv.contact_id, cv.id as conv into m
    from public.messages ms join public.conversations cv on cv.id = ms.conversation_id where ms.id = p_msg;
  if m.contact_id is null or m.direction <> 'in' or coalesce(m.body, '') = '' or length(m.body) > 1500 then return v_f; end if;
  if not exists (select 1 from public.orders o where o.contact_id = m.contact_id and o.excluido_em is null and o.cancelado_em is null and coalesce(o.teste, false) = false
                   and (o.payment_status = 'aprovado' or o.payment_manual) and coalesce(o.paid_at, o.created_at) > now() - interval '30 days') then
    return v_f;
  end if;
  t := m.body;
  v_doc := (regexp_match(t, '(\d{2}\.\d{3}\.\d{3}/\d{4}-\d{2}|\d{3}\.\d{3}\.\d{3}[-.]\d{2})'))[1];
  if v_doc is null and t ~* '(cpf|cnpj)' then v_doc := (regexp_match(regexp_replace(t, '[.\-/\s]', '', 'g'), '(\d{14}|\d{11})'))[1]; end if;
  if v_doc is not null then v_doc := regexp_replace(v_doc, '\D', '', 'g'); if length(v_doc) not in (11, 14) then v_doc := null; end if; end if;
  v_cep := coalesce((regexp_match(t, '(?:cep|cp)\W{0,3}(\d{5}-?\d{3})(?!\d)', 'i'))[1], (regexp_match(t, '(?<!\d)(\d{5}-\d{3})(?!\d)'))[1]);
  if v_cep is not null then v_cep := regexp_replace(v_cep, '\D', '', 'g'); end if;
  v_mail := lower((regexp_match(t, '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'))[1]);
  v_num := coalesce((regexp_match(t, '(?:n[úu]mero|n[º°o]\.?)\s*[:.]?\s*(\d{1,5}[A-Za-z]?)(?![\d])', 'i'))[1],
                    (regexp_match(t, '(?:rua|r\.|av\.?|avenida|travessa|alameda|pra[cç]a|estrada|rodovia)\s+[^\d\n,;]{2,60}?[\s,]+(?:n[º°o.]*\s*)?(\d{1,5}[A-Za-z]?)(?![\d])', 'i'))[1]);
  v_primeira := btrim(split_part(t, E'\n', 1));
  if v_primeira !~ '[0-9@]' and array_length(regexp_split_to_array(v_primeira, '\s+'), 1) between 2 and 8 and length(v_primeira) between 5 and 80 and v_primeira !~* '(cpf|cnpj|cep|rua|avenida|email|e-mail)' then v_nome := v_primeira; end if;

  update public.contacts x set
      document = case when v_doc is not null and (nullif(btrim(coalesce(x.document, '')), '') is null or (t ~* '(cpf|cnpj)' and regexp_replace(x.document, '\D', '', 'g') <> v_doc)) then v_doc else x.document end,
      email = case when v_mail is not null and nullif(btrim(coalesce(x.email, '')), '') is null then v_mail else x.email end,
      cep = case when v_cep is not null and length(regexp_replace(coalesce(x.cep, ''), '\D', '', 'g')) <> 8 then v_cep else x.cep end,
      numero = case when v_num is not null and nullif(btrim(coalesce(x.numero, '')), '') is null then v_num else x.numero end,
      company = case when v_nome is not null and nullif(btrim(coalesce(x.company, '')), '') is null
                      and array_length(regexp_split_to_array(btrim(coalesce(x.name, '')), '\s+'), 1) < 2 then v_nome else x.company end,
      quer_nota_fiscal = true
   where x.id = m.contact_id
  returning x.* into c;

  v_f := array_remove(array[case when v_doc is not null then 'documento' end, case when v_mail is not null then 'email' end,
                            case when v_cep is not null then 'cep' end, case when v_num is not null then 'numero' end, case when v_nome is not null then 'nome' end], null);

  if length(regexp_replace(coalesce(c.cep, ''), '\D', '', 'g')) = 8 then
    select * into v_cache from public.cep_bairros b where b.cep = regexp_replace(c.cep, '\D', '', 'g');
    if found then
      update public.contacts x set
          logradouro = coalesce(nullif(btrim(coalesce(x.logradouro, '')), ''), v_cache.logradouro), bairro = coalesce(nullif(btrim(coalesce(x.bairro, '')), ''), v_cache.bairro),
          municipio = coalesce(nullif(btrim(coalesce(x.municipio, '')), ''), v_cache.cidade), uf = coalesce(nullif(btrim(coalesce(x.uf, '')), ''), v_cache.uf),
          codigo_ibge = coalesce(nullif(btrim(coalesce(x.codigo_ibge, '')), ''), v_cache.codigo_ibge)
       where x.id = m.contact_id;
    end if;
  end if;

  if array_length(v_f, 1) > 0 then
    insert into public.agent_logs (conversation_id, actor, action, detail, result, workflow)
    values (m.conv, 'sistema', 'fiscal_extraido', jsonb_build_object('campos', to_jsonb(v_f)), 'ok', 'DB | fiscal_extrair');
  end if;
  return v_f;
end $f$;
revoke all on function private.fiscal_extrair(uuid) from public, anon, authenticated;

create or replace function private.fiscal_completar_cep(p_contact uuid) returns void
language plpgsql security definer set search_path = '' as $f$
begin
  if 'endereco' = any (coalesce((select public.contato_nf_faltantes(c) from public.contacts c where c.id = p_contact), '{}')) then
    perform net.http_post(
      url := 'https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/contato-cep-completar',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)),
      body := jsonb_build_object('contact_id', p_contact));
  end if;
exception when others then raise warning 'fiscal_completar_cep falhou: %', sqlerrm;
end $f$;
revoke all on function private.fiscal_completar_cep(uuid) from public, anon, authenticated;

create or replace function private.fiscal_extrair_trg() returns trigger
language plpgsql security definer set search_path = '' as $f$
declare v_c uuid; v_campos text[];
begin
  if new.direction = 'in' and new.body is not null and new.body ~* '(cpf|cnpj|cep|\mcp\M|@|n[úu]mero|rua |avenida|\mav\.)' then
    begin
      v_campos := private.fiscal_extrair(new.id);
      if array_length(v_campos, 1) > 0 then
        select cv.contact_id into v_c from public.conversations cv where cv.id = new.conversation_id;
        perform private.fiscal_completar_cep(v_c);
      end if;
    exception when others then raise warning 'fiscal_extrair falhou: %', sqlerrm; end;
  end if;
  return new;
end $f$;
revoke all on function private.fiscal_extrair_trg() from public, anon, authenticated;

drop trigger if exists trg_fiscal_extrair on public.messages;
create trigger trg_fiscal_extrair after insert on public.messages for each row execute function private.fiscal_extrair_trg();

-- ====================================================================================================================
-- G5: pagamento vale como aprovação; pedido de condição fora do padrão alerta o dono
-- ====================================================================================================================
do $m$
declare d text; n text;
  a1 text := $q$|vai ser (pix|cart)|isso mesmo|$q$;
  a2 text := $q$|pode ser|vamos)'$q$;
begin
  select pg_get_functiondef('public.preparar_link_pagamento(uuid)'::regprocedure) into d;
  if position('aprov_pagamento_v2' in d) > 0 then return; end if;
  if position(a1 in d) = 0 or position(a2 in d) = 0 then raise exception 'preparar_link_pagamento mudou: ajuste as âncoras'; end if;
  n := replace(d, a1, $q$|vai ser (pix|cart)|\mpix\M|cart[aã]o|pagamento (ser[aá]|vai ser|[eé]|por|no)|forma de pagamento|vou (fazer|efetuar|mandar) o pagamento|pode gerar|gera o link|manda (o )?(pix|link)|isso mesmo|$q$);
  n := replace(n, a2, $q$|pode ser|vamos|^\W*(ok|sim|blz|beleza|certo|show|perfeito|bora|fechado)\W*$)' /* aprov_pagamento_v2 */$q$);
  execute n;
end $m$;

create or replace function private.condicao_fora_padrao_trg() returns trigger
language plpgsql security definer set search_path = '' as $f$
declare v_ct uuid; v_cat text; v_orc record;
begin
  if new.direction <> 'in' or new.body is null or new.type not in ('text', 'audio') then return new; end if;
  if new.body !~* '(50 ?%|cinquenta por cento|metade|sinal|entrada|pagar (depois|na retirada|quando (retirar|buscar|pegar)|metade)|parcel\w* (em )?([3-9]|1[0-2]) ?x|\m([3-9]|1[0-2]) ?x (sem juros|no cart|de r\$|no cr[eé]dito)|em ([3-9]|1[0-2]) vezes|fiado|prazo pra pagar|pagar (s[oó] )?(no|na) (entrega|retirada))' then return new; end if;
  select cv.contact_id into v_ct from public.conversations cv where cv.id = new.conversation_id;
  select o.numero, o.total, o.order_id into v_orc from public.orcamentos o
   where o.contact_id = v_ct and o.status in ('enviado', 'rascunho', 'aceito') and o.criado_em > now() - interval '10 days' and coalesce(o.teste, false) = false
   order by o.criado_em desc limit 1;
  if v_orc.numero is null then return new; end if;
  v_cat := case when new.body ~* '(50 ?%|cinquenta|metade|sinal|entrada)' then 'entrada/sinal'
                when new.body ~* '(retirada|entrega|depois|fiado)' then 'pagar na retirada ou depois' else 'parcelamento acima de 2x' end;
  perform public.alerta_criar('agente_chamado', 'alta', v_ct, new.conversation_id, v_orc.order_id,
    'Cliente pediu condição de pagamento fora do padrão (' || v_cat || ') no orçamento ' || v_orc.numero || ' (R$ ' || to_char(v_orc.total, 'FM999G999D00') || '). A Laura só pode dizer que vai confirmar com o responsável.',
    jsonb_build_object('origem', 'condicao_fora_padrao', 'categoria', v_cat),
    'fora_padrao:' || new.conversation_id || ':' || v_cat || ':' || (now() at time zone 'America/Sao_Paulo')::date::text, null);
  return new;
exception when others then
  raise warning 'condicao_fora_padrao_trg falhou: %', sqlerrm;
  return new;
end $f$;
revoke all on function private.condicao_fora_padrao_trg() from public, anon, authenticated;

drop trigger if exists trg_condicao_fora_padrao on public.messages;
create trigger trg_condicao_fora_padrao after insert on public.messages for each row execute function private.condicao_fora_padrao_trg();

-- ====================================================================================================================
-- G7: trava de saída (promessas fora da ferramenta, pergunta de NF antes de pagar, frase repetida)
-- ====================================================================================================================
create or replace function private.saida_travas_extra(p_exec uuid, p_texto text) returns text[]
language plpgsql stable security definer set search_path = '' as $f$
declare v text[] := '{}'; v_pago boolean := false; v_ct uuid;
begin
  if coalesce(p_texto, '') = '' then return v; end if;
  if p_texto ~* '((entreg\w+|levamos|enviamos|mandamos)[^.!?]{0,60}(toda|todo|qualquer)[^.!?]{0,15}(bh|belo horizonte|regi[aã]o|cidade)|motoboy[^.!?]{0,40}(toda|todo|qualquer|regi[aã]o))' then
    v := array_append(v, 'promessa:frete_fora_da_ferramenta');
  end if;
  if p_texto ~* '((conseguimos|d[aá] (pra|para)|garanto|entregamos|fica pronto|ficam prontos|pronto a tempo|consigo deixar pronto)[^.!?]{0,160}(at[eé]|para|pra) (a |o )?(segunda|ter[cç]a|quarta|quinta|sexta|s[aá]bado|domingo|amanh[aã]|hoje))'
     and p_texto !~ '[0-9]{1,2}/[0-9]{1,2}' then
    v := array_append(v, 'promessa:prazo_sem_ferramenta');
  end if;
  if p_texto ~* '((vai|v[aã]o|vais|quer|gostaria de|precisa de|prefere)[^.!?]{0,25}nota fiscal[^.!?]{0,80}\?|nota fiscal para (esse|este) pedido\?)' then
    select ex.contact_id into v_ct from public.agente_execucoes ex where ex.id = p_exec;
    select exists (select 1 from public.orders o where o.contact_id = v_ct and o.excluido_em is null and (o.payment_status = 'aprovado' or o.payment_manual)
                     and coalesce(o.paid_at, o.created_at) > now() - interval '30 days') into v_pago;
    if not v_pago then v := array_append(v, 'promessa:nf_antes_do_pagamento'); end if;
  end if;
  return v;
end $f$;
revoke all on function private.saida_travas_extra(uuid, text) from public, anon, authenticated;

create or replace function private.saida_repeticao(p_exec uuid, p_texto text) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare v_conv uuid; s text; v_k text; v_out text := ''; v_dup boolean := false;
begin
  select ex.conversation_id into v_conv from public.agente_execucoes ex where ex.id = p_exec;
  if v_conv is null or coalesce(p_texto, '') = '' then return null; end if;
  for s in select btrim(x) from regexp_split_to_table(p_texto, '(?<=[.!?])\s+|\n+') x where btrim(x) <> '' loop
    v_k := left(regexp_replace(lower(extensions.unaccent(s)), '[^a-z ]', '', 'g'), 22);
    if length(s) >= 25 and s !~ '[0-9]' and exists (
        select 1 from public.messages m
         where m.conversation_id = v_conv and m.direction = 'out' and m.deleted_at is null and m.created_at > now() - interval '90 minutes' and m.body is not null
           and exists (select 1 from regexp_split_to_table(m.body, '(?<=[.!?])\s+|\n+') y
                        where length(btrim(y)) >= 25 and left(regexp_replace(lower(extensions.unaccent(btrim(y))), '[^a-z ]', '', 'g'), 22) = v_k)) then
      v_dup := true;
    else
      v_out := v_out || case when v_out = '' then '' else ' ' end || s;
    end if;
  end loop;
  if v_dup and length(v_out) >= 25 then return v_out; end if;
  return null;
end $f$;
revoke all on function private.saida_repeticao(uuid, text) from public, anon, authenticated;

do $m$
declare d text; n text;
  a1 text := $q$v_prom := public.agente_promessas_indevidas_execucao(p_execucao, p_texto);$q$;
  a2 text := $q$and coalesce(array_length(public.agente_promessas_indevidas_execucao(p_execucao, v_s), 1), 0) = 0$q$;
  a3 text := $q$v_rep boolean := false;$q$;
begin
  select pg_get_functiondef('public.agente_saida_segura(uuid,text)'::regprocedure) into d;
  if position('saida_travas_extra' in d) > 0 then return; end if;
  if position(a1 in d) = 0 or position(a2 in d) = 0 or position(a3 in d) = 0 or (length(d) - length(replace(d, E'  return r;', ''))) <> length(E'  return r;') then
    raise exception 'agente_saida_segura mudou: ajuste os âncoras';
  end if;
  n := replace(d, a3, a3 || ' v_dup text;');
  n := replace(n, a1, a1 || E'\n  v_prom := v_prom || private.saida_travas_extra(p_execucao, p_texto);');
  n := replace(n, a2, a2 || E'\n           and coalesce(array_length(private.saida_travas_extra(p_execucao, v_s), 1), 0) = 0');
  n := replace(n, E'  return r;', E'  if coalesce((r ->> ''ok'')::boolean, true) then\n    v_dup := private.saida_repeticao(p_execucao, p_texto);\n    if v_dup is not null then\n      r := r || jsonb_build_object(''ok'', false, ''soft_only'', true, ''texto_saneado'', v_dup, ''motivos'', coalesce(r -> ''motivos'', ''[]''::jsonb) || ''"repeticao:frase"''::jsonb);\n    end if;\n  end if;\n  return r;');
  execute n;
end $m$;

-- ====================================================================================================================
-- G4/G6: opções sem repetição por orientação; limite de ferramentas por rodada
-- ====================================================================================================================
do $m$
declare d text; n text; a text := $q$if v_qtd is not null and jsonb_array_length(v_opcoes) > 0 then /* lote_maior */$q$;
begin
  select pg_get_functiondef('public.buscar_produto(text,integer,jsonb)'::regprocedure) into d;
  if position('dedupe_orientacao' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception 'buscar_produto mudou: âncora lote_maior não encontrada'; end if;
  n := replace(d, a, $q$if jsonb_array_length(v_opcoes) > 1 then /* dedupe_orientacao */
    select coalesce(jsonb_agg(x.o order by x.ord), '[]'::jsonb) into v_opcoes
      from (select t.o, t.ord, row_number() over (
                     partition by regexp_replace(t.o ->> 'descricao_curta', '[0-9]+([.,][0-9]+)? ?x ?[0-9]+([.,][0-9]+)?', '', 'g'),
                                  t.o ->> 'quantidade', t.o ->> 'preco',
                                  (select string_agg(dim, 'x' order by dim) from unnest(array[
                                      (regexp_match(t.o ->> 'descricao_curta', '([0-9]+(?:[.,][0-9]+)?) ?x ?([0-9]+(?:[.,][0-9]+)?)'))[1],
                                      (regexp_match(t.o ->> 'descricao_curta', '([0-9]+(?:[.,][0-9]+)?) ?x ?([0-9]+(?:[.,][0-9]+)?)'))[2]]) dim)
                     order by t.ord) rn
              from jsonb_array_elements(v_opcoes) with ordinality t (o, ord)) x
     where x.rn = 1;
  end if;
  $q$ || a);
  execute n;
end $m$;

update public.agente_config set max_ferramenta_por_rodada = 6, max_chamadas_por_rodada = 16 where id = 1;
