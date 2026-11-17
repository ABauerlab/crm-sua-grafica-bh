-- SNAPSHOT DE REFERÊNCIA (17/11/2026). NÃO é migration e não deve ser aplicado em ordem.
-- Definição exata, lida do banco de produção, das funções alteradas na rodada de 17/11/2026 (Laura, trava de saída,
-- lembretes, retomada, escada de preço, financeiro e nota fiscal). Cada bloco foi conferido por hash md5 contra
-- pg_get_functiondef do banco. Serve para reconstruir o estado atual se o banco for refeito.
-- Dependências fora deste arquivo: tabelas e demais funções já existentes (ver supabase/migrations).

-- ==== private.agente_retomar_travadas (md5 ebce91dcd755909081b5c022dfd9f301) ====
CREATE OR REPLACE FUNCTION private.agente_retomar_travadas()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record; v_url text; v_n integer := 0;
begin
  select valor into v_url from public.app_segredos where chave = 'n8n_wf1_entrada_url';
  if v_url is null then return 0; end if;
  if coalesce((select (value ->> 'enabled')::boolean from public.app_settings where key = 'agent_retomada'), true) = false then return 0; end if;
  if coalesce((select (value ->> 'enabled')::boolean from public.app_settings where key = 'agent'), false) = false then return 0; end if;

  for r in
    select cv.id as conv, mi.id as msg
      from public.conversations cv
      join public.contacts ct on ct.id = cv.contact_id
      join lateral (select m.direction, m.body, m.created_at from public.messages m where m.conversation_id = cv.id order by m.created_at desc limit 1) ult on true
      join lateral (select m.id, m.created_at from public.messages m where m.conversation_id = cv.id and m.direction = 'in' order by m.created_at desc limit 1) mi on true
     where coalesce(cv.modo_atendimento, 'ia') = 'ia' and coalesce(cv.ai_handled, true)
       and not coalesce(ct.optout, false) and not ('teste' = any (coalesce(ct.tags, '{}')))
       and mi.created_at > now() - interval '6 hours' and mi.created_at < now() - interval '4 minutes'
       and (not coalesce(cv.needs_human, false) or (ult.direction = 'out' and ult.body like 'Oi! Recebi sua mensagem e já volto%'))
       and (ult.direction = 'in'
            or (ult.direction = 'out' and ult.created_at < now() - interval '4 minutes'
                and (ult.body like 'Oi! Recebi sua mensagem e já volto%' or ult.body like 'Deixa eu confirmar isso certinho aqui e já te respondo%'
                     or ult.body like 'Deixa eu conferir os detalhes exatos%')))
       and not exists (select 1 from public.agente_execucoes e where e.message_id = mi.id and e.status in ('ignorada', 'rodando'))
       and not exists (select 1 from public.agente_execucoes e where e.conversation_id = cv.id and e.status = 'rodando' and e.iniciado_em > now() - interval '5 minutes')
       and (select count(*) from public.agent_logs l where l.conversation_id = cv.id and l.action = 'retomada' and l.detail ->> 'message_id' = mi.id::text) < 6
       and not exists (select 1 from public.agent_logs l where l.conversation_id = cv.id and l.action = 'retomada' and l.created_at > now() - interval '10 minutes')
     limit 5
  loop
    update public.conversations set needs_human = false where id = r.conv and needs_human;
    delete from public.agente_execucoes where message_id = r.msg;
    insert into public.agent_logs (conversation_id, actor, action, detail, result, workflow)
    values (r.conv, 'sistema', 'retomada', jsonb_build_object('message_id', r.msg), 'ok', 'private.agente_retomar_travadas');
    perform net.http_post(url := v_url, headers := '{"Content-Type": "application/json", "x-gbh-token": "retomada"}'::jsonb, body := jsonb_build_object('message_id', r.msg));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

-- ==== private.agente_silencio_vigiar (md5 b4bd9c41f8382401aa2afff0ad5bb5fc) ====
CREATE OR REPLACE FUNCTION private.agente_silencio_vigiar()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record; n integer := 0;
begin
  for r in
    select c.id as conversation_id, c.contact_id, m.id as msg_id
      from public.conversations c
      join lateral (
        select m1.id, m1.created_at from public.messages m1
         where m1.conversation_id = c.id and m1.direction = 'in' and m1.deleted_at is null
         order by m1.created_at desc limit 1
      ) m on true
     where c.modo_atendimento = 'ia'
       and coalesce(c.ai_handled, true)
       and m.created_at between now() - interval '12 hours' and now() - interval '15 minutes' /* vigia_15min */
       and not exists (select 1 from public.messages o where o.conversation_id = c.id and o.direction = 'out' and o.created_at >= m.created_at)
       and not exists (select 1 from public.agente_execucoes e where e.conversation_id = c.id and (e.status = 'rodando' and e.iniciado_em > now() - interval '5 minutes' or e.teste))
  loop
    perform public.alerta_criar('agente_falhou', 'baixa', /* vigia_baixa */ r.contact_id, r.conversation_id, null,
      'A Laura demorou a responder. A retomada automatica ja esta tratando; nada a fazer.',
      jsonb_build_object('mensagem_id', r.msg_id, 'origem', 'vigia_silencio'), 'silencio:' || r.msg_id, null);
    n := n + 1;
  end loop;
  return n;
end $function$;

-- ==== private.faixas_escada (md5 c63f49ddf678a35045d1176adf455cb0) ====
CREATE OR REPLACE FUNCTION private.faixas_escada(p_sku text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b public.catalogo%rowtype; v_alvos integer[]; v_out jsonb; v_ub numeric; v_last_u numeric; t integer; l record; j jsonb; v_n integer := 0; v_prev integer; v_pt numeric;
begin
  select * into b from public.catalogo where sku = p_sku;
  if not found or coalesce(b.quantidade, 0) <= 0 then return null; end if;
  j := public.calcular_preco(b.sku, 1, '{}'::jsonb);
  if not coalesce((j ->> 'ok')::boolean, false) then return null; end if;
  v_ub := (j ->> 'preco_total')::numeric / b.quantidade; v_last_u := v_ub; v_prev := b.quantidade;
  v_out := jsonb_build_array(jsonb_build_object('sku', b.sku, 'quantidade', b.quantidade, 'preco', (j ->> 'preco_total')::numeric, 'preco_unitario', round(v_ub, 2)));
  select faixas into v_alvos from public.faixas_quantidade_categoria where categoria = b.categoria;
  if v_alvos is null then v_alvos := array[b.quantidade * 10, b.quantidade * 50]; end if;
  foreach t in array v_alvos loop
    exit when v_n >= 2;
    continue when t <= b.quantidade;
    l := null;
    select c.sku, c.quantidade into l from public.catalogo c
     where c.active and c.vendavel and c.preco_venda is not null and c.categoria = b.categoria and c.descricao is not distinct from b.descricao
       and c.cores is not distinct from b.cores and c.tamanho_mm is not distinct from b.tamanho_mm and c.quantidade > v_prev
     order by abs(c.quantidade - t), c.quantidade limit 1;
    continue when l.sku is null;
    j := public.calcular_preco(l.sku, 1, '{}'::jsonb);
    continue when not coalesce((j ->> 'ok')::boolean, false);
    v_pt := (j ->> 'preco_total')::numeric;
    continue when v_pt / l.quantidade >= v_last_u;
    v_out := v_out || jsonb_build_array(jsonb_build_object('sku', l.sku, 'quantidade', l.quantidade, 'preco', v_pt, 'preco_unitario', round(v_pt / l.quantidade, 2)));
    v_last_u := v_pt / l.quantidade; v_prev := l.quantidade; v_n := v_n + 1;
  end loop;
  if jsonb_array_length(v_out) < 2 then return null; end if;
  return v_out;
end $function$;

-- ==== private.ficha_respostas (md5 c75a92a815e6e65c8e2bc332a3f54b65) ====
CREATE OR REPLACE FUNCTION private.ficha_respostas(p_conv uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r record; v_q text := null; v_resp text := ''; v_pairs jsonb := '[]'::jsonb; v_qtd text := null; v_qtd_em timestamptz := null; v_m text[];
begin
  for r in select m.direction, m.body, m.created_at from public.messages m
            where m.conversation_id = p_conv and m.body is not null and m.deleted_at is null and m.created_at > now() - interval '5 days'
              and m.body !~ '^\[(foto|imagem|Orçamento)' order by m.created_at loop
    if r.direction = 'out' then
      if v_q is not null and v_resp <> '' then
        v_pairs := v_pairs || jsonb_build_object('pergunta', left(v_q, 140), 'resposta', left(v_resp, 180));
      end if;
      v_resp := '';
      if r.body ~ '\?' then
        v_m := regexp_match(r.body, '([^.!?\n]*\?)\s*$');
        v_q := btrim(coalesce(v_m[1], r.body));
      end if;
    else
      if v_q is not null then v_resp := btrim(v_resp || ' | ' || left(r.body, 120), ' |'); end if;
      v_m := regexp_match(r.body, '([0-9]{1,6})\s*(unidades|unidade|un\b|crach|cart|panfl|adesiv|banner|etiqueta|r[oó]tulo|c[oó]pias|de in[ií]cio|pe[cç]as|folhas)', 'i');
      if v_m is not null then v_qtd := v_m[1]; v_qtd_em := r.created_at;
      elsif v_q is not null and v_q ~* '(quantos|quantas|quantidade)' and btrim(r.body) ~ '^[0-9]{1,6}$' then v_qtd := btrim(r.body); v_qtd_em := r.created_at;
      end if;
    end if;
  end loop;
  if v_q is not null and v_resp <> '' then
    v_pairs := v_pairs || jsonb_build_object('pergunta', left(v_q, 140), 'resposta', left(v_resp, 180));
  end if;
  return jsonb_build_object('quantidade_informada', v_qtd, 'quantidade_em', v_qtd_em,
    'respostas', coalesce((select jsonb_agg(t.e order by t.n) from (select e, n from jsonb_array_elements(v_pairs) with ordinality x(e, n) order by n desc limit 10) t), '[]'::jsonb));
end $function$;

-- ==== private.fiscal_copiar_para_pedido (md5 aa51ae0f797039ca16e3c884f5a926ea) ====
CREATE OR REPLACE FUNCTION private.fiscal_copiar_para_pedido()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_dados jsonb;
begin
  if coalesce(new.quer_nota_fiscal, false) = false then return new; end if;
  v_dados := jsonb_strip_nulls(jsonb_build_object(
    'nome', coalesce(nullif(btrim(new.company), ''), new.name), 'documento', nullif(btrim(new.document), ''), 'email', nullif(btrim(new.email), ''),
    'cep', nullif(btrim(new.cep), ''), 'endereco', nullif(btrim(new.address), ''), 'atualizado_em', now()));
  update public.orders o set dados_fiscais = v_dados
   where o.id = (select o2.id from public.orders o2 where o2.contact_id = new.id and o2.excluido_em is null order by o2.created_at desc limit 1);
  return new;
end $function$;

-- ==== private.fu_assunto (md5 43d814cf3d10e702a40979f064e51986) ====
CREATE OR REPLACE FUNCTION private.fu_assunto(p_conv uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select l.rotulo
    from (select m.created_at, m.body from public.messages m where m.conversation_id = p_conv and m.body is not null and m.deleted_at is null order by m.created_at desc limit 10) x
    cross join lateral (select v.rotulo from (values
      (1, '(crach[aá]s?)', 'crachás'), (2, '(tirantes?|lanyards?)', 'tirantes'), (3, '(cord[aã]o|cord[oõ]es)', 'cordões'),
      (4, '(r[oó]tulos?)', 'rótulos'), (5, '(adesivos?|etiquetas?)', 'adesivos'), (6, 'cart[aã]o de visita|cart[oõ]es de visita', 'cartões de visita'),
      (7, '(panfletos?|flyers?|folhetos?)', 'panfletos'), (8, '(banners?|faixas?|lonas?)', 'banners'), (9, '(canecas?)', 'canecas'),
      (10, '(chaveiros?)', 'chaveiros'), (11, '(sacolas?)', 'sacolas'), (12, '(canetas?)', 'canetas'), (13, '(squeezes?|garrafas?)', 'squeezes'),
      (14, '(bottons?|pins?)', 'bottons'), (15, '(agendas?|cadernos?)', 'agendas'), (16, '(calend[aá]rios?)', 'calendários'),
      (17, '(camisetas?|camisas?)', 'camisetas'), (18, '(convites?)', 'convites'), (19, 'cart[aã]o fidelidade|cart[oõ]es fidelidade', 'cartões fidelidade'),
      (20, '(brindes?)', 'brindes')) v(ord, pat, rotulo) where x.body ~* v.pat order by v.ord limit 1) l
   order by x.created_at desc limit 1 $function$;

-- ==== private.fu_nome (md5 7f7609f363c539140d354eae866cd78e) ====
CREATE OR REPLACE FUNCTION private.fu_nome(p_nome text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ select coalesce(nullif(initcap(regexp_replace(split_part(trim(coalesce(p_nome, '')), ' ', 1), '[^A-Za-zÀ-ÿ-]', '', 'g')), ''), 'cliente'); $function$;

-- ==== private.fu_texto_q (md5 17fee12300a783347c2353e1e1dc70a8) ====
CREATE OR REPLACE FUNCTION private.fu_texto_q(p_regra text, p_conv uuid, p_nome text, p_var integer)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_regra = 'Q1' then
    return case p_var
      when 0 then format('Oi, %s! Assim que puder, me dá uma resposta por aqui pra gente já seguir com o seu orçamento e conseguir te entregar o seu material o quanto antes, combinado?', p_nome)
      else format('Oi, %s! Passando pra gente não perder o fio: quando puder me responder aqui, eu já sigo com o seu orçamento e garanto a entrega o mais rápido possível. Pode ser?', p_nome) end;
  elsif p_regra = 'Q2' then
    return format('Oi, %s! Última chamada: se ainda fizer sentido pra você, é só me responder por aqui que eu já sigo com o seu orçamento e te entrego o material o quanto antes. Posso contar com você?', p_nome);
  end if;
  return null;
end $function$;

-- ==== private.fu_ultima_pergunta (md5 3b431a9f7a9ca597e15efff6acd61ab3) ====
CREATE OR REPLACE FUNCTION private.fu_ultima_pergunta(p_conv uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select nullif(upper(left(q, 1)) || substr(q, 2), '')
    from (select regexp_replace(btrim(coalesce((regexp_match(m.body, '([^.!?\n]*\?)\s*$'))[1], '')), '^(E|Então|Ah|Show|Perfeito|Combinado|Beleza)[,!]?\s+', '', 'i') as q
            from public.messages m
           where m.conversation_id = p_conv and m.direction = 'out' and m.body ~ '\?\s*$' and m.body !~ 'R\$' and m.body !~* '^oi[, !]' and length(m.body) < 500
           order by m.created_at desc limit 1) z
   where length(q) between 12 and 220
     and not (q ~* '(quantos|quantas|quantidade)' and (private.ficha_respostas(p_conv) ->> 'quantidade_informada') is not null) $function$;

-- ==== public.agente_chamar_dono.3 (md5 b4b5ac815fea5904d62d490c788ce53f) ====
CREATE OR REPLACE FUNCTION public.agente_chamar_dono(p_conversation uuid, p_motivo text, p_gravidade text DEFAULT 'baixa'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_conv public.conversations%rowtype;
  v_grav text := case when p_gravidade in ('alta', 'baixa') then p_gravidade else 'baixa' end;
  v_motivo text := left(btrim(coalesce(p_motivo, 'Agente pediu apoio do dono.')), 280);
  v_al jsonb;
  v_travar_conversa boolean := false;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into v_conv from public.conversations where id = p_conversation;
  if not found then return jsonb_build_object('ok', false, 'erro', 'conversa_nao_encontrada'); end if;

  if v_grav = 'alta' and v_motivo ~* '(pediu\s+(atendente\s+)?humano|falar\s+com\s+(uma\s+)?pessoa|reclama[cç][aã]o|estorno|reembolso|defeito)' then
    v_travar_conversa := true;
    update public.conversations set needs_human = true where id = p_conversation;
  end if;

  v_al := public.alerta_criar('agente_chamado', v_grav, v_conv.contact_id, p_conversation, null, v_motivo,
    jsonb_build_object('motivo', v_motivo, 'ia_continua_ativa', not v_travar_conversa),
    'agente:' || p_conversation::text || ':' || v_grav || ':' || md5(v_motivo), null);

  return jsonb_build_object('ok', true, 'gravidade', v_grav, 'ia_continua_ativa', not v_travar_conversa, 'alerta', v_al);
end;
$function$;

-- ==== public.agente_chamar_dono.4 (md5 f80c1e0e77532bbc7228a37d98551c29) ====
CREATE OR REPLACE FUNCTION public.agente_chamar_dono(p_conversation uuid, p_motivo text, p_gravidade text DEFAULT 'baixa'::text, p_tipo text DEFAULT 'agente_chamado'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_contact uuid; v_r jsonb; v_grav text; v_motivo text := left(trim(coalesce(p_motivo, '')), 300); v_critico boolean;
begin
  select contact_id into v_contact from public.conversations where id = p_conversation;
  if v_contact is null then return jsonb_build_object('ok', false, 'motivo', 'conversa_inexistente'); end if; /* atencao_so_reclamacao */
  v_critico := p_tipo in ('reclamacao', 'pagamento_problema', 'pedido_humano', 'cancelamento', 'estorno')
    or v_motivo ~* '(pediu\s+(atendente\s+)?humano|falar\s+com\s+(uma\s+|algu[eé]m|a\s+)?(pessoa|atendente|dono)|reclama[cç][aã]o|reclamou|estorno|reembolso|cancelar\s+(o\s+)?pedido|defeito|pagou\s+e\s+n[aã]o)';
  v_grav := case when v_critico and p_gravidade = 'alta' then 'alta' else 'baixa' end;
  if not v_critico and p_tipo in ('agente_falhou', 'saida_bloqueada') then /* falha_silenciosa */
    insert into public.agent_logs (conversation_id, actor, action, detail, result, workflow)
    values (p_conversation, 'sistema', p_tipo, jsonb_build_object('motivo', v_motivo), 'sem_alerta', 'agente_chamar_dono');
    return jsonb_build_object('ok', true, 'alerta', null, 'suprimido', true);
  end if;
  v_r := public.alerta_criar(p_tipo, v_grav, v_contact, p_conversation, null, p_motivo,
    jsonb_build_object('motivo', v_motivo, 'critico', v_critico));
  if v_critico and v_grav = 'alta' then update public.conversations set needs_human = true where id = p_conversation; end if;
  return v_r;
end;
$function$;

-- ==== public.agente_contexto (md5 b94810ec5a1029b001bbd95cc78d86ef) ====
CREATE OR REPLACE FUNCTION public.agente_contexto(p_conversation uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb; p jsonb; b jsonb;
begin
  r := public.agente_contexto_base(p_conversation);
  if r ? 'erro' then return r; end if;
  if jsonb_typeof(r -> 'anuncio') = 'object' then /* anuncio_titulo */
    r := jsonb_set(r, '{anuncio}', (r -> 'anuncio') || jsonb_build_object(
      'titulo', coalesce(r -> 'anuncio' ->> 'titulo', r -> 'anuncio' ->> 'headline'),
      'texto', coalesce(r -> 'anuncio' ->> 'texto', r -> 'anuncio' ->> 'body')));
  end if;
  p := public.agente_persona(p_conversation);
  select cv.brain into b from public.conversations cv where cv.id = p_conversation;
  return r || jsonb_build_object('persona', p, 'nome_atendente', p ->> 'nome', 'fase', p ->> 'fase', 'cerebro', coalesce(b, '{}'::jsonb), 'ficha', private.ficha_respostas(p_conversation) /* ficha */);
end $function$;

-- ==== public.agente_pode_enviar_rodada (md5 a893fe1fa1ce9e420b1720bfb4604d13) ====
CREATE OR REPLACE FUNCTION public.agente_pode_enviar_rodada(p_conversation uuid, p_message uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_motivo text; m record;
begin
  v_motivo := public.agente_bloqueio(p_conversation);
  if v_motivo is null then
    select created_at, id into m from public.messages where id = p_message;
    if found and exists (select 1 from public.messages x where x.conversation_id = p_conversation and x.direction = 'in'
                            and (x.created_at, x.id) > (m.created_at, m.id)) then
      v_motivo := 'mensagem_nova';
    end if;
  end if;
  return jsonb_build_object('pode', v_motivo is null, 'motivo', v_motivo);
end $function$;

-- ==== public.agente_promessas_indevidas_execucao (md5 78f0a031162382317289502e3a079d19) ====
CREATE OR REPLACE FUNCTION public.agente_promessas_indevidas_execucao(p_execucao uuid, p_texto text)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  t text := lower(coalesce(p_texto, '')); v_contato uuid; v_motivos text[] := '{}'; v_ord record; v_orc record; v_cond boolean;
  v_cond_txt boolean; /* brinde_ok */
begin
  select contact_id into v_contato from public.agente_execucoes where id = p_execucao;
  select o.* into v_ord from public.orders o where o.contact_id = v_contato and o.excluido_em is null and o.cancelado_em is null order by o.created_at desc limit 1;
  select oc.* into v_orc from public.orcamentos oc where oc.contact_id = v_contato and oc.status in ('rascunho', 'enviado', 'aceito', 'pago') order by oc.criado_em desc limit 1;
  v_cond_txt := t ~ '(assim que|quando|depois que|após|apos|logo que|caso|se o|se a|assim q)[^.!?]{0,70}(pagamento|pix|arte|produção|producao)';

  if t ~ '(pagamento|pix|pagto)\s+(já\s+)?(foi\s+|está\s+|esta\s+)?(confirmad|aprovad|recebid|identificad|compensad)' or t ~ 'recebemos\s+(o\s+)?(seu\s+)?(pagamento|pix)' or t ~ 'já\s+(caiu|foi\s+pago|consta\s+como\s+pago)' then
    if not v_cond_txt and coalesce(v_ord.payment_status::text, '') <> 'aprovado' then v_motivos := array_append(v_motivos, 'promessa:pagamento_sem_confirmacao'); end if;
  end if;
  if t ~ '(sua\s+)?arte\s+(já\s+)?(foi\s+|está\s+|esta\s+|ficou\s+)?aprovada' or t ~ 'aprovamos\s+(a|sua)\s+arte' then
    if not v_cond_txt and coalesce(v_ord.art_status::text, '') <> 'aprovada' then v_motivos := array_append(v_motivos, 'promessa:arte_aprovada_sem_status'); end if;
  end if;
  if t ~ '(entrou|foi|está|esta|já\s+está|ja\s+esta)\s+(em|para\s+a?)\s+produ[cç][aã]o' or t ~ 'começamos\s+a\s+produzir|produ[cç][aã]o\s+iniciada|já\s+estamos\s+produzindo' then
    if not v_cond_txt and coalesce(v_ord.stage::text, '') <> 'producao' then v_motivos := array_append(v_motivos, 'promessa:producao_sem_status'); end if;
  end if;
  if t ~ '(seu\s+pedido\s+)?(já\s+)?(está|esta|ficou)\s+pronto|foi\s+entregue|saiu\s+para\s+(a\s+)?entrega|já\s+pode\s+(retirar|buscar)' then
    if not v_cond_txt and coalesce(v_ord.subestatus_pedido, '') not in ('pronto_retirada', 'saiu_entrega') and coalesce(v_ord.stage::text, '') not in ('entregue', 'recompra') then
      v_motivos := array_append(v_motivos, 'promessa:conclusao_sem_status');
    end if;
  end if;
  if t ~ 'fica(rá)?\s+pronto[^.!?]{0,60}(dia\s+\d{1,2}|\d{1,2}/\d{1,2}|amanhã|amanha|hoje|segunda|terça|terca|quarta|quinta|sexta)' then
    if not (
      (v_orc.data_prevista is not null and t ~ ('dia\s+0?' || extract(day from v_orc.data_prevista)::int::text || '(\D|$)'))
      or (v_ord.due_date is not null and t ~ ('dia\s+0?' || extract(day from v_ord.due_date)::int::text || '(\D|$)'))
      or (v_orc.data_prevista is not null and t ~ ('0?' || extract(day from v_orc.data_prevista)::int::text || '/0?' || extract(month from v_orc.data_prevista)::int::text))
    ) then v_motivos := array_append(v_motivos, 'promessa:data_que_a_ferramenta_nao_deu'); end if;
  end if;
  select exists (select 1 from public.condicoes_especiais c join public.orcamentos o on o.id = c.orcamento_id
                  where o.contact_id = v_contato and c.resultado <> 'cancelada' and c.valida_ate > now() - interval '1 hour') into v_cond;
  if regexp_replace(t, '(não|nao)\s+(consigo|posso|dá|da|temos|faço|faco|fazemos|há|ha|tem|vou)[^.!?]*[.!?]', ' ', 'g') ~ '(\d+\s*%\s*(de\s+)?desconto|desconto\s+de\s+\d|abatimento|faço\s+por\s+r\$|fecho\s+por\s+r\$|ganha(r|rá|ra)?\s+[^.!?]{0,40}brinde|brinde\s+(gr[aá]tis|de\s+cortesia))' and not v_cond then
    v_motivos := array_append(v_motivos, 'promessa:desconto_fora_da_funcao');
  end if;
  if t ~ '(vamos|iremos|irei|vou|podemos|posso|faremos|farei)\s+(fazer\s+)?(o\s+|um\s+)?(reembolso|estorno|ressarcimento)' or t ~ '(devolv(o|emos|eremos)|ressarcir)\s' or t ~ 'seu\s+(dinheiro|valor)\s+(será|vai\s+ser|sera)\s+devolvido' or t ~ 'reembolso\s+(garantido|aprovado)' then
    v_motivos := array_append(v_motivos, 'promessa:reembolso');
  end if;
  if t ~ 'a\s+partir\s+de\s+r\$\s*[0-9]' /* preco_de_entrada */
     and (select (private.ficha_respostas(ex.conversation_id) ->> 'quantidade_informada') from public.agente_execucoes ex where ex.id = p_execucao) is null then
    v_motivos := array_append(v_motivos, 'promessa:preco_de_entrada');
  end if;
  return v_motivos;
end;
$function$;

-- ==== public.agente_saida_base_execucao (md5 bc6cc3c3635e93b2d956db5803c383bd) ====
CREATE OR REPLACE FUNCTION public.agente_saida_base_execucao(p_execucao uuid, p_texto text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  ex record;
  pc record;
  v text := coalesce(p_texto, '');
  v_motivos text[] := '{}';
  v_sku text;
  v_m text[];
  v_valor numeric;
  v_ok boolean;
  v_fixos numeric[];
  v_ctx numeric[];
  v_regras text[][] := array[
    array['custo', '(\m(nosso|nossa|nossos|meu|minha)\s+custos?\M|\mpre[cç]o\s+de\s+custo\M|\mcustos?\s+(de\s+)?(produ[cç][aã]o|fabrica[cç][aã]o|interno|internos|real|reais)\M|\mcustos?\s+do\s+fornecedor\M)'],
    array['margem', '\mmargem\M(?!\s+(de\s+|da\s+|do\s+)?(seguran[cç]a|sangria|corte|branca|interna|externa|impress[aã]o|arte|papel))'],
    array['piso', '\mpiso\M'],
    array['fornecedor', '\mfornecedor(es)?\M'],
    array['sku', '\msku\M'],
    array['bicicleta', '\m(bicicleta|bike|ciclista)\M'],
    array['endereco', '(rua rio de janeiro,? *n?º? *462|\m22\s*[ºo°]?\s*andar|\msala\s*(2216|2217)\M|\m30160-?040\M)']
  ];
  i int;
begin
  select * into ex from public.agente_execucoes where id = p_execucao;
  select arte_valor, arte_frete_valor, pedido_minimo_frete_gratis into pc from public.parametros_comerciais where id = 1;
  v_fixos := array[pc.arte_valor, pc.arte_frete_valor, pc.pedido_minimo_frete_gratis];

  select coalesce(array_agg(x), '{}') into v_ctx
  from (
    select unnest(array[o.total, o.subtotal, o.arte_valor, o.frete_valor, o.desconto_valor]) as x
    from public.orcamentos o
    join public.conversations cv on cv.contact_id = o.contact_id
    where cv.id = ex.conversation_id and o.status in ('rascunho', 'enviado', 'aceito')
      and (o.validade_ate is null or o.validade_ate > now())
  ) t where x is not null and x > 0;

  -- Valores que as ferramentas já confirmaram antes nesta mesma conversa (últimas 12 h) também valem: um resumo do que já foi cotado não pode ser bloqueado.
  select v_ctx || coalesce(array_agg(distinct y), '{}') into v_ctx /* valores_da_conversa */
    from (select unnest(e2.valores_vistos) as y from public.agente_execucoes e2
           where e2.conversation_id = ex.conversation_id and e2.id <> ex.id and e2.iniciado_em > now() - interval '12 hours' and e2.valores_vistos is not null) z
   where y is not null and y > 0;

  v := regexp_replace(v, '\s*[—–]\s*', ', ', 'g');
  v := regexp_replace(v, '\*+', '', 'g');
  v := regexp_replace(v, '`+', '', 'g');
  v := regexp_replace(v, '(^|\n)\s*#{1,6}\s+', '\1', 'g');
  v := regexp_replace(v, '(^|\n)\s*[-•]\s+', '\1', 'g');
  v := regexp_replace(v, '[ \t]+\n', E'\n', 'g');
  v := regexp_replace(v, '\n{3,}', E'\n\n', 'g');
  v := trim(v);
  if v = '' then v_motivos := array_append(v_motivos, 'vazia'::text); end if;

  for i in 1 .. array_length(v_regras, 1) loop
    if v ~* v_regras[i][2] then v_motivos := array_append(v_motivos, ('vazamento:' || v_regras[i][1])::text); end if;
  end loop;
  if ex.skus_vistos is not null then
    foreach v_sku in array ex.skus_vistos loop
      if length(v_sku) >= 3 and v ~* ('\m' || regexp_replace(v_sku, '([^[:alnum:]])', '\\\1', 'g') || '\M') then
        v_motivos := array_append(v_motivos, 'vazamento:sku_do_catalogo'::text);
      end if;
    end loop;
  end if;

  for v_m in select regexp_matches(v, 'R\$\s*(\d[\d\.]*(?:,\d{1,2})?)', 'g') loop
    v_valor := replace(replace(v_m[1], '.', ''), ',', '.')::numeric;
    v_ok := false;
    if ex.valores_vistos is not null and exists (select 1 from unnest(ex.valores_vistos) x where abs(x - v_valor) < 0.011) then v_ok := true; end if;
    if exists (select 1 from unnest(v_fixos) x where abs(x - v_valor) < 0.011) then v_ok := true; end if;
    if exists (select 1 from unnest(v_ctx) x where abs(x - v_valor) < 0.011) then v_ok := true; end if;
    if not v_ok then v_motivos := array_append(v_motivos, 'preco_nao_verificado'::text); end if;
  end loop;

  return jsonb_build_object(
    'ok', coalesce(array_length(v_motivos, 1), 0) = 0,
    'motivos', to_jsonb((select coalesce(array_agg(distinct x), '{}') from unnest(v_motivos) x)),
    'texto', v,
    'texto_seguro', 'Deixa eu confirmar isso certinho aqui e já te respondo, tá?');
end;
$function$;

-- ==== public.agente_saida_segura (md5 c98f43c5ebd5e1ef81004d6dcdfeb3f3) ====
CREATE OR REPLACE FUNCTION public.agente_saida_segura(p_execucao uuid, p_texto text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r jsonb := public.agente_saida_base_execucao(p_execucao, p_texto);
  v_prom text[]; v_ct uuid; v_mot jsonb; v_s text; v_san text := ''; v_soft boolean; v_fq jsonb; v_rep boolean := false;
begin
  -- O endereço do balcão da Praça Sete (Rua Rio de Janeiro, 462, 22º andar, sala 2217) é o endereço comercial público da Sua Gráfica BH
  -- e faz parte das orientações oficiais de balcão na qualificação e fechamento. Nunca deve ser bloqueado como vazamento.
  if r -> 'motivos' ? 'vazamento:endereco' then
    v_mot := (select coalesce(jsonb_agg(m), '[]'::jsonb) from jsonb_array_elements_text(r -> 'motivos') m where m <> 'vazamento:endereco');
    r := jsonb_set(r, '{motivos}', v_mot);
    r := jsonb_set(r, '{ok}', to_jsonb(jsonb_array_length(v_mot) = 0));
  end if;
  if coalesce(p_texto, '') ~* '(calling tools?\s*:|control_token|default_api|\mcall_[0-9]{4,}|tool_call)' then
    r := jsonb_set(r, '{ok}', 'false'::jsonb);
    r := jsonb_set(r, '{motivos}', coalesce(r -> 'motivos', '[]'::jsonb) || '\"vazamento:chamada_de_ferramenta\"'::jsonb);
  end if;
  v_prom := public.agente_promessas_indevidas_execucao(p_execucao, p_texto);
  if coalesce(p_texto, '') ~* '((vou|iremos|irei|posso|podemos|farei|faremos)\s+(te\s+)?(reembolsar|estornar|devolver|ressarcir)|(reembolsarei|estornarei|devolverei|ressarcirei)|te\s+(reembolsamos|devolvemos))'
     and not v_prom @> array['promessa:reembolso'] then
    v_prom := array_append(v_prom, 'promessa:reembolso');
  end if;
  if array_length(v_prom, 1) > 0 then
    r := jsonb_set(r, '{ok}', 'false'::jsonb);
    r := jsonb_set(r, '{motivos}', coalesce(r -> 'motivos', '[]'::jsonb) || to_jsonb(v_prom));
  end if;
  select private.ficha_respostas(ex.conversation_id) into v_fq from public.agente_execucoes ex where ex.id = p_execucao;
  if v_fq ->> 'quantidade_informada' is not null and (v_fq ->> 'quantidade_em')::timestamptz > now() - interval '36 hours' then /* pergunta_repetida */
    v_rep := exists (select 1 from regexp_split_to_table(coalesce(p_texto, ''), '(?<=[.!?])\s+|\n+') z
                      where z ~* '(quantos|quantas|qual (é )?a quantidade|que quantidade)' and z ~ '\?' and z !~* '(cord[aã]o|cord[oõ]es|tirante|brinde)');
    if v_rep then
      r := jsonb_set(r, '{ok}', 'false'::jsonb);
      r := jsonb_set(r, '{motivos}', coalesce(r -> 'motivos', '[]'::jsonb) || '"pergunta_repetida:quantidade"'::jsonb);
    end if;
  end if;
  if not coalesce((r ->> 'ok')::boolean, true) then /* texto_saneado */
    v_soft := not exists (select 1 from jsonb_array_elements_text(r -> 'motivos') mm where mm not like 'promessa:%' and mm not like 'pergunta_repetida:%' and mm <> 'preco_nao_verificado');
    if v_soft then
      for v_s in select btrim(x) from regexp_split_to_table(coalesce(p_texto, ''), '(?<=[.!?])\s+|\n+') x where btrim(x) <> '' loop
        if jsonb_array_length(public.agente_saida_base_execucao(p_execucao, v_s) -> 'motivos') = 0
           and coalesce(array_length(public.agente_promessas_indevidas_execucao(p_execucao, v_s), 1), 0) = 0
           and not (v_rep and v_s ~* '(quantos|quantas|qual (é )?a quantidade|que quantidade)' and v_s ~ '\?' and v_s !~* '(cord[aã]o|cord[oõ]es|tirante|brinde)') then
          v_san := v_san || case when v_san = '' then '' else ' ' end || v_s;
        end if;
      end loop;
      r := r || jsonb_build_object('soft_only', true, 'texto_saneado', case when length(v_san) >= 25 then v_san end);
    else
      r := r || jsonb_build_object('soft_only', false);
    end if;
  end if;
  return r;
end;
$function$;

-- ==== public.buscar_produto (md5 c70079bea1a3b28c2be1c235821d7696) ====
CREATE OR REPLACE FUNCTION public.buscar_produto(p_termo text, p_quantidade integer DEFAULT NULL::integer, p_filtros jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_stop constant text[] := array['de','da','do','das','dos','para','pra','com','e','um','uma','uns','umas','quero','queria','preciso','gostaria','orcamento','fazer','tem','voce','voces','vcs','por','favor','me','quanto','custa','valor','preco','em','no','na','o','a','os','as','ai','oi','ola','bom','dia','tarde','noite','mil','unidade','unidades','un'];
  v_norm text := private.norm_busca(p_termo);
  v_variantes text[]; v_alt text; s record; v_qtd integer := nullif(p_quantidade, 0);
  v_opcoes jsonb := '[]'::jsonb; v_sem_sku integer := 0; v_existe boolean := false;
  r record; j jsonb; v_cat text := nullif(btrim(p_filtros ->> 'categoria'), ''); v_cores text := nullif(btrim(p_filtros ->> 'cores'), '');
  v_tam text := nullif(btrim(p_filtros ->> 'tamanho'), ''); v_gram integer := nullif(p_filtros ->> 'gramatura', '')::integer;
  v_faltando text[] := '{}'; v_pergunta text; v_familias integer; v_desc integer; v_tams integer; v_cores_n integer;
  v_exact boolean := false; v_maxscore numeric := 0; v_qtds jsonb; v_toks text[]; v_cat_ok boolean := false;
  v_primeira_cat text; v_cats_ok text[] := '{}'; v_cores_pref text; v_acabamentos jsonb := '[]'::jsonb; v_lote jsonb := null; v_min_exato numeric; v_cmp jsonb := null; v_sm record; v_pk integer; v_escada jsonb := null; /* escada */
begin
  if not private.atendente_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if length(v_norm) < 2 then return jsonb_build_object('ok', false, 'erro', 'termo_vazio'); end if;

  if private.is_staff() and exists (select 1 from public.catalogo c where c.sku = upper(btrim(p_termo))) then
    v_norm := private.norm_busca(upper(btrim(p_termo)));
    select jsonb_agg(jsonb_build_object('sku', c.sku, 'descricao_curta', concat_ws(' ', c.categoria, c.descricao, c.cores, c.tamanho_mm), 'quantidade', c.quantidade,
             'prazo_dias_uteis', c.prazo_dias_uteis, 'preco', (public.calcular_preco(c.sku, 1) ->> 'preco_total')::numeric, 'vendavel', c.vendavel, 'quantidade_exata', true))
      into v_opcoes from public.catalogo c where c.sku = upper(btrim(p_termo));
    return jsonb_build_object('ok', true, 'busca_por_sku', true, 'opcoes', v_opcoes);
  end if;

  v_toks := array(select tok from regexp_split_to_table(v_norm, ' ') tok where tok <> '' and not (tok = any (v_stop)) and tok !~ '^[0-9]+$');

  v_cats_ok := array(select d2.categoria from (select distinct categoria from public.catalogo where active) d2 where private.categoria_bate(d2.categoria, v_toks));
  if cardinality(v_cats_ok) > 1 then v_cats_ok := array(select c from unnest(v_cats_ok) c where private.categoria_pontos(c, v_toks) = (select max(private.categoria_pontos(c2, v_toks)) from unnest(v_cats_ok) c2)); end if;
  if v_tam is null then v_tam := case when v_norm ~ '(^| )a5( |$)' then '150 x 210' when v_norm ~ '(^| )a6( |$)' then '100 x 150' when v_norm ~ '(^| )a4( |$)' then ' x 300' when v_norm ~ '(^| )a3( |$)' then '300 x 420' end; /* tamanho_papel_a */ end if;
  if v_tam is null and v_norm ~ '(^| )[0-9]+([.,][0-9]+)? ?cm( |$)' and v_norm !~ '[0-9] ?x ?[0-9]' then /* tamanho_em_cm */
    select c.tamanho_mm into v_tam from public.catalogo c
     where c.active and c.vendavel and c.preco_venda is not null and (c.categoria = any (v_cats_ok)) and c.tamanho_mm ~ '^[0-9]+ x [0-9]+$'
       and split_part(c.tamanho_mm, ' x ', 1)::int >= round(replace((regexp_match(v_norm, '([0-9]+([.,][0-9]+)?) ?cm'))[1], ',', '.')::numeric * 10)
       and split_part(c.tamanho_mm, ' x ', 2)::int >= round(replace((regexp_match(v_norm, '([0-9]+([.,][0-9]+)?) ?cm'))[1], ',', '.')::numeric * 10)
     order by abs(split_part(c.tamanho_mm, ' x ', 1)::int - split_part(c.tamanho_mm, ' x ', 2)::int), split_part(c.tamanho_mm, ' x ', 1)::int limit 1;
    v_norm := btrim(regexp_replace(v_norm, '(^| )[0-9]+([.,][0-9]+)? ?cm( |$)', ' ', 'g'));
  end if;
  v_norm := btrim(regexp_replace(v_norm, '(^| )a[3-6]( |$)', ' ', 'g'));
  if v_cores is null then /* cores_preferidas */
    v_cores_pref := case
      when v_norm ~ '(^| )4 ?x ?4( |$)' or v_norm ~ 'frente e verso colorid|colorid[oa]? (na )?frente e (no )?verso|colorid[oa]? dos dois lados' then '4X4'
      when v_norm ~ '(^| )4 ?x ?1( |$)' then '4X1'
      when v_norm ~ '(^| )4 ?x ?0( |$)' or v_norm ~ 'colorid[oa]? so (na )?frente|so frente colorid' then '4X0'
      when v_norm ~ '(^| )1 ?x ?1( |$)' then '1X1'
      when v_norm ~ '(^| )1 ?x ?0( |$)' then '1X0' end;
  end if;
  v_variantes := array[v_norm];
  for s in select distinct si.grupo, si.termo from public.sinonimos si where (' ' || v_norm || ' ') like ('% ' || si.termo || ' %') loop
    for v_alt in select si2.termo from public.sinonimos si2 where si2.grupo = s.grupo and si2.termo <> s.termo loop
      v_variantes := array_append(v_variantes, btrim(replace(' ' || v_norm || ' ', ' ' || s.termo || ' ', ' ' || v_alt || ' ')));
    end loop;
  end loop;
  v_variantes := array(select distinct x from unnest(v_variantes) x);
  if v_norm ~ '(^| )(cracha|credencial|identificacao)( |$)' and v_norm ~ '(^| )(pvc|plastico)( |$)' then /* cracha_pvc */
    v_variantes := array(select distinct x from unnest(v_variantes || array['cartao fidelidade plastico compacto', 'pvc branco 050']) x);
  end if;

  create temp table if not exists _bp (id uuid, score numeric) on commit drop;
  truncate _bp;
  insert into _bp
  select id, max(score) from (
    select c.id,
           (count(*) filter (where position(t.tok in c.especificacao_normalizada) > 0))::numeric / nullif(count(*), 0)
             + extensions.similarity(c.especificacao_normalizada, v.variante) * 0.5 as score,
           count(*) filter (where position(t.tok in c.especificacao_normalizada) > 0 and t.tok !~ '^[0-9]+$') as casadas_texto,
           count(*) filter (where position(t.tok in c.especificacao_normalizada) > 0)::numeric / nullif(count(*), 0) as fracao
    from unnest(v_variantes) as v (variante)
    cross join lateral (select tok from regexp_split_to_table(v.variante, ' ') tok where tok <> '' and not (tok = any (v_stop))) t
    join public.catalogo c on c.especificacao_normalizada like '%' || t.tok || '%'
    where c.active and (v_cat is null or c.categoria ilike '%' || v_cat || '%') and (v_cores is null or c.cores ilike v_cores)
      and (v_tam is null or c.tamanho_mm ilike '%' || v_tam || '%') and (v_gram is null or c.gramatura_g = v_gram)
    group by c.id, v.variante, c.especificacao_normalizada
  ) q where casadas_texto >= 1 and fracao >= 0.6
  group by id;

  if not exists (select 1 from _bp) then
    insert into _bp
    select c.id, extensions.similarity(c.especificacao_normalizada, v_norm)
      from public.catalogo c
     where c.active and c.especificacao_normalizada operator(extensions.%) v_norm
       and (v_cat is null or c.categoria ilike '%' || v_cat || '%') and (v_cores is null or c.cores ilike v_cores)
       and (v_tam is null or c.tamanho_mm ilike '%' || v_tam || '%') and (v_gram is null or c.gramatura_g = v_gram)
     order by 2 desc limit 300;
  end if;

  select count(*) into v_sem_sku from _bp b join public.catalogo c on c.id = b.id where c.sku is null;

  create temp table if not exists _bp_fam (id uuid, score numeric, ordem numeric) on commit drop;
  truncate _bp_fam;
  insert into _bp_fam
  select distinct on (c.categoria, c.descricao, c.cores, c.tamanho_mm) c.id, b.score,
         row_number() over (order by b.score desc, c.preco_base_custo)
    from _bp b join public.catalogo c on c.id = b.id
   where c.sku is not null and c.vendavel and c.preco_venda is not null /* preco_oficial_obrigatorio */
   order by c.categoria, c.descricao, c.cores, c.tamanho_mm,
            case when v_qtd is null then c.quantidade else abs(c.quantidade - v_qtd) end, c.quantidade desc;

  select coalesce(max(score), 0) into v_maxscore from _bp_fam;
  v_exact := v_qtd is not null and exists (select 1 from _bp_fam f join public.catalogo c on c.id = f.id where c.quantidade = v_qtd and f.score >= v_maxscore * 0.85 and (cardinality(v_cats_ok) = 0 or c.categoria = any (v_cats_ok))); /* exata_relevante */ /* exata_categoria */
  v_cat_ok := v_exact and cardinality(v_toks) > 0 and exists (
    select 1 from _bp_fam f join public.catalogo c on c.id = f.id where c.quantidade = v_qtd and (c.categoria = any (v_cats_ok)));

  for r in
    with cand as (
      select c.sku, c.categoria, c.descricao, c.cores, c.tamanho_mm, c.tamanho_final, c.gramatura_g, c.quantidade, c.prazo_dias_uteis, c.vendavel, f.score, c.preco_base_custo,
             row_number() over (order by c.preco_base_custo, f.score desc) rn, count(*) over () n
        from _bp_fam f join public.catalogo c on c.id = f.id
       where not exists (select 1 from unnest(array['pvc','plastico','holografica','hotstamping','kraft','metalizad','madeira','acrilico','imantad']) x /* material_exotico */ where position(x in c.especificacao_normalizada) > 0 and position(x in v_norm) = 0 and not (x = 'plastico' and position('pvc' in v_norm) > 0) and not (x = 'pvc' and position('plastico' in v_norm) > 0) and not (x in ('plastico', 'pvc') and v_norm ~ 'cracha') /* pvc_plastico */)
      and ((not v_exact)
          or (c.quantidade = v_qtd and ((v_cat_ok and (c.categoria = any (v_cats_ok)) and f.score >= 0.85 * (select coalesce(max(f2.score), 0) /* relevancia_categoria */ from _bp_fam f2 join public.catalogo c2 on c2.id = f2.id where c2.quantidade = v_qtd and (c2.categoria = any (v_cats_ok)))) or (not v_cat_ok and f.score >= v_maxscore * 0.85))))
    )
    select * from cand
     where true /* opcoes_por_relevancia: as 4 mais baratas entre as relevantes, sem espalhar até o item mais caro */
     order by case when private.norm_busca(categoria) = v_norm then 0 else 1 end /* categoria_igual */, case when categoria = any (v_cats_ok) then 0 else 1 end /* categoria_primeiro */, case when v_qtd is not null and not v_exact and quantidade > greatest(v_qtd * 12, 30) then 1 else 0 end /* lote_razoavel */, case when v_qtd is not null and not v_exact then abs(quantidade - v_qtd) else 0 end, case when v_cores_pref is not null and upper(btrim(coalesce(cores, ''))) = v_cores_pref then 0 else 1 end, case when v_exact then preco_base_custo else 0 end, score desc, preco_base_custo
     limit (case when v_exact then 4 else 5 end)
  loop
    j := public.calcular_preco(r.sku, 1, '{}'::jsonb);
    continue when not coalesce((j ->> 'ok')::boolean, false);
    v_existe := v_existe or (v_qtd is not null and r.quantidade = v_qtd);
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object(
      'sku', r.sku, 'descricao_curta', concat_ws(' ', initcap(lower(r.categoria)), r.descricao, r.cores, case when private.categoria_3d(r.categoria) then r.tamanho_final else r.tamanho_mm end),
      'quantidade', r.quantidade, 'prazo_dias_uteis', r.prazo_dias_uteis, 'preco', (j ->> 'preco_total')::numeric, 'vendavel', r.vendavel,
      'quantidade_exata', v_qtd is not null and r.quantidade = v_qtd, 'tamanho_final', case when private.categoria_3d(r.categoria) then coalesce(r.tamanho_final, 'a confirmar com o cliente (o catálogo só tem o tamanho da arte)') end,
      'em_palavras', private.traduzir_especificacao(r.cores, r.gramatura_g, case when private.categoria_3d(r.categoria) then r.tamanho_final else r.tamanho_mm end, concat_ws(' ', r.categoria, r.descricao))));
    if v_primeira_cat is null then
      v_primeira_cat := r.categoria;
    end if;
  end loop;

  if v_qtd is not null and jsonb_array_length(v_opcoes) > 0 then /* lote_maior */
    select min((o ->> 'preco')::numeric) into v_min_exato from jsonb_array_elements(v_opcoes) o where (o ->> 'quantidade')::integer = v_qtd;
    for r in
      select c.sku, c.categoria, c.descricao, c.cores, c.tamanho_mm, c.tamanho_final, c.gramatura_g, c.quantidade, c.prazo_dias_uteis
        from _bp_fam f join public.catalogo c on c.id = f.id
       where c.quantidade > v_qtd and c.quantidade <= greatest(v_qtd * 20, 100) and f.score >= v_maxscore * 0.85 /* lote_mesma_familia */
         and (v_primeira_cat is null or c.categoria = v_primeira_cat)
         and (v_norm !~ '(^| )(pvc|plastico)( |$)' or c.especificacao_normalizada ~ '(pvc|plastico)')
         and not exists (select 1 from unnest(array['pvc','plastico','holografica','hotstamping','kraft','metalizad','madeira','acrilico','imantad']) x where position(x in c.especificacao_normalizada) > 0 and position(x in v_norm) = 0
                           and not (x = 'plastico' and position('pvc' in v_norm) > 0) and not (x = 'pvc' and position('plastico' in v_norm) > 0))
       order by c.preco_base_custo, f.score desc limit 1
    loop
      j := public.calcular_preco(r.sku, 1, '{}'::jsonb);
      if coalesce((j ->> 'ok')::boolean, false) and (v_min_exato is null or (j ->> 'preco_total')::numeric <= v_min_exato * 1.6) then
        v_lote := jsonb_build_object('sku', r.sku, 'descricao_curta', concat_ws(' ', initcap(lower(r.categoria)), r.descricao, r.cores, r.tamanho_mm),
          'quantidade', r.quantidade, 'preco', (j ->> 'preco_total')::numeric, 'preco_unitario', round((j ->> 'preco_total')::numeric / r.quantidade, 2),
          'prazo_dias_uteis', r.prazo_dias_uteis,
          'em_palavras', private.traduzir_especificacao(r.cores, r.gramatura_g, r.tamanho_mm, concat_ws(' ', r.categoria, r.descricao)));
      end if;
    end loop;
  end if;

  if v_lote is null and not v_existe and v_qtd is not null and v_qtd >= 2 and jsonb_array_length(v_opcoes) > 0 then /* lote_da_familia */ /* so_sem_exato */
    select jsonb_build_object('sku', c4.sku, 'quantidade', c4.quantidade, 'preco', (public.calcular_preco(c4.sku, 1, '{}'::jsonb) ->> 'preco_total')::numeric,
             'descricao_curta', concat_ws(' ', initcap(lower(c4.categoria)), c4.descricao, c4.cores, c4.tamanho_mm), 'prazo_dias_uteis', c4.prazo_dias_uteis)
      into v_lote
      from public.catalogo c4 join public.catalogo c3 on c3.sku = (v_opcoes -> 0 ->> 'sku')
     where c4.active and c4.vendavel and c4.preco_venda is not null and c4.categoria = c3.categoria and c4.descricao = c3.descricao
       and c4.cores is not distinct from c3.cores and c4.tamanho_mm is not distinct from c3.tamanho_mm and c4.quantidade > v_qtd
     order by c4.quantidade asc limit 1;
    if v_lote is not null then v_lote := v_lote || jsonb_build_object('preco_unitario', round((v_lote ->> 'preco')::numeric / (v_lote ->> 'quantidade')::numeric, 2)); end if;
  end if;
  if v_lote is not null and not v_existe and v_qtd is not null and v_qtd >= 2 then /* comparativo_lotes */
    select c2.sku, c2.quantidade into v_sm
      from public.catalogo c2 join public.catalogo c3 on c3.sku = (v_lote ->> 'sku')
     where c2.active and c2.vendavel and c2.preco_venda is not null and c2.categoria = c3.categoria and c2.descricao = c3.descricao
       and c2.cores is not distinct from c3.cores and c2.tamanho_mm is not distinct from c3.tamanho_mm and c2.quantidade < v_qtd
     order by c2.quantidade desc limit 1;
    if found then
      v_pk := ceil(v_qtd::numeric / v_sm.quantidade)::integer;
      j := public.calcular_preco(v_sm.sku, v_pk, '{}'::jsonb);
      if coalesce((j ->> 'ok')::boolean, false) then
        v_cmp := jsonb_build_object('pequeno_sku', v_sm.sku, 'pequeno_lote', v_sm.quantidade, 'pacotes', v_pk, 'total_pequeno', (j ->> 'preco_total')::numeric,
          'lote_sku', v_lote ->> 'sku', 'lote_unidades', (v_lote ->> 'quantidade')::integer, 'lote_total', (v_lote ->> 'preco')::numeric,
          'lote_maior_compensa', (v_lote ->> 'preco')::numeric <= (j ->> 'preco_total')::numeric);
      end if;
    end if;
  end if;

  if jsonb_array_length(v_opcoes) > 0 then v_escada := private.faixas_escada(v_opcoes -> 0 ->> 'sku'); end if;
  -- Acabamentos da categoria
  if v_primeira_cat is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'nome', a.nome,
      'tipo', a.tipo,
      'custo_adicional', a.custo_adicional,
      'dias_adicionais', a.dias_uteis_adicionais,
      'obrigatorio_escolher', a.obrigatorio_escolher,
      'pergunta', a.pergunta_qualificacao
    ) order by a.obrigatorio_escolher desc, a.dias_uteis_adicionais, a.custo_adicional), '[]'::jsonb)
    into v_acabamentos
    from public.produto_acabamentos a
    where a.ativo and (a.categoria ilike '%' || v_primeira_cat || '%' or v_primeira_cat ilike '%' || a.categoria || '%');
  end if;

  select coalesce(jsonb_agg(q order by q), '[]'::jsonb) into v_qtds
    from (select distinct c.quantidade q from _bp b join public.catalogo c on c.id = b.id
           where c.sku is not null and c.vendavel and (not v_cat_ok or (c.categoria = any (v_cats_ok)))) z;

  select count(*), count(distinct descricao), count(distinct tamanho_mm), count(distinct cores)
    into v_familias, v_desc, v_tams, v_cores_n
    from _bp_fam f join public.catalogo c on c.id = f.id;
  if v_qtd is null then v_faltando := array_append(v_faltando, 'quantidade'); end if;
  if v_tams > 1 and v_tam is null then v_faltando := array_append(v_faltando, 'tamanho'); end if;
  if v_desc > 1 and v_familias > 3 then v_faltando := array_append(v_faltando, 'papel'); end if;
  if v_cores_n > 1 and v_cores is null then v_faltando := array_append(v_faltando, 'cores'); end if;
  select q.pergunta into v_pergunta from public.qualificacao_perguntas q where q.campo = any (v_faltando) order by q.ordem limit 1;

  return jsonb_build_object('ok', true, 'opcoes', v_opcoes,
    'acabamentos_disponiveis', v_acabamentos,
    'quantidade_pedida', v_qtd, 'quantidade_pedida_existe', v_existe,
    'quantidades_disponiveis', v_qtds,
    'total_opcoes_na_quantidade', case when v_exact then (select count(*) from _bp_fam f join public.catalogo c on c.id = f.id where c.quantidade = v_qtd and (not v_cat_ok or (c.categoria = any (v_cats_ok)))) end,
    'oferecer_mais_proxima', v_qtd is not null and not v_existe and jsonb_array_length(v_opcoes) > 0,
    'pergunta_qualificacao', case when jsonb_array_length(v_opcoes) = 0 or v_familias > 1 or v_qtd is null then v_pergunta end,
    'alternativa_lote_maior', v_lote,
    'orientacao_quantidade', case
      when v_lote is not null and v_existe then 'Mostre primeiro as opções na quantidade pedida. Depois, em uma frase, apresente o lote maior (alternativa_lote_maior): total R$ ' || private.fmt_reais_at((v_lote ->> 'preco')::numeric) || ' para ' || (v_lote ->> 'quantidade') || ' unidades (R$ ' || private.fmt_reais_at((v_lote ->> 'preco_unitario')::numeric) || ' cada), e pergunte qual ele prefere. Use só os valores da ferramenta.'
      when v_lote is not null then 'Esse produto não é vendido em ' || v_qtd || ' unidades. Explique em linguagem simples que o menor lote é de ' || (v_lote ->> 'quantidade') || ' unidades, por R$ ' || private.fmt_reais_at((v_lote ->> 'preco')::numeric) || ' no total (R$ ' || private.fmt_reais_at((v_lote ->> 'preco_unitario')::numeric) || ' cada), que costuma compensar e sobra para reposição, e pergunte se ele prefere o lote ou outra opção. Nunca diga só que o mínimo é essa quantidade.'
      end,
    'comparativo_lotes', v_cmp,
    'faixas_sugeridas', v_escada,
    'orientacao_faixas', case when v_escada is not null then 'Mostre também as faixas maiores para o cliente ver a unidade cair: ' || (select string_agg(format('%s un por R$ %s (R$ %s cada)', e ->> 'quantidade', private.fmt_reais_at((e ->> 'preco')::numeric), private.fmt_reais_at((e ->> 'preco_unitario')::numeric)), '; ' order by (e ->> 'quantidade')::integer) from jsonb_array_elements(v_escada) e) || '. Use só estes valores e pergunte qual faixa prefere.' end,
    'orientacao_comparativo', case when v_cmp is not null then 'Para ' || v_qtd || ' unidades existem duas formas: ' || (v_cmp ->> 'pacotes') || ' pacote(s) de ' || (v_cmp ->> 'pequeno_lote') || ' unidade(s) por R$ ' || private.fmt_reais_at((v_cmp ->> 'total_pequeno')::numeric) || ', ou 1 lote de ' || (v_cmp ->> 'lote_unidades') || ' unidades por R$ ' || private.fmt_reais_at((v_cmp ->> 'lote_total')::numeric) || case when (v_cmp ->> 'lote_maior_compensa')::boolean then ' (o lote maior sai mais barato e ainda sobram peças para reposição)' else '' end || '. Mostre as duas e recomende a mais vantajosa. Para orçar, a quantidade em montar_orcamento é o número de pacotes do SKU escolhido.' end,
    'itens_sem_sku_encontrados', v_sem_sku,
    'orientacao', case when jsonb_array_length(v_opcoes) = 0 then case when v_sem_sku > 0 then 'sem_sku_chamar_dono_alta' else 'nao_encontrado_chamar_dono_alta' end end);
end;
$function$;

-- ==== public.financeiro_mp (md5 760d626943b90a372415ef04ae0e16ce) ====
CREATE OR REPLACE FUNCTION public.financeiro_mp(p_de date, p_ate date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_de timestamptz := (p_de::timestamp at time zone 'America/Sao_Paulo'); v_ate timestamptz := ((p_ate + 1)::timestamp at time zone 'America/Sao_Paulo'); r jsonb;
begin
  if not private.is_admin() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select jsonb_build_object(
    'recebimentos', count(*) filter (where tipo = 'recebimento'),
    'bruto', coalesce(sum(bruto) filter (where tipo = 'recebimento'), 0),
    'taxas', coalesce(sum(taxa) filter (where tipo = 'recebimento'), 0),
    'liquido', coalesce(sum(coalesce(liquido, bruto - taxa)) filter (where tipo = 'recebimento'), 0),
    'estornos', coalesce(sum(estornado), 0),
    'sem_pedido', count(*) filter (where tipo = 'recebimento' and order_id is null),
    'pendentes', count(*) filter (where tipo = 'pendente'),
    'ultima_atualizacao', max(atualizado_em)
  ) into r from public.mp_movimentos where data >= v_de and data < v_ate;
  return r || jsonb_build_object('saldo', (select to_jsonb(s) - 'id' from public.mp_saldo_historico s order by capturado_em desc limit 1));
end $function$;

-- ==== public.followup_agendar (md5 38b34296c647f27a3a5c538a10e85aa7) ====
CREATE OR REPLACE FUNCTION public.followup_agendar(p_agora timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_orc integer := 0; v_pag integer := 0; v_pos integer := 0; r record; q record; v_n integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  for r in select * from public.followup_regras where ativo and referencia = 'orcamento_enviado' loop
    insert into public.followup_fila (contact_id, conversation_id, orcamento_id, regra_codigo, chave, agendado_para, teste, produto)
    select o.contact_id, o.conversation_id, o.id, r.codigo, r.codigo || ':' || o.id::text,
           private.fu_proxima_janela(o.pdf_enviado_em + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max), o.teste,
           (select left(i.descricao, 80) from public.orcamento_itens i where i.orcamento_id = o.id order by i.criado_em limit 1)
      from public.orcamentos o
     where o.status = 'enviado' and o.pdf_enviado_em is not null and o.origem_id is null and o.pdf_enviado_em > p_agora - interval '10 days'
       and not exists (select 1 from public.conversations cv where cv.id = o.conversation_id and cv.last_inbound_at > o.pdf_enviado_em + interval '1 minute')
    on conflict (chave) do nothing;
    get diagnostics v_n = row_count; v_orc := v_orc + v_n;
  end loop;
  for r in select * from public.followup_regras where ativo and referencia = 'link_pagamento' loop
    insert into public.followup_fila (contact_id, conversation_id, orcamento_id, order_id, regra_codigo, chave, agendado_para, teste)
    select ord.contact_id, ord.conversation_id,
           (select oc.id from public.orcamentos oc where oc.order_id = ord.id order by oc.criado_em desc limit 1), ord.id,
           r.codigo, r.codigo || ':' || ord.id::text,
           private.fu_proxima_janela(p.criado_em + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max), coalesce(ord.teste, false)
      from public.pagamentos p join public.orders ord on ord.id = p.order_id
     where p.eh_link and p.link_ativo and p.status = 'pendente' and (p.expira_em is null or p.expira_em > p_agora)
       and ord.payment_status <> 'aprovado' and ord.stage in ('novo', 'cotando', 'aguardando_pagamento')
       and p.criado_em > p_agora - interval '3 days'
    on conflict (chave) do nothing;
    get diagnostics v_n = row_count; v_pag := v_pag + v_n;
  end loop;
  for r in select * from public.followup_regras where ativo and referencia = 'conversa_parada' loop /* conversa_parada */
    insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, teste)
    select cv.contact_id, cv.id, r.codigo, r.codigo || ':' || cv.id::text || ':' || (extract(epoch from cv.last_inbound_at))::bigint::text,
           case when r.codigo = 'Q1' then private.fu_proxima_janela(ult.criado + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max)
                else private.fu_q2_horario(cv.last_inbound_at + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max) end,
           'teste' = any (coalesce(ct.tags, '{}'))
      from public.conversations cv join public.contacts ct on ct.id = cv.contact_id
      cross join lateral (select m.created_at as criado, m.direction as dir from public.messages m where m.conversation_id = cv.id order by m.created_at desc limit 1) ult
     where cv.last_inbound_at is not null and cv.last_inbound_at > p_agora - interval '23 hours'
       and ult.dir = 'out' and ult.criado > cv.last_inbound_at and not exists (select 1 from public.orders xo where xo.contact_id = cv.contact_id and xo.excluido_em is null and xo.created_at > p_agora - interval '10 days') /* q_sem_pedido */
       and coalesce(cv.modo_atendimento, 'ia') = 'ia' and coalesce(cv.ai_handled, true) /* q_quente */
       and not coalesce(ct.optout, false)
       and not exists (select 1 from public.orcamentos o where o.contact_id = cv.contact_id and o.status in ('enviado', 'aceito', 'pago') and o.criado_em > p_agora - interval '10 days')
       and not exists (select 1 from public.orders x where x.contact_id = cv.contact_id and x.excluido_em is null and x.stage in ('pago', 'arte', 'prova', 'producao', 'entregue') and coalesce(x.paid_at, x.created_at) > p_agora - interval '30 days')
       and (r.codigo <> 'Q2' or ult.criado < p_agora - interval '3 hours')
    on conflict (chave) do nothing;
    get diagnostics v_n = row_count; v_orc := v_orc + v_n;
  end loop;
  for q in select id from public.orders where stage = 'entregue' and delivered_at > p_agora - interval '120 days' loop
    v_pos := v_pos + private.fu_agendar_pos(q.id, p_agora);
  end loop;
  return jsonb_build_object('ok', true, 'orcamento', v_orc, 'pagamento', v_pag, 'pos', v_pos);
end;
$function$;

-- ==== public.followup_montar (md5 43879aaef5fb43d9c7354795ec151593) ====
CREATE OR REPLACE FUNCTION public.followup_montar(p_fila uuid, p_agora timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  f public.followup_fila%rowtype; r public.followup_regras%rowtype; o public.orcamentos%rowtype; ord public.orders%rowtype; ct public.contacts%rowtype; cv public.conversations%rowtype;
  c public.condicoes_especiais%rowtype; n text; v_num text; v_val text; v_pronto text; v_prod text; v_link text; v_var integer; v_janela boolean; v_texto text; v_tpl text; v_params jsonb;
  v_up text; v_cond_vigente boolean := false; v_ped text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into f from public.followup_fila where id = p_fila;
  if not found then return jsonb_build_object('ok', false, 'acao', 'pular', 'motivo', 'fila_inexistente'); end if;
  select * into r from public.followup_regras where codigo = f.regra_codigo;
  select * into ct from public.contacts where id = f.contact_id;
  select * into cv from public.conversations where id = coalesce(f.conversation_id, (select id from public.conversations where contact_id = f.contact_id limit 1));
  select * into o from public.orcamentos where id = f.orcamento_id;
  select * into ord from public.orders where id = f.order_id;
  n := private.fu_nome(ct.name);
  v_var := abs(hashtext(f.id::text)) % 2;
  v_janela := cv.last_inbound_at is not null and cv.last_inbound_at + interval '24 hours' > p_agora;
  v_num := case when o.id is not null then private.orcamento_numero(o.numero) end;
  v_ped := case when ord.id is not null then 'SG-' || lpad(ord.number::text, 4, '0') end;
  v_val := case when o.validade_ate is not null then to_char(o.validade_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"') else 'a data combinada' end;
  v_pronto := to_char(o.data_prevista, 'DD/MM');
  v_prod := coalesce(f.produto, (select left(i.descricao, 80) from public.orcamento_itens i where i.orcamento_id = o.id order by i.criado_em limit 1), 'pedido');

  if f.regra_codigo in ('F3', 'F4', 'PAG_24H') then
    select * into c from public.condicoes_especiais
     where (orcamento_id = f.orcamento_id or orcamento_novo_id = f.orcamento_id) and resultado = 'oferecida' and valida_ate > p_agora
       and (f.regra_codigo = 'PAG_24H' or (gatilho = r.gatilho_condicao and criado_em >= coalesce(f.reservado_em, f.criado_em) - interval '2 minutes') or id = f.condicao_id)
     order by criado_em desc limit 1;
    v_cond_vigente := found;
    if v_cond_vigente and f.regra_codigo <> 'PAG_24H' then update public.followup_fila set condicao_id = c.id where id = f.id; end if;
  end if;

  if f.regra_codigo = 'F1' then
    v_texto := case v_var
      when 0 then format('Oi, %s! Passando pra saber se ficou alguma dúvida sobre o orçamento %s. A gente cuida da arte e entrega com data certa. Se quiser ajustar quantidade, acabamento ou prazo, é só me falar que eu resolvo rapidinho.', n, v_num)
      else format('Oi, %s! Conseguiu dar uma olhada no orçamento %s? Qualquer dúvida sobre o material ou a arte, me chama por aqui que eu te ajudo.%s', n, v_num,
                  case when o.data_prevista is not null then ' Fechando, o pedido fica pronto dia ' || v_pronto || '.' else '' end) end;
  elsif f.regra_codigo = 'F2' then
    v_texto := format('Oi, %s! O orçamento %s vale até %s%s. Quer que eu reenvie o link de pagamento?', n, v_num, v_val,
                      case when o.data_prevista is not null then ', e fechando hoje ele fica pronto dia ' || v_pronto else '' end);
    v_tpl := 'orcamento_vence_hoje'; v_params := jsonb_build_array(n, v_num, v_val);
  elsif f.regra_codigo in ('F3', 'F4') and v_cond_vigente then
    v_link := coalesce(c.link_pagamento, (select oc.link_pagamento from public.orcamentos oc where oc.id = c.orcamento_novo_id));
    v_texto := format('Oi, %s! %s no seu orçamento %s: %s. Vale até %s.%s', n,
                      case when f.regra_codigo = 'F4' then 'Última chamada, consegui uma condição especial' else 'Consegui uma condição especial' end, v_num, c.texto_curto,
                      to_char(c.valida_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"'),
                      case when v_link is not null then ' Segue o link atualizado: ' || v_link else ' Quer que eu envie o link de pagamento atualizado?' end);
    v_tpl := 'condicao_especial_orcamento'; v_params := jsonb_build_array(n, v_num, c.texto_curto, to_char(c.valida_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"'));
  elsif f.regra_codigo = 'F3' then
    v_texto := format('Oi, %s! Seu orçamento %s vale até %s. Dá pra fechar e garantir a entrega no prazo. Quer que eu reenvie o link de pagamento?', n, v_num, v_val);
    v_tpl := 'orcamento_vence_hoje'; v_params := jsonb_build_array(n, v_num, v_val);
  elsif f.regra_codigo = 'F4' then
    v_texto := format('Oi, %s, passando pra saber se ainda faz sentido seguir com o seu pedido de %s. Se quiser ajustar quantidade ou acabamento, me chama por aqui que a gente resolve rápido.', n, v_prod);
    v_tpl := 'ultima_chance_orcamento'; v_params := jsonb_build_array(n, v_prod);
  elsif f.regra_codigo in ('Q1', 'Q2') and private.fu_texto_q(f.regra_codigo, cv.id, n, v_var) is not null then /* q_sem_eco */
    v_texto := private.fu_texto_q(f.regra_codigo, cv.id, n, v_var);
  elsif f.regra_codigo = 'Q1' and false then /* q_assunto */
    v_texto := case v_var
      when 0 then format('Oi, %s! Voltando ao nosso papo: %s Se já tiver o que precisa, me manda que eu monto o seu orçamento agora.', n, private.fu_ultima_pergunta(cv.id))
      else format('Oi, %s! Só pra gente não perder o fio: %s Me responde por aqui que eu já avanço com o seu pedido.', n, private.fu_ultima_pergunta(cv.id)) end;
  elsif f.regra_codigo = 'Q2' and false then
    v_texto := format('Oi, %s! Ainda consigo te ajudar com isso: %s Se me responder, eu já te mando o orçamento ainda hoje.', n, private.fu_ultima_pergunta(cv.id));
  elsif f.regra_codigo = 'Q1' and (private.ficha_respostas(cv.id) ->> 'quantidade_informada') is not null then /* q_qtd_sabida */
    v_texto := format('Oi, %s! Com as %s unidades que você me falou, já consigo montar o seu orçamento agora. Posso seguir?', n, private.ficha_respostas(cv.id) ->> 'quantidade_informada');
  elsif f.regra_codigo = 'Q1' then /* conversa_parada */
    v_texto := case v_var
      when 0 then format('Oi, %s! Passando pra saber se deu pra ver o que te mandei. Me conta só o que falta que eu já fecho o seu orçamento e te mando o PDF ainda hoje, combinado?', n) /* q1_v2 */
      else format('Oi, %s! Ainda tá precisando disso? Se me confirmar a quantidade e se já tem a arte, eu monto o orçamento agora mesmo.', n) end;
  elsif f.regra_codigo = 'Q2' then
    v_texto := format('Oi, %s! Ainda consigo te ajudar com o seu pedido? Se me passar só o que falta, eu já te mando o orçamento ainda hoje.', n);
  elsif f.regra_codigo like 'PAG_%' then
    select p.link into v_link from public.pagamentos p where p.order_id = f.order_id and p.eh_link and p.link_ativo and p.status = 'pendente' order by p.criado_em desc limit 1;
    v_num := coalesce(v_num, v_ped);
    if v_link is null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'link_inativo'); end if;
    v_texto := case f.regra_codigo
      when 'PAG_1H' then format('Oi, %s! Seu orçamento %s está aguardando o pagamento. O link é %s. Se precisar de ajuda, é só responder por aqui.', n, v_num, v_link)
      when 'PAG_6H' then format('Oi, %s! Só lembrando do pagamento do orçamento %s: %s. Se surgiu alguma dúvida, me fala que eu resolvo.', n, v_num, v_link)
      else format('Oi, %s! Seu orçamento %s ainda está aguardando o pagamento: %s.%s', n, v_num, v_link,
                  case when v_cond_vigente then ' A condição especial vale só até ' || to_char(c.valida_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"') || ' e depois volta ao preço normal.' else ' Se precisar de ajuda, é só responder por aqui.' end) end;
    v_tpl := 'pagamento_pendente'; v_params := jsonb_build_array(n, v_num, v_link);
  elsif f.regra_codigo = 'POS_ENTREGA' then
    if ord.id is null or ord.stage is distinct from 'entregue' then
      return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'pedido_nao_esta_entregue');
    end if;
    v_up := case upper(extensions.unaccent(coalesce(f.produto, '')))
      when '' then 'Se precisar de mais alguma coisa, é só chamar por aqui.'
      else case when upper(extensions.unaccent(f.produto)) like '%CARTA%' then 'Aproveita e me fala se quer adesivos ou panfletos combinando com o cartão.'
                when upper(extensions.unaccent(f.produto)) like '%ADESIV%' then 'Se quiser, já monto também um cartão de visita combinando.'
                when upper(extensions.unaccent(f.produto)) like '%PANFLET%' or upper(extensions.unaccent(f.produto)) like '%FLYER%' then 'Se quiser, já monto também cartões ou adesivos combinando.'
                else 'Se precisar de mais alguma coisa, é só chamar por aqui.' end end;
    v_texto := format('Oi, %s! Seu pedido %s foi entregue. Obrigado pela confiança! Deu tudo certo? Se puder, avalie a Sua Gráfica BH no Google, leva 1 minuto: https://g.page/r/CZ6eNNGjdgO4EAE/review %s Vamos te avisar por aqui de novidades e promoções. Se não quiser, é só responder PARAR.', n, v_ped, v_up);
    v_tpl := 'pos_venda_avaliacao'; v_params := jsonb_build_array(n, v_ped);
  elsif f.regra_codigo like 'RECOMPRA_%' then
    if ord.id is not null and ord.stage not in ('entregue', 'recompra') then
      return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'pedido_nao_concluido');
    end if;
    v_prod := coalesce(f.produto, 'pedido');
    v_texto := format('Oi, %s! Já faz um tempinho desde o seu pedido de %s. Quer repor ou incluir algo novo? Me responde por aqui que eu monto o orçamento rapidinho.', n, v_prod);
    v_tpl := 'recompra_lembrete'; v_params := jsonb_build_array(n, v_prod);
  else
    return jsonb_build_object('ok', false, 'acao', 'pular', 'motivo', 'regra_sem_texto');
  end if;

  if not v_janela and v_tpl is null then
    return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'janela_fechada');
  end if;
  return jsonb_build_object('ok', true, 'acao', 'enviar', 'via', case when v_janela then 'livre' else 'template' end,
    'texto', v_texto, 'template', v_tpl, 'params', v_params, 'conversation_id', cv.id, 'regra', f.regra_codigo,
    'janela_ate', cv.last_inbound_at + interval '24 hours', 'com_condicao', v_cond_vigente and f.regra_codigo <> 'PAG_24H',
    'simular', 'teste' = any (coalesce(ct.tags, '{}')) or f.teste);
end;
$function$;

-- ==== public.followup_reservar (md5 b61b2fd30ad1d3cb47f5fa233915eccc) ====
CREATE OR REPLACE FUNCTION public.followup_reservar(p_familia text, p_limite integer DEFAULT 20, p_agora timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  f public.followup_fila%rowtype; r public.followup_regras%rowtype; o public.orcamentos%rowtype; ord public.orders%rowtype; ct public.contacts%rowtype; cv public.conversations%rowtype;
  v_cfg jsonb := private.fu_cfg(); v_max integer := coalesce((v_cfg ->> 'max_por_dia')::integer, 1);
  v_itens jsonb := '[]'::jsonb; v_motivo text; v_novo timestamptz; v_hoje date := (p_agora at time zone 'America/Sao_Paulo')::date; v_cadencia boolean := p_familia = 'cadencia';
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_familia not in ('cadencia', 'pos') then raise exception 'Família inválida.'; end if;
  for f in
    select * from public.followup_fila
     where status = 'pendente' and agendado_para <= p_agora
       and ((v_cadencia and regra_codigo ~ '^(F[1-4]|PAG_|Q[1-2])') or (not v_cadencia and regra_codigo ~ '^(POS_|RECOMPRA_)'))
     order by agendado_para limit greatest(p_limite, 1) for update skip locked
  loop
    v_motivo := null; v_novo := null;
    select * into r from public.followup_regras where codigo = f.regra_codigo;
    select * into ct from public.contacts where id = f.contact_id;
    select * into cv from public.conversations where id = coalesce(f.conversation_id, (select id from public.conversations where contact_id = f.contact_id limit 1));
    select * into o from public.orcamentos where id = f.orcamento_id;
    select * into ord from public.orders where id = f.order_id;

    if not coalesce(r.ativo, false) then v_motivo := 'regra_inativa';
    elsif coalesce(ct.optout, false) then v_motivo := 'optout';
    elsif v_cadencia and (
        coalesce(o.status, '') = 'pago' or coalesce(ord.payment_status, '') = 'aprovado' or coalesce(ord.payment_manual, false)
        or exists (select 1 from public.orders x where x.contact_id = f.contact_id and x.stage in ('pago', 'arte', 'prova', 'producao', 'entregue')
                      and coalesce(x.paid_at, x.created_at) >= coalesce(o.pdf_enviado_em, o.criado_em, f.criado_em))) then v_motivo := 'pago';
    elsif v_cadencia and f.regra_codigo ~ '^F[1-4]$' and (o.id is null or o.status not in ('enviado', 'aceito')) then v_motivo := 'orcamento_encerrado';
    elsif v_cadencia and f.regra_codigo ~ '^F[1-4]$' and o.validade_ate is not null and o.validade_ate < p_agora then v_motivo := 'orcamento_vencido';
    elsif v_cadencia and f.regra_codigo ~ '^PAG_' and not exists (
        select 1 from public.pagamentos p where p.order_id = f.order_id and p.eh_link and p.link_ativo and p.status = 'pendente' and (p.expira_em is null or p.expira_em > p_agora)) then v_motivo := 'link_inativo';
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and cv.last_inbound_at > f.criado_em then v_motivo := 'cliente_respondeu'; /* conversa_parada */
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and exists (select 1 from public.orders xo where xo.contact_id = f.contact_id and xo.excluido_em is null and xo.created_at > p_agora - interval '10 days') then v_motivo := 'pedido_existente'; /* q_sem_pedido */
    elsif v_cadencia and f.regra_codigo = 'Q2' and exists (select 1 from public.followup_fila x where x.contact_id = f.contact_id and x.regra_codigo = 'Q1' and x.status in ('enviado', 'reservado') and coalesce(x.enviado_em, x.reservado_em) > p_agora - interval '6 hours') then v_motivo := 'q1_recente';
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and (cv.last_inbound_at is null or cv.last_inbound_at + interval '24 hours' < p_agora) then v_motivo := 'janela_fechada';
    elsif v_cadencia and f.regra_codigo ~ '^Q[1-2]$' and exists (select 1 from public.orcamentos oo where oo.contact_id = f.contact_id and oo.status in ('enviado', 'aceito') and oo.criado_em > p_agora - interval '10 days') then v_motivo := 'orcamento_enviado';
    elsif v_cadencia and coalesce(cv.modo_atendimento, 'ia') <> 'ia' then v_motivo := 'modo_humano';
    elsif not v_cadencia and f.regra_codigo like 'RECOMPRA_%' and exists (
        select 1 from public.orders x join public.order_items xi on xi.order_id = x.id join public.catalogo xc on xc.sku = xi.code
         where x.contact_id = f.contact_id and x.id <> f.order_id and x.created_at > coalesce(ord.delivered_at, ord.stage_entered_at)
           and upper(extensions.unaccent(coalesce(xc.grupo_produto, xc.categoria, ''))) like upper(extensions.unaccent(split_part(coalesce(f.grupo_produto, ''), ' ', 1))) || '%') then v_motivo := 'recomprou';
    elsif not v_cadencia and f.regra_codigo like 'RECOMPRA_%' and ct.marketing_consent = 'opted_out' then v_motivo := 'optout';
    end if;
    if v_motivo is not null then
      update public.followup_fila set status = case when v_motivo in ('modo_humano', 'link_inativo') then 'pulado' else 'cancelado' end, motivo = v_motivo where id = f.id;
      continue;
    end if;

    if private.fu_pausada() then v_novo := p_agora + interval '60 minutes';
    elsif extract(hour from p_agora at time zone 'America/Sao_Paulo') < r.hora_min or extract(hour from p_agora at time zone 'America/Sao_Paulo') >= r.hora_max then
      v_novo := private.fu_proxima_janela(p_agora, r.hora_min, r.hora_max);
    elsif f.regra_codigo !~ '^Q' and (select count(*) from public.followup_fila x where x.contact_id = f.contact_id and x.id <> f.id and x.status in ('enviado', 'reservado')
             and (coalesce(x.enviado_em, x.reservado_em) at time zone 'America/Sao_Paulo')::date = v_hoje) >= v_max then
      v_novo := private.fu_proxima_janela((date_trunc('day', p_agora at time zone 'America/Sao_Paulo') + interval '1 day' + make_interval(hours => r.hora_min)) at time zone 'America/Sao_Paulo', r.hora_min, r.hora_max);
    end if;
    if v_novo is not null then
      update public.followup_fila set agendado_para = greatest(v_novo, p_agora + interval '1 minute'), motivo = 'adiado' where id = f.id;
      continue;
    end if;

    update public.followup_fila set status = 'reservado', reservado_em = p_agora, tentativas = tentativas + 1, motivo = null where id = f.id;
    v_itens := v_itens || jsonb_build_object(
      'fila_id', f.id, 'regra', f.regra_codigo, 'tentativa', f.tentativas + 1,
      'gatilho', r.gatilho_condicao, 'precisa_condicao', r.gatilho_condicao is not null and f.condicao_id is null,
      'orcamento_id', f.orcamento_id, 'conversation_id', cv.id, 'contact_id', f.contact_id,
      'simular', 'teste' = any (coalesce(ct.tags, '{}')) or f.teste);
  end loop;
  return jsonb_build_object('ok', true, 'itens', v_itens);
end;
$function$;

-- ==== public.montar_orcamento (md5 9aece6e93e1926ec6a240c14b3b5731c) ====
CREATE OR REPLACE FUNCTION public.montar_orcamento(p_contact uuid, p_itens jsonb, p_opcoes jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  pr public.parametros_comerciais%rowtype;
  v_cfg jsonb := coalesce((select value from public.app_settings where key = 'orcamento_agente'), '{}'::jsonb);
  v_max_pacotes integer := coalesce((v_cfg ->> 'pacotes_max_linha')::integer, 100);
  v_max_unid numeric := coalesce((v_cfg ->> 'unidades_max')::numeric, 50000);
  v_valor_alerta numeric := coalesce((v_cfg ->> 'valor_alerta')::numeric, 10000);
  v_unid numeric := 0;
  v_opc jsonb := coalesce(p_opcoes, '{}'::jsonb);
  v_local text := nullif(btrim(coalesce(v_opc ->> 'cep', v_opc ->> 'bairro', '')), '');
  v_arte text := coalesce(nullif(v_opc ->> 'arte', ''), 'nenhuma');
  v_metodo text := nullif(v_opc ->> 'metodo', '');
  v_conv uuid := nullif(v_opc ->> 'conversation_id', '')::uuid;
  v_teste boolean := coalesce((v_opc ->> 'teste')::boolean, false);
  v_data_evento date := nullif(btrim(v_opc ->> 'data_evento'), '')::date;
  v_seg text;
  it jsonb; r jsonb; fr jsonb; pz jsonb;
  v_skus text[] := '{}'; v_qtds integer[] := '{}'; v_calcs jsonb[] := '{}';
  v_acabs text[] := '{}'; v_acab_custos numeric[] := '{}'; v_acab_dias integer[] := '{}';
  v_larguras integer[] := '{}'; v_alturas integer[] := '{}'; v_areas numeric[] := '{}';
  v_sku text; v_qtd integer; v_lote_cat integer; v_i integer; v_acab_nome text;
  v_acab_custo numeric := 0; v_acab_dia integer := 0; v_frete_nac numeric := 0; v_acab_real text := '';
  v_larg integer; v_alt integer; v_bg record; v_rb jsonb;
  v_valor_itens numeric := 0; v_itens_frete jsonb := '[]'::jsonb;
  v_frete_modo text := 'retirada'; v_entrega text := 'retirada';
  v_avisos text[] := '{}'; v_arte_valor numeric := 0;
  v_pronto date; v_frase text; v_up jsonb;
  v_id uuid; v_num bigint; v_val jsonb; v_fin jsonb; v_unit numeric;
  v_pior text := 'alta'; v_tem_baixa boolean := false; v_tem_media boolean := false;
  v_itens_out jsonb := '[]'::jsonb; v_cep text; v_validade timestamptz; v_total numeric; v_frete_txt text;
  v_pub_avisos text[]; v_exib jsonb; v_dias_max_acab integer := 0;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  if not exists (select 1 from public.contacts where id = p_contact) then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'contato_nao_encontrado', 'alternativa', 'Confirme o contato antes de orçar.');
  end if;
  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) not between 1 and 10 then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'alternativa', 'Informe de 1 a 10 itens com SKU e quantidade.');
  end if;
  if v_arte not in ('nenhuma', 'cliente', 'paga', 'com_frete') then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'arte_invalida', 'alternativa', 'Escolha: nenhuma, cliente, paga ou com_frete.');
  end if;
  select segment into v_seg from public.contacts where id = p_contact;

  for it in select * from jsonb_array_elements(p_itens) loop
    v_sku := upper(btrim(coalesce(it ->> 'sku', '')));
    if nullif(btrim(coalesce(it ->> 'quantidade', '')), '') is not null and btrim(it ->> 'quantidade') !~ '^[1-9][0-9]*$' then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'quantidade_invalida', 'alternativa', 'A quantidade é o número INTEIRO de pacotes do SKU (cada SKU tem a sua quantidade fixa). Nunca use fração. Se a quantidade exata do cliente não existir, ofereça a opção mais próxima que a busca devolveu.');
    end if;
    v_qtd := coalesce((it ->> 'quantidade')::integer, 1);
    if exists (select 1 from public.catalogo cx where cx.sku = v_sku and cx.preco_venda is null) then /* preco_oficial_obrigatorio */
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'sem_preco_oficial', 'alternativa', 'Esse item não tem preço oficial na planilha. Ofereça o produto mais próximo que a busca devolveu e continue o atendimento.');
    end if;
    v_acab_nome := nullif(btrim(it ->> 'acabamento'), '');
    v_larg := nullif((it ->> 'largura_mm')::integer, 0);
    v_alt := nullif((it ->> 'altura_mm')::integer, 0);

    select coalesce(c.quantidade, 1) into v_lote_cat from public.catalogo c where c.sku = v_sku;
    if v_lote_cat >= 5 and v_qtd >= v_lote_cat and mod(v_qtd, v_lote_cat) = 0 then
      v_qtd := v_qtd / v_lote_cat;
    end if;

    if v_sku = '' or v_qtd < 1 or v_qtd > v_max_pacotes then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'alternativa', 'Cada item precisa de SKU e quantidade de 1 a ' || v_max_pacotes || ' pacotes.');
    end if;

    r := public.calcular_preco(v_sku, v_qtd, jsonb_build_object('metodo', v_metodo, 'largura_mm', v_larg, 'altura_mm', v_alt));
    if not coalesce((r ->> 'ok')::boolean, false) then
      if r ->> 'erro' = 'sku_nao_encontrado' then
        return jsonb_build_object('status', 'bloqueado', 'motivo', 'sku_nao_encontrado',
                                  'alternativa', 'Busque o SKU correto usando buscar_produto antes de chamar montar_orcamento.');
      end if;
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'item_indisponivel', 'alternativa', 'Ofereça outro item do catálogo.');
    end if;

    if v_larg is null and coalesce(v_opc ->> 'nao_otimizar_lote', '') <> 'true' then /* lote_maior_barato */
      -- Se o lote maior do mesmo produto custa menos que os pacotes pedidos, usa o lote maior (o cliente leva mais unidades por menos).
      select c2.sku, c2.quantidade into v_bg from public.catalogo c2 join public.catalogo c1 on c1.sku = v_sku
       where c2.active and c2.vendavel and c2.preco_venda is not null and c2.categoria = c1.categoria and c2.descricao = c1.descricao
         and c2.cores is not distinct from c1.cores and c2.tamanho_mm is not distinct from c1.tamanho_mm
         and c2.quantidade > coalesce(v_lote_cat, 1) * v_qtd and c2.quantidade <= greatest(coalesce(v_lote_cat, 1) * v_qtd * 3, 10)
       order by c2.quantidade asc limit 1;
      if found then
        v_rb := public.calcular_preco(v_bg.sku, 1, jsonb_build_object('metodo', v_metodo, 'largura_mm', v_larg, 'altura_mm', v_alt));
        if coalesce((v_rb ->> 'ok')::boolean, false) and (v_rb ->> 'preco_total')::numeric <= (r ->> 'preco_total')::numeric then
          v_avisos := array_append(v_avisos, 'lote_maior_mais_barato');
          v_sku := v_bg.sku; v_qtd := 1; v_lote_cat := v_bg.quantidade; r := v_rb;
        end if;
      end if;
    end if;
    v_acab_custo := 0.00;
    v_acab_dia := 0;
    v_acab_real := coalesce(v_acab_nome, '');
    if v_acab_nome is not null then
      select nome, coalesce(custo_adicional, 0.00), coalesce(dias_uteis_adicionais, 0)
        into v_acab_real, v_acab_custo, v_acab_dia
        from public.produto_acabamentos
       where ativo and (nome ilike '%' || v_acab_nome || '%' or v_acab_nome ilike '%' || nome || '%') 
       limit 1;
      if not found then
        v_acab_custo := 0.00;
        v_acab_dia := 0;
        v_acab_real := v_acab_nome;
      end if;
    end if;

    v_unid := v_unid + v_qtd * coalesce(v_lote_cat, 1);
    v_skus := v_skus || v_sku; 
    v_qtds := v_qtds || v_qtd;
    v_acabs := v_acabs || v_acab_real;
    v_acab_custos := v_acab_custos || v_acab_custo;
    v_acab_dias := v_acab_dias || v_acab_dia;
    v_larguras := v_larguras || coalesce(v_larg, 0);
    v_alturas := v_alturas || coalesce(v_alt, 0);
    v_areas := v_areas || coalesce((r ->> 'area_m2_por_unidade')::numeric, 0.000);
    
    if v_acab_dia > v_dias_max_acab then
      v_dias_max_acab := v_acab_dia;
    end if;

    v_valor_itens := v_valor_itens + (r ->> 'preco_total')::numeric + (v_acab_custo * v_qtd);
    v_itens_frete := v_itens_frete || jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', v_qtd));
  end loop;

  if v_unid > v_max_unid then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'quantidade_irreal',
                              'alternativa', 'Quantidade acima do que a produção atende de uma vez.');
  end if;

  if v_local is not null then
    fr := public.verificar_frete(v_local, v_itens_frete, v_valor_itens, v_arte = 'com_frete');
    if coalesce((fr ->> 'frete_gratis')::boolean, false) then v_frete_modo := 'bike_gratis'; v_entrega := 'bike'; else v_frete_modo := 'uber_cliente'; end if;
    if (fr ->> 'dimensao_desconhecida')::boolean then v_avisos := array_append(v_avisos, 'frete_a_confirmar'); end if;
  end if;

  if v_arte = 'com_frete' and v_frete_modo <> 'bike_gratis' then
    v_arte := 'paga'; v_avisos := array_append(v_avisos, 'arte_com_frete_indisponivel');
  end if;
  v_arte_valor := case v_arte when 'paga' then pr.arte_valor when 'com_frete' then pr.arte_frete_valor else 0 end;

  v_cep := case when v_local ~ '^\s*\d{5}-?\d{3}\s*$' then regexp_replace(v_local, '\D', '', 'g') end;
  v_validade := now() + make_interval(hours => pr.validade_orcamento_horas);
  if v_cep is not null then /* frete_correios */
    if nullif(v_opc ->> 'frete_servico', '') is not null then
      select c.valor into v_frete_nac from public.frete_cotacoes c where c.conversation_id = v_conv and c.cep = v_cep and c.servico = lower(v_opc ->> 'frete_servico') and c.criado_em > now() - interval '3 days' order by c.criado_em desc limit 1;
      if v_frete_nac is null then
        return jsonb_build_object('status', 'bloqueado', 'motivo', 'frete_sem_cotacao', 'alternativa', 'Consulte verificar_frete com o CEP do cliente e confirme PAC ou SEDEX antes de orçar.');
      end if;
      v_frete_modo := 'correios'; v_entrega := 'uber';
    elsif v_frete_modo <> 'bike_gratis' and exists (select 1 from public.frete_cotacoes c where c.conversation_id = v_conv and c.cep = v_cep and c.criado_em > now() - interval '3 days') then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'escolher_frete', 'alternativa', 'O cliente é de fora de BH: pergunte se prefere PAC ou SEDEX (valores de verificar_frete) e envie frete_servico em opcoes.');
    end if;
  end if;

  for v_i in 1 .. cardinality(v_skus) loop
    r := public.calcular_preco(v_skus[v_i], v_qtds[v_i], jsonb_build_object('metodo', v_metodo, 'entrega', case when v_entrega = 'bike' then 'bike' end, 'largura_mm', v_larguras[v_i], 'altura_mm', v_alturas[v_i]));
    v_calcs := v_calcs || r;
    if (r ->> 'confianca') = 'baixa' then v_tem_baixa := true; elsif (r ->> 'confianca') = 'media' then v_tem_media := true; end if;
  end loop;
  v_pior := case when v_tem_baixa then 'baixa' when v_tem_media then 'media' else 'alta' end;

  for v_i in 1 .. cardinality(v_skus) loop
    pz := public.calcular_prazo(v_skus[v_i], now(), false);
    if coalesce((pz ->> 'ok')::boolean, false) and (v_pronto is null or (pz ->> 'data_pronto')::date > v_pronto) then
      v_pronto := (pz ->> 'data_pronto')::date; v_frase := pz ->> 'frase';
    end if;
  end loop;

  if v_dias_max_acab > 0 and v_pronto is not null then
    v_pronto := public.add_business_days(v_pronto, v_dias_max_acab);
    v_frase := coalesce(v_frase, '') || ' (+ ' || v_dias_max_acab || ' dia útil do acabamento)';
  end if;

  if v_pronto is null then v_avisos := array_append(v_avisos, 'prazo_a_confirmar'); end if;

  if v_data_evento is not null and v_pronto is not null then
    if v_pronto > v_data_evento then
      v_avisos := array_append(v_avisos, 'prazo_estoura_data_evento');
    elsif v_pronto = v_data_evento then
      v_avisos := array_append(v_avisos, 'prazo_no_limite_do_evento');
    end if;
  end if;

  v_up := private.upsell_regra(v_skus, v_seg, v_arte);

  insert into public.orcamentos (contact_id, conversation_id, status, entrega, bairro, cep, metodo_previsto, arte_modo, arte_valor, frete_valor,
                                 validade_ate, frete_modo, upsell_tipo, upsell_texto, data_prevista, data_evento, avisos, teste, regra_preco, confianca_preco)
  values (p_contact, v_conv, 'rascunho', v_entrega, case when v_cep is null then v_local end, v_cep, v_metodo, v_arte, v_arte_valor, v_frete_nac,
          v_validade, v_frete_modo, v_up ->> 'tipo', v_up ->> 'texto', v_pronto, v_data_evento, to_jsonb(v_avisos), v_teste,
          (v_calcs[1] ->> 'regra'), v_pior)
  returning id, numero into v_id, v_num;

  for v_i in 1 .. cardinality(v_skus) loop
    r := v_calcs[v_i];
    v_unit := ceil(((r ->> 'preco_total')::numeric + (v_acab_custos[v_i] * v_qtds[v_i])) / v_qtds[v_i] * 100) / 100;
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, acabamento, acabamento_custo, acabamento_dias_adicionais,
                                        largura_mm, altura_mm, area_m2,
                                        regra_preco, confianca_preco, margem_liquida_pct,
                                        consulta_mercado_id, mercado_mediana, fontes_mercado, nao_competitivo, piso, piso_duro, lucro_liquido, especificacao)
    values (v_id, v_skus[v_i], (select descricao from public.catalogo where sku = v_skus[v_i]), v_qtds[v_i], v_unit,
            nullif(v_acabs[v_i], ''), v_acab_custos[v_i], v_acab_dias[v_i],
            nullif(v_larguras[v_i], 0), nullif(v_alturas[v_i], 0), nullif(v_areas[v_i], 0),
            r ->> 'regra', r ->> 'confianca', (r ->> 'margem_liquida_pct')::numeric,
            nullif(r ->> 'consulta_mercado_id', '')::uuid, (r ->> 'mercado_mediana')::numeric, (r ->> 'fontes_mercado')::integer,
            coalesce((r ->> 'nao_competitivo')::boolean, false), (r ->> 'piso')::numeric, (r ->> 'piso_duro')::numeric, (r ->> 'lucro_liquido')::numeric,
            private.especificacao_publica(v_skus[v_i]));
  end loop;

  v_val := public.validar_margem(v_id);
  if v_val ->> 'status' <> 'ok' then
    delete from public.orcamentos where id = v_id;
    return jsonb_build_object('status', 'bloqueado', 'motivo', v_val ->> 'motivo',
                              'alternativa', 'Sugira uma especificação mais simples ou outra quantidade.');
  end if;

  v_fin := private.orcamento_financeiro(v_id);
  update public.orcamentos set custo_total = (v_fin ->> 'custo')::numeric + (v_fin ->> 'extra')::numeric,
         lucro_liquido = (v_fin ->> 'lucro')::numeric,
         margem_liquida_pct = round((v_fin ->> 'lucro')::numeric / nullif((v_fin ->> 'receita')::numeric, 0) * 100, 1)
   where id = v_id;
  select total into v_total from public.orcamentos where id = v_id;

  select jsonb_agg(jsonb_build_object('descricao', g.descricao, 'especificacao', g.especificacao, 'quantidade', g.unidades,
                                      'acabamento', g.acabamento,
                                      'area_m2', g.area_m2,
                                      'valor_unitario', round(g.total / g.unidades, 4), 'valor_total', round(g.total, 2)) order by g.ordem)
    into v_exib
    from (select i.descricao, regexp_replace(coalesce(i.especificacao, ''), '^\s*[0-9.]+\s*un\.?\s*·\s*', '') as especificacao,
                 i.acabamento, i.area_m2,
                 sum(i.quantidade * coalesce(c.quantidade, 1)) as unidades,
                 sum(i.quantidade * i.preco_unitario) as total, min(i.criado_em) as ordem, count(*) as linhas
            from public.orcamento_itens i left join public.catalogo c on c.sku = i.sku
           where i.orcamento_id = v_id group by 1, 2, 3, 4) g;

  if exists (select 1 from public.orcamento_itens i where i.orcamento_id = v_id group by i.descricao, regexp_replace(coalesce(i.especificacao, ''), '^\s*[0-9.]+\s*un\.?\s*·\s*', '') having count(*) > 1)
     and v_exib is not null and jsonb_array_length(v_exib) between 1 and 10 then
    update public.orcamentos set itens_exibicao = v_exib where id = v_id;
  end if;

  if v_total > v_valor_alerta then
    perform public.alerta_criar('orcamento_valor_alto', 'alta', p_contact, v_conv, null,
                                'Orçamento de R$ ' || to_char(v_total, 'FM999G999G990D00') || ' montado pelo agente.',
                                jsonb_build_object('orcamento_id', v_id), 'valor_alto:' || v_id::text, array['whatsapp']);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'especificacao', i.especificacao, 'quantidade', i.quantidade,
                                               'acabamento', i.acabamento, 'area_m2', i.area_m2,
                                               'valor_unitario', i.preco_unitario, 'valor_total', i.quantidade * i.preco_unitario) order by i.criado_em, i.id), '[]'::jsonb)
    into v_itens_out from public.orcamento_itens i where i.orcamento_id = v_id;

  v_frete_txt := case v_frete_modo
    when 'bike_gratis' then 'Entrega grátis na região central, em horário comercial.'
    when 'uber_cliente' then 'Entrega por Uber Entrega, por conta do cliente. A retirada é grátis.' when 'correios' then 'Envio pelos Correios (' || upper(coalesce(v_opc ->> 'frete_servico', '')) || '), por conta do cliente, somado ao total.'
    else 'Retirada grátis no centro de BH.' end;
  v_pub_avisos := array(select a from unnest(v_avisos) a where a in ('arte_com_frete_indisponivel', 'frete_a_confirmar', 'prazo_a_confirmar', 'prazo_estoura_data_evento', 'prazo_no_limite_do_evento', 'faturamento_minimo_1m2', 'lote_maior_mais_barato'));

  return jsonb_build_object(
    'status', 'ok', 'orcamento_id', v_id, 'numero', private.orcamento_numero(v_num),
    'itens', v_itens_out, 'subtotal', (select subtotal from public.orcamentos where id = v_id),
    'arte', jsonb_build_object('modo', v_arte, 'valor', v_arte_valor),
    'opcoes_arte', case when v_arte = 'nenhuma' then jsonb_build_array(
        jsonb_build_object('modo', 'paga', 'valor', pr.arte_valor, 'texto', 'Só a arte'),
        jsonb_build_object('modo', 'com_frete', 'valor', pr.arte_frete_valor, 'texto', 'Arte com frete grátis na região central',
                           'disponivel', v_frete_modo = 'bike_gratis' or v_local is null)) end,
    'frete', jsonb_build_object('modo', case v_frete_modo when 'bike_gratis' then 'entrega_gratis' else v_frete_modo end, 'valor', v_frete_nac, 'texto', v_frete_txt),
    'total', v_total, 'data_prevista', v_pronto, 'data_prevista_br', to_char(v_pronto, 'DD/MM'), 'prazo', v_frase, 'validade_ate', v_validade,
    'upsell', v_up, 'avisos', to_jsonb(v_pub_avisos),
    'resumo_composto', case when jsonb_array_length(v_itens_out) > 1 then private.resumo_composto(v_id) end /* resumo_composto */);
end;
$function$;

-- ==== public.mp_movimentos_vincular (md5 86117197180ba183acd9e8441f0eb5af) ====
CREATE OR REPLACE FUNCTION public.mp_movimentos_vincular()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_n integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.mp_movimentos m set order_id = o.id
    from public.orders o
   where m.order_id is null and m.referencia ~ '^SG-[0-9]+' and o.number = (regexp_replace(m.referencia, '^SG-([0-9]+).*$', '\1'))::bigint;
  get diagnostics v_n = row_count;
  return v_n;
end $function$;
