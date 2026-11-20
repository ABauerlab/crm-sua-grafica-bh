-- Fase 1 (Plano de Ação), item 1.3: automação leve de recuperação de carrinho abandonado do site
-- (hoje não existe nenhum job que leia carrinhos_abandonados). Reaproveita a fila de follow-up e o
-- WF6 que já existem: um cron varre carrinhos parados, enfileira em followup_fila quando o contato
-- já tem conversa com a janela de 24h aberta (único jeito de mandar mensagem livre sem template
-- aprovado pela Meta) e alerta o dono (gravidade baixa) nos outros casos, em vez de ficar em silêncio
-- para sempre. Aditiva e idempotente.

-- 1) CHECK de followup_regras.referencia precisa aceitar o novo valor.
alter table public.followup_regras drop constraint if exists followup_regras_referencia_check;
alter table public.followup_regras add constraint followup_regras_referencia_check
  check (referencia = any (array['orcamento_enviado', 'link_pagamento', 'pedido_entregue', 'pedido_pago', 'conversa_parada', 'checkout_aberto', 'anuncio_parado', 'recusa_preco', 'carrinho_abandonado']));

-- 2) Regra nova.
insert into public.followup_regras (codigo, descricao, referencia, atraso_minutos, hora_min, hora_max, ativo, revisar)
values ('CARRINHO_ABANDONADO', 'Carrinho do site parado há 30 min com WhatsApp conhecido: mensagem livre só se a janela de 24h já estiver aberta', 'carrinho_abandonado', 0, 8, 20, true, true)
on conflict (codigo) do update set descricao = excluded.descricao, referencia = excluded.referencia, hora_min = excluded.hora_min, hora_max = excluded.hora_max;

-- 3) Varredura: enfileira quando dá, alerta o dono (gravidade baixa) quando não dá.
create or replace function private.carrinho_abandonado_varrer(p_agora timestamp with time zone default now())
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $$
declare
  c record; v_wa text; v_contact uuid; v_conv_id uuid; v_janela_aberta boolean; v_ja_comprou boolean;
  v_processados integer := 0; v_enfileirados integer := 0; v_alertas integer := 0; v_fila integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  for c in
    select * from public.carrinhos_abandonados
     where status = 'aberto' and avisado_em is null and whatsapp is not null
       and criado_em <= p_agora - interval '30 minutes'
  loop
    v_processados := v_processados + 1;
    v_wa := regexp_replace(c.whatsapp, '\D', '', 'g');
    v_contact := null; v_conv_id := null; v_janela_aberta := false;
    select ct.id into v_contact from public.contacts ct where ct.wa_id = v_wa limit 1;
    if v_contact is not null then
      select cv.id, cv.last_inbound_at is not null and cv.last_inbound_at > p_agora - interval '24 hours'
        into v_conv_id, v_janela_aberta
        from public.conversations cv where cv.contact_id = v_contact limit 1;
      v_ja_comprou := exists (select 1 from public.orders o where o.contact_id = v_contact and o.excluido_em is null
                                and o.payment_status = 'aprovado' and o.created_at >= c.criado_em);
    else
      v_ja_comprou := false;
    end if;

    if v_contact is not null and v_conv_id is not null and v_janela_aberta and not v_ja_comprou then
      insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, teste)
      values (v_contact, v_conv_id, 'CARRINHO_ABANDONADO', 'CARRINHO_ABANDONADO:' || c.id::text, p_agora, false)
      on conflict (chave) do nothing;
      get diagnostics v_fila = row_count; v_enfileirados := v_enfileirados + v_fila;
    elsif not v_ja_comprou then
      perform public.alerta_criar('carrinho_abandonado_sem_janela', 'baixa', v_contact, v_conv_id, null,
        'Carrinho de ' || private.brl(c.total) || ' (' || coalesce(c.nome, 'sem nome') || ', ' || c.whatsapp || ') ficou parado no site e não dá para mandar mensagem automática agora (sem conversa aberta ou janela de 24h fechada). Avalie contato manual.',
        jsonb_build_object('carrinho_id', c.id, 'total', c.total), 'carrinho_sem_janela:' || c.id::text, array['whatsapp']);
      v_alertas := v_alertas + 1;
    end if;
    update public.carrinhos_abandonados set avisado_em = p_agora where id = c.id;
  end loop;
  return jsonb_build_object('ok', true, 'processados', v_processados, 'enfileirados', v_enfileirados, 'alertas', v_alertas);
end;
$$;
revoke execute on function private.carrinho_abandonado_varrer(timestamp with time zone) from public, anon, authenticated;

-- 4) Texto do lembrete em followup_montar_base (branch nova, antes do "else" final).
create or replace function private.followup_montar_base(p_fila uuid, p_agora timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  f public.followup_fila%rowtype; r public.followup_regras%rowtype; o public.orcamentos%rowtype; ord public.orders%rowtype; ct public.contacts%rowtype; cv public.conversations%rowtype;
  c public.condicoes_especiais%rowtype; n text; v_num text; v_val text; v_pronto text; v_prod text; v_link text; v_var integer; v_janela boolean; v_texto text; v_tpl text; v_params jsonb;
  v_up text; v_cond_vigente boolean := false; v_ped text; v_sauda text; v_carr public.carrinhos_abandonados%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into f from public.followup_fila where id = p_fila;
  if not found then return jsonb_build_object('ok', false, 'acao', 'pular', 'motivo', 'fila_inexistente'); end if;
  select * into r from public.followup_regras where codigo = f.regra_codigo;
  select * into ct from public.contacts where id = f.contact_id;
  select * into cv from public.conversations where id = coalesce(f.conversation_id, (select id from public.conversations where contact_id = f.contact_id limit 1));
  if cv.id is null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'sem_conversa'); end if;
  select * into o from public.orcamentos where id = f.orcamento_id;
  select * into ord from public.orders where id = f.order_id;
  n := private.fu_nome(ct.name);
  v_sauda := coalesce('Oi, ' || n, 'Oi');
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

  if f.regra_codigo = 'F1' and o.link_pagamento is not null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'coberto_pelo_link'); end if;
  if f.regra_codigo = 'F1' then
    v_texto := case v_var
      when 0 then format('%s! Passando pra saber se ficou alguma dúvida sobre o orçamento %s. A gente cuida da arte e entrega com data certa. Se quiser ajustar quantidade, acabamento ou prazo, é só me falar que eu resolvo rapidinho.', v_sauda, v_num)
      else format('%s! Conseguiu dar uma olhada no orçamento %s? Qualquer dúvida sobre o material ou a arte, me chama por aqui que eu te ajudo.%s', v_sauda, v_num,
                  case when o.data_prevista is not null then ' Fechando, o pedido fica pronto dia ' || v_pronto || '.' else '' end) end;
  elsif f.regra_codigo = 'F2' then
    v_texto := format('%s! O orçamento %s vale até %s%s. Quer que eu reenvie o link de pagamento?', v_sauda, v_num, v_val,
                      case when o.data_prevista is not null then ', e fechando hoje ele fica pronto dia ' || v_pronto else '' end);
    v_tpl := 'orcamento_vence_hoje'; v_params := jsonb_build_array(n, v_num, v_val);
  elsif f.regra_codigo in ('F3', 'F4') and v_cond_vigente then
    v_link := coalesce(c.link_pagamento, (select oc.link_pagamento from public.orcamentos oc where oc.id = c.orcamento_novo_id));
    v_texto := format('%s! %s no seu orçamento %s: %s. Vale até %s.%s', v_sauda,
                      case when f.regra_codigo = 'F4' then 'Última chamada, consegui uma condição especial' else 'Consegui uma condição especial' end, v_num, c.texto_curto,
                      to_char(c.valida_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"'),
                      case when v_link is not null then ' Segue o link atualizado: ' || v_link else ' Quer que eu envie o link de pagamento atualizado?' end);
    v_tpl := 'condicao_especial_orcamento'; v_params := jsonb_build_array(n, v_num, c.texto_curto, to_char(c.valida_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"'));
  elsif f.regra_codigo = 'F3' then
    v_texto := format('%s! Seu orçamento %s vale até %s. Dá pra fechar e garantir a entrega no prazo. Quer que eu reenvie o link de pagamento?', v_sauda, v_num, v_val);
    v_tpl := 'orcamento_vence_hoje'; v_params := jsonb_build_array(n, v_num, v_val);
  elsif f.regra_codigo = 'F4' then
    v_texto := format('%s, passando pra saber se ainda faz sentido seguir com o seu pedido de %s. Se quiser ajustar quantidade ou acabamento, me chama por aqui que a gente resolve rápido.', v_sauda, v_prod);
    v_tpl := 'ultima_chance_orcamento'; v_params := jsonb_build_array(n, v_prod);
  elsif f.regra_codigo in ('Q1', 'Q2') and private.fu_texto_q(f.regra_codigo, cv.id, n, v_var) is not null then /* q_sem_eco */
    v_texto := private.fu_texto_q(f.regra_codigo, cv.id, n, v_var);
  elsif f.regra_codigo = 'Q1' and false then /* q_assunto */
    v_texto := case v_var
      when 0 then format('%s! Voltando ao nosso papo: %s Se já tiver o que precisa, me manda que eu monto o seu orçamento agora.', v_sauda, private.fu_ultima_pergunta(cv.id))
      else format('%s! Só pra gente não perder o fio: %s Me responde por aqui que eu já avanço com o seu pedido.', v_sauda, private.fu_ultima_pergunta(cv.id)) end;
  elsif f.regra_codigo = 'Q2' and false then
    v_texto := format('%s! Ainda consigo te ajudar com isso: %s Se me responder, eu já te mando o orçamento ainda hoje.', v_sauda, private.fu_ultima_pergunta(cv.id));
  elsif f.regra_codigo = 'Q1' and (private.ficha_respostas(cv.id) ->> 'quantidade_informada') is not null then /* q_qtd_sabida */
    v_texto := format('%s! Com as %s unidades que você me falou, já consigo montar o seu orçamento agora. Posso seguir?', v_sauda, private.ficha_respostas(cv.id) ->> 'quantidade_informada');
  elsif f.regra_codigo = 'Q1' then /* conversa_parada */
    v_texto := case v_var
      when 0 then format('%s! Passando pra saber se deu pra ver o que te mandei. Me conta só o que falta que eu já fecho o seu orçamento e te mando o PDF ainda hoje, combinado?', v_sauda) /* q1_v2 */
      else format('%s! Ainda tá precisando disso? Se me confirmar a quantidade e se já tem a arte, eu monto o orçamento agora mesmo.', v_sauda) end;
  elsif f.regra_codigo = 'Q2' then
    v_texto := format('%s! Ainda consigo te ajudar com o seu pedido? Se me passar só o que falta, eu já te mando o orçamento ainda hoje.', v_sauda);
  elsif f.regra_codigo like 'PAG_%' then
    select p.link into v_link from public.pagamentos p where p.order_id = f.order_id and p.eh_link and p.link_ativo and p.status = 'pendente' order by p.criado_em desc limit 1;
    v_num := coalesce(v_num, v_ped);
    if v_link is null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'link_inativo'); end if;
    v_texto := case f.regra_codigo when 'PAG_CHK' then format('%s! Vi que você abriu o link do pedido %s e ainda não finalizou. Ficou alguma dúvida? O Pix de qualquer banco cai na hora e o cartão vai em até 2x sem juros: %s Posso te ajudar com alguma coisa?', v_sauda, v_num, v_link) when 'PAG_20M' then format('%s! O link do orçamento %s está logo acima: %s. O Pix de qualquer banco cai na hora e dá pra pagar no cartão em até 2x sem juros. Se quiser ajustar alguma coisa antes de fechar, me fala.', v_sauda, v_num, v_link) when 'PAG_1H' then format('%s! Seu orçamento %s está aguardando o pagamento. O link é %s. Se precisar de ajuda, é só responder por aqui.', v_sauda, v_num, v_link)
      when 'PAG_6H' then format('%s! Só lembrando do fechamento do seu pedido %s: %s. Se surgiu alguma dúvida, me fala que eu resolvo.', v_sauda, v_num, v_link)
      else format('%s! Seu orçamento %s ainda está aguardando o pagamento: %s.%s', v_sauda, v_num, v_link,
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
    v_texto := format('%s! Seu pedido %s foi entregue. Obrigado pela confiança! Deu tudo certo? Se puder, avalie a Sua Gráfica BH no Google, leva 1 minuto: https://g.page/r/CZ6eNNGjdgO4EAE/review %s Vamos te avisar por aqui de novidades e promoções. Se não quiser, é só responder PARAR.', v_sauda, v_ped, v_up);
    v_tpl := 'pos_venda_avaliacao'; v_params := jsonb_build_array(n, v_ped);
  elsif f.regra_codigo like 'RECOMPRA_%' then
    if ord.id is not null and ord.stage not in ('entregue', 'recompra') then
      return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'pedido_nao_concluido');
    end if;
    v_prod := coalesce(f.produto, 'pedido');
    v_texto := format('%s! Já faz um tempinho desde o seu pedido de %s. Quer repor ou incluir algo novo? Me responde por aqui que eu monto o orçamento rapidinho.', v_sauda, v_prod);
    v_tpl := 'recompra_lembrete'; v_params := jsonb_build_array(n, v_prod);
  elsif f.regra_codigo = 'CARRINHO_ABANDONADO' then
    select * into v_carr from public.carrinhos_abandonados where id = nullif(split_part(f.chave, ':', 2), '')::uuid;
    if v_carr.id is null or v_carr.status <> 'aberto' then
      return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'carrinho_nao_esta_mais_aberto');
    end if;
    if exists (select 1 from public.orders x where x.contact_id = f.contact_id and x.excluido_em is null and x.payment_status = 'aprovado' and x.created_at >= v_carr.criado_em) then
      return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'ja_comprou');
    end if;
    v_texto := format('%s! Vi que você montou um carrinho de %s aqui no nosso site e não deu tempo de finalizar. Posso te ajudar a fechar? Se quiser, me fala que eu já confirmo tudo certinho pra você.', v_sauda, private.brl(v_carr.total));
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

-- 5) Cron a cada 15 minutos.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'carrinho-abandonado-varrer') then
      perform cron.unschedule('carrinho-abandonado-varrer');
    end if;
    perform cron.schedule('carrinho-abandonado-varrer', '*/15 * * * *', 'select private.carrinho_abandonado_varrer()');
  end if;
end $$;
