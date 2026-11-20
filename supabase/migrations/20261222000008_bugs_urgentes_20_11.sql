-- Correção de 4 bugs reais em produção (20/11/2026), achados pelo dono em atendimentos reais.

-- ---------------------------------------------------------------- 1. fu_assunto: "pin" dentro de "stamping" virava "bottons"
-- Causa raiz: os padrões de fu_assunto não tinham borda de palavra, então "hot stamping" (pedido do cliente, repetido
-- pela própria Laura ao recusar) batia no padrão de "bottons/pins" (substring "pin" dentro de "stamping"). A função
-- também olhava mensagens de SAÍDA (da própria Laura), não só de entrada do cliente; a mensagem mais recente que bateu
-- era da Laura, não do cliente, e isso venceu o assunto real (cartões de visita) no follow-up.
-- Fix: toda borda de palavra (\y) nos padrões e só mensagens do cliente (direction = 'in').
create or replace function private.fu_assunto(p_conv uuid)
returns text
language sql
stable
security definer
set search_path to ''
as $function$
  select l.rotulo
    from (select m.created_at, m.body from public.messages m where m.conversation_id = p_conv and m.direction = 'in' and m.body is not null and m.deleted_at is null order by m.created_at desc limit 10) x
    cross join lateral (select v.rotulo from (values
      (1, '\y(crach[aá]s?)\y', 'crachás'), (2, '\y(tirantes?|lanyards?)\y', 'tirantes'), (3, '\y(cord[aã]o|cord[oõ]es)\y', 'cordões'),
      (4, '\y(r[oó]tulos?)\y', 'rótulos'), (5, '\y(adesivos?|etiquetas?)\y', 'adesivos'), (6, '\ycart[aã]o de visita\y|\ycart[oõ]es de visita\y', 'cartões de visita'),
      (7, '\y(panfletos?|flyers?|folhetos?)\y', 'panfletos'), (8, '\y(banners?|faixas?|lonas?)\y', 'banners'), (9, '\y(canecas?)\y', 'canecas'),
      (10, '\y(chaveiros?)\y', 'chaveiros'), (11, '\y(sacolas?)\y', 'sacolas'), (12, '\y(canetas?)\y', 'canetas'), (13, '\y(squeezes?|garrafas?)\y', 'squeezes'),
      (14, '\y(bottons?|pins?)\y', 'bottons'), (15, '\y(agendas?|cadernos?)\y', 'agendas'), (16, '\y(calend[aá]rios?)\y', 'calendários'),
      (17, '\y(camisetas?|camisas?)\y', 'camisetas'), (18, '\y(convites?)\y', 'convites'), (19, '\ycart[aã]o fidelidade\y|\ycart[oõ]es fidelidade\y', 'cartões fidelidade'),
      (20, '\y(brindes?)\y', 'brindes')) v(ord, pat, rotulo) where x.body ~* v.pat order by v.ord limit 1) l
   order by x.created_at desc limit 1
$function$;

-- ---------------------------------------------------------------- 2. "Oi, cliente!" (contato sem nome real válido)
-- A regra de identidade já proíbe isso no prompt, mas o modelo não seguiu em um atendimento real (abertura de
-- anúncio). Trava determinística: se o texto chamar o contato de "cliente" como vocativo e o contato não tiver
-- nome válido (private.fu_nome devolve null para "." e símbolos), bloqueia e sanitiza a frase.
create or replace function private.saida_travas_extra(p_exec uuid, p_texto text)
returns text[]
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare v text[] := '{}'; v_pago boolean := false; v_ct uuid; v_sem_nome boolean;
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
  if p_texto ~* '(\y(oi|ol[aá]|opa)[,!]?\s+cliente\y|,\s*cliente\s*[!.])' then
    select ex.contact_id into v_ct from public.agente_execucoes ex where ex.id = p_exec;
    select private.fu_nome(c.name) is null into v_sem_nome from public.contacts c where c.id = v_ct;
    if coalesce(v_sem_nome, true) then
      v := array_append(v, 'saudacao:cliente_sem_nome');
    end if;
  end if;
  return v;
end $function$;

-- ---------------------------------------------------------------- 3. remover "qualquer banco" (decisão do dono) em todo o banco
create or replace function private.fu_texto_anuncio(p_conv uuid, p_nome text)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
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
  return format('%s! Vi que você veio pelo nosso anúncio de %s. Separei algumas opções de %s unidades (%s mm), da mais em conta à mais completa:%s' || E'\n\n' || 'O Pix cai na hora e o cartão vai em até 2x sem juros. Qual dessas faz mais sentido pra você?',
                v_sauda, lower(v_head), v_q, coalesce(v_t, 'padrão'), v_linhas);
end $function$;

create or replace function private.fu_texto_tiragens_menores(p_conv uuid, p_nome text)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
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
                'O Pix cai na hora e o cartão vai em até 2x sem juros. Qual dessas cabe melhor pra você?',
                coalesce(p_nome, 'Então'), b.quantidade, v_prod, v_linhas);
end $function$;

create or replace function private.followup_montar_base(p_fila uuid, p_agora timestamp with time zone default now())
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
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
    v_texto := case f.regra_codigo when 'PAG_CHK' then format('%s! Vi que você abriu o link do pedido %s e ainda não finalizou. Ficou alguma dúvida? O Pix cai na hora e o cartão vai em até 2x sem juros: %s Posso te ajudar com alguma coisa?', v_sauda, v_num, v_link) when 'PAG_20M' then format('%s! O link do orçamento %s está logo acima: %s. O Pix cai na hora e dá pra pagar no cartão em até 2x sem juros. Se quiser ajustar alguma coisa antes de fechar, me fala.', v_sauda, v_num, v_link) when 'PAG_1H' then format('%s! Seu orçamento %s está aguardando o pagamento. O link é %s. Se precisar de ajuda, é só responder por aqui.', v_sauda, v_num, v_link)
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

create or replace function private.cobertura_processar(p_contact uuid, p_itens jsonb, p_opcoes jsonb, p_criar boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  cfg jsonb := coalesce((select value from public.app_settings where key = 'cobertura'), '{}'::jsonb);
  pr public.parametros_comerciais%rowtype;
  v_abaixo numeric := coalesce((cfg ->> 'abaixo_do_concorrente')::numeric, 4.10);
  v_taxa numeric := coalesce((private.taxa_pagamento('pix') ->> 'pct')::numeric, 0);
  it jsonb; c public.catalogo%rowtype; cand record; v_opc jsonb;
  v_sku text; v_qtd integer; v_val numeric; v_floor numeric; v_unit numeric; v_total numeric;
  v_m jsonb; v_id uuid; v_vm jsonb; v_fin jsonb; v_motivo text; v_f jsonb; v_faixas jsonb := '[]'::jsonb;
  v_cobertas integer := 0; v_ids uuid[] := '{}'; v_achou boolean; v_total_orc numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  v_opc := jsonb_strip_nulls(jsonb_build_object('conversation_id', p_opcoes -> 'conversation_id', 'bairro', p_opcoes -> 'bairro', 'cep', p_opcoes -> 'cep',
            'arte', coalesce(p_opcoes -> 'arte', '"nenhuma"'::jsonb), 'metodo', 'pix', 'teste', p_opcoes -> 'teste', 'nao_otimizar_lote', 'true'));

  for it in select * from jsonb_array_elements(p_itens) limit 6 loop
    v_sku := upper(btrim(coalesce(it ->> 'sku', '')));
    v_qtd := greatest(1, coalesce(nullif(it ->> 'quantidade', '')::integer, 1));
    v_val := nullif(it ->> 'valor_concorrente', '')::numeric;
    v_achou := false; v_motivo := null;
    select * into c from public.catalogo where sku = v_sku and active and vendavel and preco_venda is not null;
    if v_val is null or v_val <= 0 then
      v_motivo := 'valor_concorrente_invalido';
    elsif not found then
      v_motivo := 'sku_invalido';
    else
      for cand in
        select x.sku, x.custo, x.descricao, (x.sku = c.sku) as exato
          from public.catalogo x
         where x.active and x.vendavel and x.preco_venda is not null
           and (x.sku = c.sku or (x.categoria = c.categoria and x.quantidade is not distinct from c.quantidade
                and x.gramatura_g is not distinct from c.gramatura_g and x.cores is not distinct from c.cores
                and x.tamanho_mm is not distinct from c.tamanho_mm and x.custo < c.custo))
         order by (x.sku = c.sku) desc, x.custo desc
      loop
        v_floor := greatest(ceil((cand.custo * v_qtd + pr.lucro_bruto_minimo) * 100) / 100,
                            ceil(cand.custo * v_qtd / (1 - pr.imposto_pct / 100 - v_taxa / 100) * 100) / 100);
        v_unit := ceil(greatest(v_val - v_abaixo, v_floor) / v_qtd * 100) / 100;
        v_total := v_unit * v_qtd;
        if v_total >= v_val then v_motivo := 'abaixo_do_piso'; continue; end if;

        v_id := null; v_m := null; v_total_orc := v_total;
        if p_criar then
          v_m := public.montar_orcamento(p_contact, jsonb_build_array(jsonb_build_object('sku', cand.sku, 'quantidade', v_qtd)), v_opc);
          if coalesce(v_m ->> 'status', '') <> 'ok' then v_motivo := coalesce(v_m ->> 'motivo', 'orcamento_bloqueado'); continue; end if;
          v_id := (v_m ->> 'orcamento_id')::uuid;
          begin
            update public.orcamento_itens set preco_unitario = v_unit, regra_preco = 'cobertura_concorrente', confianca_preco = 'alta' where orcamento_id = v_id;
            update public.orcamentos set aprovado_dono_em = now(), regra_preco = 'cobertura_concorrente',
                   aprovado_dono_motivo = 'Cobertura automática de orçamento concorrente (regra do dono, 19/11/2026)' where id = v_id;
            v_vm := public.validar_margem(v_id);
            if v_vm ->> 'status' <> 'ok' then raise exception 'margem'; end if;
            v_fin := private.orcamento_financeiro(v_id);
            update public.orcamentos set custo_total = (v_fin ->> 'custo')::numeric + (v_fin ->> 'extra')::numeric,
                   lucro_liquido = (v_fin ->> 'lucro')::numeric,
                   margem_liquida_pct = round((v_fin ->> 'lucro')::numeric / nullif((v_fin ->> 'receita')::numeric, 0) * 100, 1)
             where id = v_id;
            select total into v_total_orc from public.orcamentos where id = v_id;
          exception when others then
            delete from public.orcamentos where id = v_id;
            v_id := null; v_motivo := 'abaixo_do_piso';
            continue;
          end;
          v_ids := v_ids || v_id;
        end if;

        v_f := jsonb_build_object('cobrivel', true, 'quantidade_pacotes', v_qtd, 'descricao', cand.descricao,
                 'valor_concorrente', v_val, 'total', v_total_orc, 'valor_economia', round(v_val - v_total_orc, 2),
                 'eh_alternativa_sem_acabamento', not cand.exato,
                 'diferenca', case when cand.exato then null else 'Versão ' || cand.descricao || ' no lugar de ' || c.descricao end,
                 'orcamento_id', v_id, 'numero', v_m ->> 'numero', 'data_prevista_br', v_m ->> 'data_prevista_br');
        v_faixas := v_faixas || jsonb_build_array(jsonb_strip_nulls(v_f));
        v_cobertas := v_cobertas + 1; v_achou := true;
        exit;
      end loop;
    end if;
    if not v_achou then
      v_faixas := v_faixas || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('cobrivel', false, 'motivo', coalesce(v_motivo, 'abaixo_do_piso'),
                   'valor_concorrente', v_val, 'descricao', c.descricao)));
    end if;
  end loop;

  return jsonb_build_object('status', 'ok', 'cobertas', v_cobertas, 'faixas', v_faixas, 'orcamentos', to_jsonb(v_ids),
    'vantagens', jsonb_build_array('Retirada grátis no centro de BH, sem frete', 'Entrega grátis nos bairros centrais', 'Pix e cartão em até 2x sem juros'),
    'orientacao', case
      when v_cobertas = 0 then 'Nenhuma faixa pôde ser coberta. Diga com educação que nessa especificação o valor do concorrente está abaixo do que conseguimos praticar, mostre o orçamento normal e destaque as vantagens (retirada grátis, Pix, prazo). Nunca cite custo, piso nem margem. Não chame o dono.'
      else 'Apresente só as faixas com cobrivel=true, com o valor de total e o valor_economia. Se eh_alternativa_sem_acabamento=true, diga com transparência a diferença (campo diferenca) de forma vendedora e pergunte se serve. Destaque as vantagens. Com UMA faixa coberta e o cliente pronto para fechar, chame gerar_pdf_orcamento e depois gerar_link_pagamento com o orcamento_id da faixa na mesma rodada. Com várias, diga quais cobrimos e pergunte qual ele quer. Nunca chame chamar_dono.' end);
end $function$;

-- ---------------------------------------------------------------- 4. Q1_ANUNCIO desligada (a abertura nova já dá opções e preço na hora)
update public.followup_regras set ativo = false where codigo = 'Q1_ANUNCIO';

-- ---------------------------------------------------------------- 5. "qualquer banco" também na base de conhecimento (buscar_conhecimento)
update public.conhecimento set fatos = 'Confirmar item, valor e data. Enviar o link só depois do pode fechar.'
  where id = 'eed60cc3-2ea3-4b03-9a82-b4cd20ca42e2';
update public.conhecimento set fatos = 'Sempre apresente o Pix primeiro. Não divulgue o parcelamento por conta própria. Desconto específico para Pix não existe ainda. Boleto não é aceito.'
  where id = '22bda068-f823-43da-8c7b-2ec5bb02fb38';
update public.conhecimento set fatos = 'Link novo e único por orçamento. Não peça dados de cartão no chat.'
  where id = 'b05afc3e-9ed6-41cd-8207-1058813aff46';
update public.conhecimento set proximo_passo = regexp_replace(proximo_passo, '\s*e avisar que o Pix (aceita|vale) qualquer banco\.?', '.', 'gi')
  where proximo_passo ilike '%qualquer banco%';
