-- Fase 1 (Plano de Ação), item 1.2 e 1.4:
-- 1) Fallback de nome vazio: "cliente" nunca mais aparece nas mensagens de follow-up.
-- 2) Template "pagamento do orçamento" (confuso: o cliente acha que o ORÇAMENTO é cobrado) vira
--    "fechamento do seu pedido" no lembrete PAG_6H (caso real: contato 08d9b350-6a22-44c1-b136-0dff8616a8f1).
-- 3) pagamentos_alertas.resolvido_em passa a ser marcado sozinho quando o pedido é pago por outro
--    caminho (hoje fica aberto para sempre; achado real: alerta do pedido SG-0296).
-- 4) Limpeza de 108 linhas órfãs de erros_operacao (tipo divergencia_pagamento) que apontam para
--    pedidos já inexistentes (confirmado: 100% delas; a função que gera o alerta já só olha pedidos
--    que existem, então não é um bug ativo, só ruído histórico).
-- Aditiva e idempotente (CREATE OR REPLACE / DELETE condicional).

-- 1) fu_nome: nunca mais devolve a string "cliente".
create or replace function private.fu_nome(p_nome text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ select nullif(initcap(regexp_replace(split_part(trim(coalesce(p_nome, '')), ' ', 1), '[^A-Za-zÀ-ÿ-]', '', 'g')), ''); $function$;

-- 2) followup_montar_base: saudação sem nome vira "Oi!" em vez de "Oi, cliente!"; PAG_6H corrigido.
create or replace function private.followup_montar_base(p_fila uuid, p_agora timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  f public.followup_fila%rowtype; r public.followup_regras%rowtype; o public.orcamentos%rowtype; ord public.orders%rowtype; ct public.contacts%rowtype; cv public.conversations%rowtype;
  c public.condicoes_especiais%rowtype; n text; v_num text; v_val text; v_pronto text; v_prod text; v_link text; v_var integer; v_janela boolean; v_texto text; v_tpl text; v_params jsonb;
  v_up text; v_cond_vigente boolean := false; v_ped text; v_sauda text;
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

-- 3) fu_texto_q: mesma saudação sem a palavra "cliente".
create or replace function private.fu_texto_q(p_regra text, p_conv uuid, p_nome text, p_var integer)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ja integer; v_v integer; v_ass text := private.fu_assunto(p_conv); v_sauda text := coalesce('Oi, ' || p_nome, 'Oi');
begin
  select count(*) into v_ja from public.followup_fila x join public.conversations cv on cv.contact_id = x.contact_id
   where cv.id = p_conv and x.regra_codigo ~ '^Q[1-2]$' and x.status in ('enviado', 'reservado');
  v_v := (coalesce(p_var, 0) + coalesce(v_ja, 0)) % 4;
  if p_regra = 'Q1' then
    return case v_v
      when 0 then format('%s! Assim que puder, me responde por aqui pra gente já seguir%s, combinado?', v_sauda, case when v_ass is not null then ' com os ' || v_ass else ' com o seu orçamento' end)
      when 1 then format('%s! Ficou alguma dúvida%s? Me diz o que falta que eu resolvo rapidinho.', v_sauda, case when v_ass is not null then ' sobre os ' || v_ass else '' end)
      when 2 then format('%s, tô por aqui quando você quiser retomar%s. É só me chamar!', coalesce(p_nome, 'Oi'), case when v_ass is not null then ' os ' || v_ass else '' end)
      else format('%s! Se ajudar, eu já adianto o que for preciso pra fechar%s. Posso seguir?', v_sauda, case when v_ass is not null then ' os ' || v_ass else '' end) end;
  elsif p_regra = 'Q2' then
    return format('%s! Última chamada: se ainda fizer sentido pra você, é só me responder por aqui que eu já sigo e te entrego o material o quanto antes. Posso contar com você?', v_sauda);
  end if;
  return null;
end $function$;

-- 4) fu_texto_anuncio: mesma saudação sem a palavra "cliente".
create or replace function private.fu_texto_anuncio(p_conv uuid, p_nome text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_head text; v_h text; v_cat text; v_q integer; v_t text; v_linhas text; v_sauda text := coalesce('Oi, ' || p_nome, 'Oi');
begin
  select coalesce(nullif(cv.last_referral ->> 'headline', ''), nullif(ct.first_referral ->> 'headline', '')) into v_head
    from public.conversations cv join public.contacts ct on ct.id = cv.contact_id where cv.id = p_conv;
  if v_head is null then return null; end if;
  v_h := private.texto_norm(v_head);

  if v_h like '%crach%' then
    return format('%s! Vi que você veio pelo nosso anúncio de %s. Pra eu te mostrar as opções certas: você prefere o crachá na vertical ou na horizontal?', v_sauda, lower(v_head));
  end if;

  v_cat := case
    when v_h ~ 'cart(ao|oes).*visita|visita' then 'CARTÕES DE VISITA'
    when v_h ~ 'panfleto|flyer|folheto' then 'PANFLETOS, FLYERS E FOLHETOS'
    else (select c.categoria from public.catalogo c
           where c.active and c.vendavel and c.preco_venda is not null and v_h like '%' || split_part(private.texto_norm(c.categoria), ' ', 1) || '%' limit 1) end;
  if v_cat is null then
    return format('%s! Vi que você veio pelo nosso anúncio de %s. Me conta qual quantidade você precisa que eu já te passo as opções e os valores certinhos.', v_sauda, lower(v_head));
  end if;

  select mode() within group (order by quantidade) into v_q from public.catalogo where categoria = v_cat and active and vendavel and preco_venda is not null;
  select mode() within group (order by tamanho_mm) into v_t from public.catalogo where categoria = v_cat and quantidade = v_q and active and vendavel and preco_venda is not null;

  with g as (
    select distinct on (x.descricao, x.cores)
           private.desc_publica(x.descricao) || case x.cores
             when '4X0' then ', colorido na frente' when '4X4' then ', colorido frente e verso' when '4X1' then ', colorido na frente e uma cor no verso'
             when '1X0' then ', uma cor na frente' when '1X1' then ', uma cor frente e verso' else '' end as texto,
           (public.calcular_preco(x.sku, 1, '{}'::jsonb) ->> 'preco_total')::numeric as preco
      from public.catalogo x
     where x.categoria = v_cat and x.quantidade = v_q and x.tamanho_mm is not distinct from v_t and x.active and x.vendavel and x.preco_venda is not null
     order by x.descricao, x.cores, x.preco_venda),
  rk as (select g.*, row_number() over (order by g.preco) as rn, count(*) over () as n from g where g.preco is not null)
  select string_agg(E'\n• ' || rk.texto || ': ' || private.brl(rk.preco), '' order by rk.preco) into v_linhas
    from rk where rk.n <= 5 or rk.rn in (1, 1 + (rk.n - 1) / 4, 1 + (rk.n - 1) / 2, 1 + (3 * (rk.n - 1)) / 4, rk.n);
  if v_linhas is null then return null; end if;
  return format('%s! Vi que você veio pelo nosso anúncio de %s. Separei algumas opções de %s unidades (%s mm), da mais em conta à mais completa:%s' || E'\n\n' || 'O Pix de qualquer banco cai na hora e o cartão vai em até 2x sem juros. Qual dessas faz mais sentido pra você?',
                v_sauda, lower(v_head), v_q, coalesce(v_t, 'padrão'), v_linhas);
end $function$;

-- 5) fu_texto_tiragens_menores: sem nome, abre com "Então" em vez de ficar só a vírgula sem nome.
create or replace function private.fu_texto_tiragens_menores(p_conv uuid, p_nome text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare k record; b public.catalogo%rowtype; v_linhas text; v_prod text;
begin
  select * into k from private.fu_ultima_cotacao(p_conv);
  if k.sku is null then return null; end if;
  select * into b from public.catalogo where sku = k.sku;
  with t as (
    select distinct on (x.quantidade) x.sku, x.quantidade,
           (public.calcular_preco(x.sku, 1, '{}'::jsonb) ->> 'preco_total')::numeric as preco,
           coalesce((public.calcular_preco(x.sku, 1, '{}'::jsonb) ->> 'lucro_ok')::boolean, false) as ok
      from public.catalogo x
     where x.categoria = b.categoria and x.descricao is not distinct from b.descricao and x.cores is not distinct from b.cores
       and x.tamanho_mm is not distinct from b.tamanho_mm and x.quantidade < b.quantidade
       and x.active and x.vendavel and x.preco_venda is not null
     order by x.quantidade, x.preco_venda)
  select string_agg(E'\n• ' || t.quantidade || ' unidades: ' || private.brl(t.preco), '' order by t.quantidade)
    into v_linhas from t where t.preco is not null and t.ok;
  if v_linhas is null then return null; end if;
  v_prod := lower(b.categoria);
  return format('%s, tranquilo! Se o valor de %s unidades pesou, dá pra começar com uma tiragem menor do mesmo %s (mesmo papel e tamanho):%s' || E'\n\n' ||
                'O Pix de qualquer banco cai na hora e o cartão vai em até 2x sem juros. Qual dessas cabe melhor pra você?',
                coalesce(p_nome, 'Então'), b.quantidade, v_prod, v_linhas);
end $function$;

-- 6) pagamentos_alertas.resolvido_em marcado sozinho quando o pedido é pago (qualquer caminho:
--    webhook, conferência manual ou confirmação do dono), igual já acontecia com orcamentos/orders.
create or replace function private.confirmar_pagamento(p_order uuid, p_origem text, p_metodo text, p_ext_id text, p_quando timestamp with time zone, p_pagamento uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_o public.orders%rowtype; v_total numeric; v_taxa jsonb; v_lucro numeric;
begin
  select * into v_o from public.orders where id = p_order for update;
  if not found or v_o.payment_status = 'aprovado' then return false; end if;

  v_taxa := private.taxa_pagamento(coalesce(p_metodo, v_o.payment_method));
  update public.orders set
    payment_status = 'aprovado',
    payment_manual = (p_origem = 'manual'),
    payment_method = coalesce(p_metodo, payment_method),
    payment_external_id = coalesce(p_ext_id, payment_external_id),
    payment_confirmed_at = coalesce(payment_confirmed_at, p_quando, now()),
    -- método conhecido: o pedido passa a usar a taxa real; desconhecido mantém a taxa prevista
    payment_fee_pct = case when (v_taxa ->> 'conhecido')::boolean then (v_taxa ->> 'pct')::numeric else payment_fee_pct end,
    -- só avança para Pago quem ainda está antes dessa etapa; quem já passou dela não volta
    stage = case when stage in ('novo', 'cotando', 'aguardando_pagamento') then 'pago' else stage end
  where id = p_order;

  select total, net_profit into v_total, v_lucro from public.order_financials where order_id = p_order;
  update public.orders set taxa_pagamento_real_pct = (select payment_fee_pct from public.orders where id = p_order), lucro_liquido_real = v_lucro where id = p_order;
  -- só orçamentos já enviados: sair de rascunho dispara a trava de lucro, e pagamento confirmado nunca é bloqueado
  update public.orcamentos set status = 'pago' where order_id = p_order and status in ('enviado', 'aceito');
  -- pedido pago por outro caminho: fecha o alerta de pagamento recusado/problema que ainda estava aberto
  update public.pagamentos_alertas set resolvido_em = now() where order_id = p_order and resolvido_em is null;

  perform private.mp_evento(
    'pagamento_confirmado', p_order, p_pagamento, 'pagamento_confirmado:' || p_order::text,
    jsonb_build_object('pedido_id', p_order, 'pedido_numero', v_o.number, 'referencia', 'SG-' || lpad(v_o.number::text, 4, '0'),
      'valor', v_total, 'metodo', coalesce(p_metodo, v_o.payment_method), 'origem', p_origem, 'mp_payment_id', p_ext_id, 'teste', v_o.teste));
  return true;
end;
$function$;

-- 7) Limpeza de ruído histórico: linhas de erros_operacao (divergencia_pagamento) que apontam para
--    pedidos já excluídos de verdade do banco (confirmado: 100% das 108 linhas existentes hoje).
--    A função que gera o alerta (public.pagamentos_divergencias_checar) já só olha pedidos existentes,
--    então isso não volta a acontecer sozinho.
delete from public.erros_operacao e
 where e.tipo = 'divergencia_pagamento'
   and e.pedido_id is not null
   and not exists (select 1 from public.orders o where o.id = e.pedido_id);
