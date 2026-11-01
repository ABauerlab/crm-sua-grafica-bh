-- Etapa 7B, Bloco B: agente, conversa e conversão. Aditiva e idempotente.
-- B1 debounce de 10 s com prolongamento, B3 dados do cliente, B5 três opções, B6 setores, B7 promessas indevidas,
-- B9 motivo de perda, B10 BauerLab, B11 validador de pedido.

-- ---------------------------------------------------------------- B1. debounce de 10 s
update public.agente_config set debounce_segundos = 10 where id = 1 and debounce_segundos = 8;
alter table public.agente_config alter column debounce_segundos set default 10;

-- A API oficial do WhatsApp NÃO entrega "digitando..." do cliente. A alternativa: se a última mensagem parece incompleta, espera mais.
create or replace function private.mensagem_incompleta(p_tipo text, p_corpo text) returns boolean
language sql immutable set search_path = ''
as $$
  select case
    when coalesce(p_tipo, 'text') in ('audio', 'image', 'document', 'video') and length(trim(coalesce(p_corpo, ''))) < 3 then true   -- só áudio ou arquivo
    when trim(coalesce(p_corpo, '')) ~ '\?\s*$' and length(trim(p_corpo)) >= 12 then false                                           -- pergunta completa: responde já
    when trim(coalesce(p_corpo, '')) ~ '[:,;]\s*$' then true
    when lower(trim(coalesce(p_corpo, ''))) ~ '(^|\s)(e|então|entao|tipo|ou|mas|que|pra|para|com|de|do|da|um|uma|por|se|quando|porque|pq|tb|também)\s*$' then true
    else false end;
$$;

drop function if exists public.agente_debounce(uuid);
create or replace function public.agente_debounce(p_message uuid, p_esperar boolean default true) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  m record; v_corte timestamptz; v_msgs jsonb; v_primeira timestamptz; v_extra numeric; v_prolongou boolean := false;
begin
  select * into m from public.messages where id = p_message;
  if not found then return jsonb_build_object('ultima', false); end if;
  if exists (select 1 from public.messages x where x.conversation_id = m.conversation_id and x.direction = 'in' and (x.created_at, x.id) > (m.created_at, m.id)) then
    update public.agente_execucoes set status = 'agrupada', motivo = 'agrupada_com_mensagem_seguinte', finalizado_em = now() where message_id = p_message;
    return jsonb_build_object('ultima', false);
  end if;

  select max(created_at) into v_corte from public.messages where conversation_id = m.conversation_id and direction = 'out';
  -- mensagem que parece incompleta: espera mais, até 60 s no total desde a primeira mensagem sem resposta
  if p_esperar and private.mensagem_incompleta(m.type, m.body) then
    select min(created_at) into v_primeira from public.messages where conversation_id = m.conversation_id and direction = 'in' and created_at > coalesce(v_corte, '-infinity'::timestamptz);
    v_extra := least(20, greatest(0, 60 - extract(epoch from (now() - coalesce(v_primeira, now())))));
    if v_extra > 0.5 then
      perform pg_sleep(v_extra);
      v_prolongou := true;
      if exists (select 1 from public.messages x where x.conversation_id = m.conversation_id and x.direction = 'in' and (x.created_at, x.id) > (m.created_at, m.id)) then
        update public.agente_execucoes set status = 'agrupada', motivo = 'agrupada_com_mensagem_seguinte', finalizado_em = now() where message_id = p_message;
        return jsonb_build_object('ultima', false, 'prolongou', true);
      end if;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'tipo', t.type, 'corpo', t.body, 'media_id', t.media_id) order by t.created_at), '[]'::jsonb)
  into v_msgs
  from (select id, type, body, media_id, created_at from public.messages
        where conversation_id = m.conversation_id and direction = 'in' and created_at > coalesce(v_corte, '-infinity'::timestamptz)
        order by created_at desc limit 10) t;
  return jsonb_build_object('ultima', true, 'mensagens', v_msgs, 'conversation_id', m.conversation_id, 'prolongou', v_prolongou);
end;
$$;
revoke execute on function public.agente_debounce(uuid, boolean) from public, anon, authenticated;
grant execute on function public.agente_debounce(uuid, boolean) to service_role;

-- ---------------------------------------------------------------- B3. dados do cliente: só o que falta, consentimento separado
create or replace function public.agente_salvar_contato(p_contact uuid, p_dados jsonb) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  d jsonb := coalesce(p_dados, '{}'::jsonb);
  c public.contacts%rowtype;
  v_nome text := nullif(left(trim(d ->> 'nome'), 80), '');
  v_emp text := nullif(left(trim(d ->> 'empresa'), 80), '');
  v_seg text := nullif(left(trim(d ->> 'segmento'), 60), '');
  v_bairro text := nullif(left(trim(d ->> 'bairro'), 60), '');
  v_email text := nullif(lower(left(trim(d ->> 'email'), 120)), '');
  v_doc text := nullif(regexp_replace(coalesce(d ->> 'documento', ''), '\D', '', 'g'), '');
  v_end text := nullif(left(trim(d ->> 'endereco'), 200), '');
  v_cep text := nullif(regexp_replace(coalesce(d ->> 'cep', ''), '\D', '', 'g'), '');
  v_qtd integer; v_interesse text := nullif(left(trim(d ->> 'interesse'), 120), '');
  v_arte text := lower(nullif(trim(d ->> 'tem_arte'), ''));
  v_nf boolean := coalesce(lower(d ->> 'nota_fiscal') in ('true', 'sim', 's'), false);
  v_entrega boolean := coalesce(lower(d ->> 'entrega') in ('true', 'sim', 's'), false);
  v_cons text := lower(nullif(trim(d ->> 'consentimento_promocoes'), ''));
  v_urg text := nullif(left(trim(d ->> 'urgencia'), 200), '');
  v_salvo text[] := '{}'; v_ignorado text[] := '{}'; v_falta text[] := '{}'; v_dados jsonb := '{}'::jsonb;
begin
  select * into c from public.contacts where id = p_contact;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'contato_inexistente'); end if;
  begin v_qtd := nullif(trim(d ->> 'quantidade'), '')::integer; exception when others then v_qtd := null; end;
  if v_qtd is not null and (v_qtd < 1 or v_qtd > 10000000) then v_qtd := null; end if;
  if v_cep is not null and length(v_cep) <> 8 then v_cep := null; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email := null; end if;
  if v_doc is not null and length(v_doc) not in (11, 14) then v_doc := null; end if;
  if v_arte is not null then v_arte := case when v_arte in ('sim', 'true', 's', 'tem') then 'sim' when v_arte in ('nao', 'não', 'false', 'n') then 'nao' else null end; end if;
  -- CPF ou CNPJ e endereço só quando o cliente quer nota fiscal ou entrega
  if v_doc is not null and not v_nf then v_doc := null; v_ignorado := array_append(v_ignorado, 'documento_sem_nota_fiscal'); end if;
  if v_end is not null and not (v_nf or v_entrega) then v_end := null; v_ignorado := array_append(v_ignorado, 'endereco_sem_entrega_ou_nota'); end if;

  update public.contacts set
    name = coalesce(v_nome, name), company = coalesce(v_emp, company), segment = coalesce(v_seg, segment), bairro = coalesce(v_bairro, bairro),
    email = coalesce(v_email, email), document = coalesce(v_doc, document), address = coalesce(v_end, address), cep = coalesce(v_cep, cep),
    status_lead = case when status_lead = 'novo' then 'qualificando' else status_lead end
  where id = p_contact;
  if v_nome is not null then v_salvo := array_append(v_salvo, 'nome'); end if;
  if v_emp is not null then v_salvo := array_append(v_salvo, 'empresa'); end if;
  if v_seg is not null then v_salvo := array_append(v_salvo, 'segmento'); end if;
  if v_bairro is not null then v_salvo := array_append(v_salvo, 'bairro'); end if;
  if v_email is not null then v_salvo := array_append(v_salvo, 'email'); end if;
  if v_doc is not null then v_salvo := array_append(v_salvo, 'documento'); end if;
  if v_end is not null then v_salvo := array_append(v_salvo, 'endereco'); end if;
  if v_cep is not null then v_salvo := array_append(v_salvo, 'cep'); end if;
  if v_interesse is not null then v_dados := v_dados || jsonb_build_object('interesse', v_interesse); v_salvo := array_append(v_salvo, 'interesse'); end if;
  if v_qtd is not null then v_dados := v_dados || jsonb_build_object('quantidade', v_qtd); v_salvo := array_append(v_salvo, 'quantidade'); end if;
  if v_arte is not null then v_dados := v_dados || jsonb_build_object('tem_arte', v_arte); v_salvo := array_append(v_salvo, 'tem_arte'); end if;
  if v_nf then v_dados := v_dados || jsonb_build_object('nota_fiscal', true); end if;
  if v_dados <> '{}'::jsonb then
    update public.conversations set collected_data = coalesce(collected_data, '{}'::jsonb) || v_dados where contact_id = p_contact;
  end if;

  -- Consentimento de promoções: pergunta separada, nunca presumida, nunca reverte quem pediu para parar
  if v_cons in ('sim', 'nao', 'não') then
    if v_cons = 'sim' and c.marketing_consent <> 'opted_out' then
      update public.contacts set marketing_consent = 'opted_in', marketing_consent_at = now(), marketing_consent_source = 'whatsapp' where id = p_contact;
      v_salvo := array_append(v_salvo, 'consentimento_promocoes');
    elsif v_cons = 'sim' then
      v_ignorado := array_append(v_ignorado, 'consentimento_ignorado_pediu_para_parar');
    else
      update public.conversations set collected_data = coalesce(collected_data, '{}'::jsonb) || '{"promocoes_recusou": true}'::jsonb where contact_id = p_contact;
    end if;
  end if;
  if v_urg is not null then perform public.registrar_urgencia(p_contact, v_urg, true); v_salvo := array_append(v_salvo, 'urgencia'); end if;

  -- o que ainda falta (o agente pergunta só isso, nunca repete o que já sabe)
  select * into c from public.contacts where id = p_contact;
  if coalesce(c.name, '') = '' then v_falta := array_append(v_falta, 'nome'); end if;
  if coalesce(c.company, '') = '' then v_falta := array_append(v_falta, 'empresa'); end if;
  if coalesce(c.segment, '') = '' then v_falta := array_append(v_falta, 'segmento'); end if;
  if v_nf or coalesce((select collected_data ->> 'nota_fiscal' from public.conversations where contact_id = p_contact), '') = 'true' then
    if coalesce(c.document, '') = '' then v_falta := array_append(v_falta, 'documento'); end if;
    if coalesce(c.email, '') = '' then v_falta := array_append(v_falta, 'email'); end if;
  end if;
  if (v_nf or v_entrega) and coalesce(c.address, '') = '' then v_falta := array_append(v_falta, 'endereco'); end if;
  return jsonb_build_object('ok', true, 'salvo', to_jsonb(v_salvo), 'ignorado', to_jsonb(v_ignorado), 'falta', to_jsonb(v_falta),
    'consentimento_promocoes', c.marketing_consent = 'opted_in', 'perguntar_promocoes', c.marketing_consent = 'none');
end;
$$;
revoke execute on function public.agente_salvar_contato(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.agente_salvar_contato(uuid, jsonb) to service_role;

-- ---------------------------------------------------------------- B6. setores e escalonamento
alter table public.conversations add column if not exists setor text check (setor in ('comercial', 'arte', 'financeiro', 'dono'));
alter table public.tasks add column if not exists setor text check (setor in ('comercial', 'arte', 'financeiro', 'dono'));
alter table public.alertas add column if not exists setor text check (setor in ('comercial', 'arte', 'financeiro', 'dono'));

create or replace function public.agente_encaminhar_setor(p_conversation uuid, p_setor text, p_motivo text, p_resumo text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_cv public.conversations%rowtype; v_setor text := lower(trim(coalesce(p_setor, ''))); v_motivo text := left(trim(coalesce(p_motivo, '')), 300);
  v_resumo text := left(trim(coalesce(p_resumo, '')), 600); v_acao text; v_hist jsonb; v_ord record; v_al jsonb; v_grave boolean;
  v_pag jsonb := null;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if v_setor not in ('comercial', 'arte', 'financeiro', 'dono') then return jsonb_build_object('ok', false, 'motivo', 'setor_invalido'); end if;
  select * into v_cv from public.conversations where id = p_conversation;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'conversa_inexistente'); end if;
  -- reclamação, cancelamento, reembolso, divergência, exceção urgente ou fornecedor sem confirmar vão para o dono
  v_grave := lower(v_motivo || ' ' || v_resumo) ~ '(reclama|cancel|reembols|estorn|diverg|urgen|fornecedor|defeito|errad|atras|problema|insatisf)';
  if v_grave then v_setor := 'dono'; end if;
  update public.conversations set setor = v_setor where id = p_conversation;
  select o.id, o.number, o.payment_status, o.paid_at, o.stage, o.art_status into v_ord from public.orders o
   where o.contact_id = v_cv.contact_id and o.excluido_em is null order by o.created_at desc limit 1;
  select coalesce(jsonb_agg(left(t.body, 140) order by t.created_at), '[]'::jsonb) into v_hist
    from (select body, created_at from public.messages where conversation_id = p_conversation and body is not null order by created_at desc limit 5) t;

  if v_setor = 'financeiro' then
    -- o sistema responde sozinho com o que está no banco (sincronizado com o Mercado Pago pelo webhook); nada inventado
    v_pag := jsonb_build_object('pedido', case when v_ord.id is null then null else 'SG-' || lpad(v_ord.number::text, 4, '0') end,
      'pagamento', coalesce(v_ord.payment_status::text, 'sem_pedido'), 'pago_em', v_ord.paid_at,
      'orientacao', case when v_ord.id is null then 'Ainda não há pedido. Envie o orçamento antes.'
                         when v_ord.payment_status = 'aprovado' then 'O pagamento está confirmado no sistema.'
                         else 'O pagamento ainda não aparece como confirmado. Peça um instante, confira com a ferramenta de pagamento e, se o cliente garantir que pagou, chame o dono.' end);
    v_acao := 'Conferir o pagamento no Mercado Pago';
  elsif v_setor = 'arte' then
    insert into public.tasks (title, contact_id, order_id, kind, priority, setor, due_at) values ('Arte: ' || left(v_motivo, 120), v_cv.contact_id, v_ord.id, 'aprovar_prova', 'alta', 'arte', now() + interval '4 hours');
    v_acao := 'Conferir arquivos e aprovação na fila de arte';
  elsif v_setor = 'comercial' then
    v_acao := 'Continuar a venda: orçamento, negociação e fechamento';
  else
    v_acao := case when v_motivo ~* 'reembols|estorn' then 'Decidir o reembolso no Mercado Pago (o agente não promete reembolso)'
                   when v_motivo ~* 'cancel' then 'Entender o motivo do cancelamento e decidir'
                   when v_motivo ~* 'reclama|defeito|errad|insatisf|problema' then 'Ligar ou responder pessoalmente, com tom profissional'
                   else 'Assumir a conversa' end;
    update public.conversations set needs_human = true where id = p_conversation;
    v_al := public.alerta_criar('encaminhado_dono', 'alta', v_cv.contact_id, p_conversation, v_ord.id,
      left('Encaminhado ao dono: ' || v_motivo, 200), jsonb_build_object('setor', 'dono', 'resumo', v_resumo, 'motivo', v_motivo, 'acao_recomendada', v_acao, 'historico', v_hist),
      'setor_dono:' || p_conversation::text || ':' || to_char(date_trunc('hour', now()), 'YYYYMMDDHH24'));
    if v_al ->> 'alerta_id' is not null then update public.alertas set setor = 'dono' where id = (v_al ->> 'alerta_id')::uuid; end if;
  end if;
  return jsonb_build_object('ok', true, 'setor', v_setor, 'acao_recomendada', v_acao, 'financeiro', v_pag, 'dono_chamado', v_setor = 'dono',
    'orientacao', case when v_setor = 'dono' then 'Diga ao cliente que vai passar o caso para o responsável e que ele retorna em breve. Não prometa solução, reembolso nem prazo e não repita perguntas que o CRM já responde.' else null end);
end;
$$;
revoke execute on function public.agente_encaminhar_setor(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.agente_encaminhar_setor(uuid, text, text, text) to service_role;

-- ---------------------------------------------------------------- B7. promessas indevidas (camada determinística, além do prompt)
create or replace function public.agente_promessas_indevidas(p_execucao uuid, p_texto text) returns text[]
language plpgsql stable security definer set search_path = ''
as $$
declare
  t text := lower(coalesce(p_texto, '')); v_contato uuid; v_motivos text[] := '{}'; v_ord record; v_orc record; v_cond boolean;
  v_cond_txt boolean;
begin
  select contact_id into v_contato from public.agente_execucoes where id = p_execucao;
  select o.* into v_ord from public.orders o where o.contact_id = v_contato and o.excluido_em is null and o.cancelado_em is null order by o.created_at desc limit 1;
  select oc.* into v_orc from public.orcamentos oc where oc.contact_id = v_contato and oc.status in ('rascunho', 'enviado', 'aceito', 'pago') order by oc.criado_em desc limit 1;
  -- frases condicionais ("assim que o pagamento for confirmado") não são afirmações
  v_cond_txt := t ~ '(assim que|quando|depois que|após|apos|logo que|caso|se o|se a|assim q)[^.!?]{0,70}(pagamento|pix|arte|produção|producao)';

  -- pagamento: só afirma com pedido pago no sistema
  if t ~ '(pagamento|pix|pagto)\s+(já\s+)?(foi\s+|está\s+|esta\s+)?(confirmad|aprovad|recebid|identificad|compensad)' or t ~ 'recebemos\s+(o\s+)?(seu\s+)?(pagamento|pix)' or t ~ 'já\s+(caiu|foi\s+pago|consta\s+como\s+pago)' then
    if not v_cond_txt and coalesce(v_ord.payment_status::text, '') <> 'aprovado' then v_motivos := array_append(v_motivos, 'promessa:pagamento_sem_confirmacao'); end if;
  end if;
  -- arte aprovada
  if t ~ '(sua\s+)?arte\s+(já\s+)?(foi\s+|está\s+|esta\s+|ficou\s+)?aprovada' or t ~ 'aprovamos\s+(a|sua)\s+arte' then
    if not v_cond_txt and coalesce(v_ord.art_status::text, '') <> 'aprovada' then v_motivos := array_append(v_motivos, 'promessa:arte_aprovada_sem_status'); end if;
  end if;
  -- produção
  if t ~ '(entrou|foi|está|esta|já\s+está|ja\s+esta)\s+(em|para\s+a?)\s+produ[cç][aã]o' or t ~ 'começamos\s+a\s+produzir|produ[cç][aã]o\s+iniciada|já\s+estamos\s+produzindo' then
    if not v_cond_txt and coalesce(v_ord.stage::text, '') <> 'producao' then v_motivos := array_append(v_motivos, 'promessa:producao_sem_status'); end if;
  end if;
  -- conclusão / entrega
  if t ~ '(seu\s+pedido\s+)?(já\s+)?(está|esta|ficou)\s+pronto|foi\s+entregue|saiu\s+para\s+(a\s+)?entrega|já\s+pode\s+(retirar|buscar)' then
    if not v_cond_txt and coalesce(v_ord.subestatus_pedido, '') not in ('pronto_retirada', 'saiu_entrega') and coalesce(v_ord.stage::text, '') not in ('entregue', 'recompra') then
      v_motivos := array_append(v_motivos, 'promessa:conclusao_sem_status');
    end if;
  end if;
  -- data de pronto: só a que a ferramenta deu (data prevista do orçamento ou do pedido)
  if t ~ 'fica(rá)?\s+pronto[^.!?]{0,60}(dia\s+\d{1,2}|\d{1,2}/\d{1,2}|amanhã|amanha|hoje|segunda|terça|terca|quarta|quinta|sexta)' then
    if not (
      (v_orc.data_prevista is not null and t ~ ('dia\s+0?' || extract(day from v_orc.data_prevista)::int::text || '(\D|$)'))
      or (v_ord.due_date is not null and t ~ ('dia\s+0?' || extract(day from v_ord.due_date)::int::text || '(\D|$)'))
      or (v_orc.data_prevista is not null and t ~ ('0?' || extract(day from v_orc.data_prevista)::int::text || '/0?' || extract(month from v_orc.data_prevista)::int::text))
    ) then v_motivos := array_append(v_motivos, 'promessa:data_que_a_ferramenta_nao_deu'); end if;
  end if;
  -- desconto fora da função (condição especial vigente libera)
  select exists (select 1 from public.condicoes_especiais c join public.orcamentos o on o.id = c.orcamento_id
                  where o.contact_id = v_contato and c.resultado <> 'cancelada' and c.valida_ate > now() - interval '1 hour') into v_cond;
  if t ~ '(\d+\s*%\s*(de\s+)?desconto|desconto\s+de\s+\d|abatimento|faço\s+por\s+r\$|fecho\s+por\s+r\$|brinde|ganha\s+(um|uma)\s+\w+\s+de\s+brinde)' and not v_cond then
    v_motivos := array_append(v_motivos, 'promessa:desconto_fora_da_funcao');
  end if;
  -- reembolso
  if t ~ '(vamos|iremos|irei|vou|podemos|posso|faremos|farei)\s+(fazer\s+)?(o\s+|um\s+)?(reembolso|estorno|ressarcimento)' or t ~ '(devolv(o|emos|eremos)|ressarcir)\s' or t ~ 'seu\s+(dinheiro|valor)\s+(será|vai\s+ser|sera)\s+devolvido' or t ~ 'reembolso\s+(garantido|aprovado)' then
    v_motivos := array_append(v_motivos, 'promessa:reembolso');
  end if;
  return v_motivos;
end;
$$;
revoke execute on function public.agente_promessas_indevidas(uuid, text) from public, anon, authenticated;
grant execute on function public.agente_promessas_indevidas(uuid, text) to service_role;

create or replace function public.agente_saida_segura(p_execucao uuid, p_texto text) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  r jsonb := public.agente_saida_base(p_execucao, p_texto);
  v_prom text[];
begin
  if coalesce(p_texto, '') ~* '(calling tools?\s*:|control_token|default_api|\mcall_[0-9]{4,}|tool_call)' then
    r := jsonb_set(r, '{ok}', 'false'::jsonb);
    r := jsonb_set(r, '{motivos}', coalesce(r -> 'motivos', '[]'::jsonb) || '"vazamento:chamada_de_ferramenta"'::jsonb);
  end if;
  v_prom := public.agente_promessas_indevidas(p_execucao, p_texto);
  if array_length(v_prom, 1) > 0 then
    r := jsonb_set(r, '{ok}', 'false'::jsonb);
    r := jsonb_set(r, '{motivos}', coalesce(r -> 'motivos', '[]'::jsonb) || to_jsonb(v_prom));
  end if;
  return r;
end;
$$;
revoke execute on function public.agente_saida_segura(uuid, text) from public, anon, authenticated;
grant execute on function public.agente_saida_segura(uuid, text) to service_role;

-- ---------------------------------------------------------------- B9. motivo da perda e estratégia de recuperação
alter table public.orcamentos add column if not exists motivo_perda text check (motivo_perda in ('preco', 'prazo', 'sumiu', 'decidiu_depois', 'abandonou_checkout', 'outro'));
alter table public.orcamentos add column if not exists motivo_perda_em timestamptz;

create table if not exists public.estrategia_recuperacao (
  motivo text not null check (motivo in ('preco', 'prazo', 'sumiu', 'decidiu_depois', 'abandonou_checkout', 'outro')),
  ordem smallint not null,
  passo text not null check (passo in ('esclarecer', 'alternativa_real', 'pix', 'parcelar_2x', 'condicao_especial', 'lembrar_prazo', 'ajudar_checkout', 'esperar')),
  primary key (motivo, ordem)
);
alter table public.estrategia_recuperacao enable row level security;
drop policy if exists estrategia_recuperacao_dono on public.estrategia_recuperacao;
create policy estrategia_recuperacao_dono on public.estrategia_recuperacao for select to authenticated using (private.is_staff());
-- a condição especial é sempre o ÚLTIMO degrau e só pela função de desconto
insert into public.estrategia_recuperacao (motivo, ordem, passo) values
  ('preco', 1, 'esclarecer'), ('preco', 2, 'alternativa_real'), ('preco', 3, 'pix'), ('preco', 4, 'parcelar_2x'), ('preco', 5, 'condicao_especial'),
  ('prazo', 1, 'esclarecer'), ('prazo', 2, 'lembrar_prazo'), ('prazo', 3, 'alternativa_real'),
  ('sumiu', 1, 'esclarecer'), ('sumiu', 2, 'pix'), ('sumiu', 3, 'condicao_especial'),
  ('decidiu_depois', 1, 'esperar'), ('decidiu_depois', 2, 'esclarecer'), ('decidiu_depois', 3, 'pix'),
  ('abandonou_checkout', 1, 'ajudar_checkout'), ('abandonou_checkout', 2, 'pix'), ('abandonou_checkout', 3, 'parcelar_2x'),
  ('outro', 1, 'esclarecer'), ('outro', 2, 'alternativa_real')
on conflict do nothing;

create or replace function public.orcamento_registrar_perda(p_orcamento uuid, p_motivo text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_motivo not in ('preco', 'prazo', 'sumiu', 'decidiu_depois', 'abandonou_checkout', 'outro') then return jsonb_build_object('ok', false, 'motivo', 'motivo_invalido'); end if;
  update public.orcamentos set motivo_perda = p_motivo, motivo_perda_em = now() where id = p_orcamento;
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.orcamento_registrar_perda(uuid, text) from public, anon;
grant execute on function public.orcamento_registrar_perda(uuid, text) to authenticated, service_role;

-- Próximo passo de recuperação para o follow-up (respeita optout e o que já foi tentado). Nunca promete nada.
create or replace function public.recuperacao_proximo_passo(p_orcamento uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare o public.orcamentos%rowtype; v_motivo text; v_feitos integer; v_passo text; v_opt boolean;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return jsonb_build_object('ok', false); end if;
  select (marketing_consent = 'opted_out') into v_opt from public.contacts where id = o.contact_id;
  if coalesce(v_opt, false) then return jsonb_build_object('ok', true, 'passo', null, 'motivo', 'optout'); end if;
  v_motivo := coalesce(o.motivo_perda, 'sumiu');
  select count(*) into v_feitos from public.followup_fila where orcamento_id = p_orcamento and status = 'enviado';
  select passo into v_passo from public.estrategia_recuperacao where motivo = v_motivo and ordem = v_feitos + 1;
  return jsonb_build_object('ok', true, 'motivo_perda', v_motivo, 'passo', v_passo, 'tentativas', v_feitos,
    'regra', 'condicao_especial só como último degrau e somente pela função oferecer_condicao_especial');
end;
$$;
revoke execute on function public.recuperacao_proximo_passo(uuid) from public, anon;
grant execute on function public.recuperacao_proximo_passo(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- B10. BauerLab
create table if not exists public.oportunidades_bauerlab (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid not null references public.contacts (id) on delete cascade,
  conversation_id uuid references public.conversations (id) on delete set null,
  necessidade text,
  criado_em timestamptz not null default now(),
  unique (contact_id)
);
alter table public.oportunidades_bauerlab enable row level security;
drop policy if exists oportunidades_bauerlab_dono on public.oportunidades_bauerlab;
create policy oportunidades_bauerlab_dono on public.oportunidades_bauerlab for select to authenticated using (private.is_staff());
insert into public.app_settings (key, value) values ('bauerlab', jsonb_build_object('nome_contato', 'João Victor', 'telefone', '+5531998021169', 'telefone_confirmado_pelo_dono', false,
  'apresentacao', 'A BauerLab é uma agência de sites, landing pages, lojas virtuais, identidade visual, design, redes sociais, tráfego pago e Google Meu Negócio.'))
on conflict (key) do nothing;

-- Uma vez por contato, sem insistir. Alerta de baixa gravidade; não interrompe a venda.
create or replace function public.agente_bauerlab(p_conversation uuid, p_necessidade text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_ct uuid; v_cfg jsonb; v_novo boolean;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select contact_id into v_ct from public.conversations where id = p_conversation;
  if v_ct is null then return jsonb_build_object('ok', false, 'motivo', 'conversa_inexistente'); end if;
  select value into v_cfg from public.app_settings where key = 'bauerlab';
  insert into public.oportunidades_bauerlab (contact_id, conversation_id, necessidade) values (v_ct, p_conversation, left(trim(coalesce(p_necessidade, '')), 200))
  on conflict (contact_id) do nothing returning true into v_novo;
  if not coalesce(v_novo, false) then
    return jsonb_build_object('ok', true, 'ja_apresentado', true, 'orientacao', 'A BauerLab já foi apresentada a este cliente. Não insista; siga com a venda.');
  end if;
  perform public.alerta_criar('oportunidade_bauerlab', 'baixa', v_ct, p_conversation, null, 'Oportunidade BauerLab: ' || left(coalesce(p_necessidade, 'cliente precisa de serviço digital'), 120));
  return jsonb_build_object('ok', true, 'ja_apresentado', false, 'apresentacao', v_cfg ->> 'apresentacao', 'contato', v_cfg ->> 'nome_contato', 'telefone', v_cfg ->> 'telefone',
    'orientacao', 'Apresente em uma ou duas frases, passe o contato de ' || (v_cfg ->> 'nome_contato') || ' e volte para o pedido em andamento. Uma vez só.');
end;
$$;
revoke execute on function public.agente_bauerlab(uuid, text) from public, anon, authenticated;
grant execute on function public.agente_bauerlab(uuid, text) to service_role;

-- ---------------------------------------------------------------- B11. validador de pedidos (antes de seguir para a arte)
create or replace function public.pedido_pendencias(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare o public.orders%rowtype; c public.contacts%rowtype; v_p text[] := '{}'; v_tot numeric; v_orc record;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orders where id = p_order;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'pedido_inexistente'); end if;
  select * into c from public.contacts where id = o.contact_id;
  if coalesce(c.name, '') = '' then v_p := array_append(v_p, 'Nome do cliente'); end if;
  if not exists (select 1 from public.order_items i where i.order_id = o.id) then v_p := array_append(v_p, 'Itens do pedido'); end if;
  if exists (select 1 from public.order_items i where i.order_id = o.id and (coalesce(i.code, '') = '' and not coalesce(i.fora_catalogo, false))) then v_p := array_append(v_p, 'SKU do produto'); end if;
  if exists (select 1 from public.order_items i where i.order_id = o.id and (i.qty < 1 or i.unit_price <= 0)) then v_p := array_append(v_p, 'Quantidade e preço dos itens'); end if;
  select total into v_tot from public.order_financials where order_id = o.id;
  select oc.total, oc.status into v_orc from public.orcamentos oc where oc.order_id = o.id and oc.status in ('enviado', 'aceito', 'pago') order by oc.criado_em desc limit 1;
  if v_orc.total is not null and abs(v_orc.total - coalesce(v_tot, 0)) > 0.05 then v_p := array_append(v_p, 'Preço aprovado (o valor do pedido difere do orçamento enviado)'); end if;
  if o.payment_status <> 'aprovado' and not o.payment_manual then v_p := array_append(v_p, 'Pagamento confirmado'); end if;
  if o.due_date is null and o.lead_days is null then v_p := array_append(v_p, 'Prazo informado'); end if;
  if o.art_mode is null then v_p := array_append(v_p, 'Como será a arte (cliente envia ou criamos)'); end if;
  return jsonb_build_object('ok', true, 'completo', array_length(v_p, 1) is null, 'pendencias', to_jsonb(v_p));
end;
$$;
revoke execute on function public.pedido_pendencias(uuid) from public, anon;
grant execute on function public.pedido_pendencias(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- B5. três opções de orçamento (econômica, intermediária, premium)
create table if not exists public.orcamento_opcoes (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null,
  contact_id uuid not null references public.contacts (id) on delete cascade,
  rotulo text not null check (rotulo in ('economica', 'intermediaria', 'premium')),
  sku text not null,
  quantidade integer not null,
  preco_total numeric(12, 2) not null,
  lucro_pior_caso numeric(12, 2) not null,
  diferenca text,
  recomendada boolean not null default false,
  escolhida_em timestamptz,
  criado_em timestamptz not null default now()
);
create index if not exists orcamento_opcoes_grupo_idx on public.orcamento_opcoes (grupo_id);
alter table public.orcamento_opcoes enable row level security;
drop policy if exists orcamento_opcoes_dono on public.orcamento_opcoes;
create policy orcamento_opcoes_dono on public.orcamento_opcoes for select to authenticated using (private.is_staff());

-- Até 3 alternativas REAIS do mesmo grupo de produto (quantidade ou gramatura diferentes), cada uma com preço de calcular_preco
-- (que nunca fica abaixo do piso) e lucro mínimo respeitado no pior caso. Menos de 3 válidas: devolve só as válidas.
create or replace function public.montar_opcoes(p_contact uuid, p_sku text, p_quantidade integer default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  base record; r record; v_pr jsonb; v_min numeric; v_grupo uuid := gen_random_uuid(); v_ops jsonb := '[]'::jsonb; v_lista jsonb := '[]'::jsonb;
  v_idx integer; v_n integer; v_rot text; v_dif text; v_prazo jsonb; v_pos integer; v_base_preco numeric;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into base from public.catalogo where sku = p_sku and active and vendavel;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'sku_invalido'); end if;
  select lucro_liquido_minimo into v_min from public.parametros_comerciais where id = 1;
  -- candidatas válidas do mesmo grupo e mesmo papel/tamanho de origem (mesmas cores e tamanho), ordenadas por preço
  for r in
    select c.sku, c.descricao, c.quantidade, c.gramatura_g, c.tamanho_mm, c.cores
      from public.catalogo c
     where c.active and c.vendavel and c.grupo_produto = base.grupo_produto and c.tamanho_mm is not distinct from base.tamanho_mm and c.cores is not distinct from base.cores
  loop
    v_pr := public.calcular_preco(r.sku, 1, '{}'::jsonb);
    continue when not coalesce((v_pr ->> 'ok')::boolean, false);
    continue when (v_pr ->> 'lucro_liquido')::numeric < v_min - 0.05 or (v_pr ->> 'preco_total')::numeric < (v_pr ->> 'piso')::numeric;   -- precisa passar na margem
    v_lista := v_lista || jsonb_build_array(jsonb_build_object('sku', r.sku, 'quantidade', r.quantidade, 'gram', r.gramatura_g, 'preco', (v_pr ->> 'preco_total')::numeric,
      'lucro', (v_pr ->> 'lucro_liquido')::numeric, 'descricao', r.descricao));
  end loop;
  -- ordena por preço e escolhe: a pedida (intermediária) com o vizinho mais barato (econômica) e o mais caro (premium)
  select jsonb_agg(e order by (e ->> 'preco')::numeric) into v_lista from jsonb_array_elements(v_lista) e;
  v_n := coalesce(jsonb_array_length(v_lista), 0);
  select ord - 1 into v_pos from jsonb_array_elements(coalesce(v_lista, '[]'::jsonb)) with ordinality t(e, ord) where e ->> 'sku' = p_sku;
  if v_pos is null then return jsonb_build_object('ok', false, 'motivo', 'item_pedido_nao_passou_na_margem'); end if;
  v_base_preco := (v_lista -> v_pos ->> 'preco')::numeric;
  for v_idx in greatest(v_pos - 1, 0) .. least(v_pos + 1, v_n - 1) loop
    v_rot := case when v_idx < v_pos then 'economica' when v_idx > v_pos then 'premium' else 'intermediaria' end;
    r := null;
    select (v_lista -> v_idx ->> 'sku') as sku, (v_lista -> v_idx ->> 'quantidade')::int as quantidade, (v_lista -> v_idx ->> 'gram')::int as gram,
           (v_lista -> v_idx ->> 'preco')::numeric as preco, (v_lista -> v_idx ->> 'lucro')::numeric as lucro into r;
    v_dif := case when v_rot = 'intermediaria' then 'a que você pediu'
                  when r.quantidade is distinct from base.quantidade and r.gram is distinct from base.gramatura_g then format('%s un. e papel de %s g', r.quantidade, r.gram)
                  when r.quantidade is distinct from base.quantidade then format('%s un. em vez de %s', r.quantidade, base.quantidade)
                  when r.gram is distinct from base.gramatura_g then format('papel de %s g em vez de %s g', r.gram, base.gramatura_g)
                  else 'outra configuração' end;
    if v_rot <> 'intermediaria' and r.quantidade is not distinct from base.quantidade and r.gram is not distinct from base.gramatura_g then continue; end if;   -- sem diferença real, não entra
    v_prazo := public.calcular_prazo(r.sku, now(), false);
    insert into public.orcamento_opcoes (grupo_id, contact_id, rotulo, sku, quantidade, preco_total, lucro_pior_caso, diferenca, recomendada)
    values (v_grupo, p_contact, v_rot, r.sku, r.quantidade, r.preco, r.lucro, v_dif, v_rot = 'intermediaria');
    v_ops := v_ops || jsonb_build_array(jsonb_build_object('rotulo', v_rot, 'recomendada', v_rot = 'intermediaria', 'quantidade', r.quantidade, 'preco_total', r.preco,
      'diferenca', v_dif, 'pronto', v_prazo ->> 'data_pronto_texto', 'sku', r.sku));
  end loop;
  return jsonb_build_object('ok', true, 'grupo_id', v_grupo, 'opcoes', v_ops,
    'orientacao', 'Apresente de forma curta, a recomendada primeiro e em destaque, sem inventar diferenças além das listadas. Se só houver uma opção, apresente só ela.');
end;
$$;
revoke execute on function public.montar_opcoes(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.montar_opcoes(uuid, text, integer) to service_role;

create or replace function public.orcamento_opcao_escolher(p_grupo uuid, p_rotulo text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.orcamento_opcoes set escolhida_em = now() where grupo_id = p_grupo and rotulo = p_rotulo and escolhida_em is null;
  return jsonb_build_object('ok', found);
end;
$$;
revoke execute on function public.orcamento_opcao_escolher(uuid, text) from public, anon, authenticated;
grant execute on function public.orcamento_opcao_escolher(uuid, text) to service_role;

create or replace view public.opcoes_conversao with (security_invoker = true) as
select rotulo, count(*) as apresentadas, count(escolhida_em) as escolhidas,
       round(count(escolhida_em)::numeric / nullif(count(*), 0) * 100, 1) as pct_escolha
  from public.orcamento_opcoes group by rotulo;
revoke all on public.opcoes_conversao from anon;
