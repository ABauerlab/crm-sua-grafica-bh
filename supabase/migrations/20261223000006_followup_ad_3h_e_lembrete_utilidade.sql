-- Follow-up de lead de anúncio sem pagamento: (1) teste de 14 dias de um toque de 2 h 30 depois do último contato da Laura,
-- no lugar do lembrete de 20 h (F2) e só para contato de anúncio com orçamento ou link sem pagamento; (2) lembrete de orçamento
-- em template UTILITY (orcamento_lembrete_pedido) em vez do MARKETING orcamento_vence_hoje, só depois de aprovado como UTILITY.
-- Aditiva e idempotente. Mantém todas as travas atuais: janela de 24 h (texto livre, sem template pago), horário 8h às 20h,
-- 1 lembrete por dia (max_por_dia), opt-out, modo humano, pedido pago, recusa do cliente e cancelamento quando o cliente responde.
--  * regra F2_AD3H (o prefixo F2 faz a regra entrar na cadência existente de followup_reservar);
--  * o teste liga e desliga sozinho por app_settings.followup_teste_ad (ligado, inicio, fim, atraso_min);
--  * durante o teste, F2 pendente de contato de anúncio é cancelada com motivo 'substituido_pelo_teste_ad_3h';
--  * depois de 'fim' nada novo é agendado e a F2 volta ao normal.

alter table public.followup_regras drop constraint if exists followup_regras_referencia_check;
alter table public.followup_regras add constraint followup_regras_referencia_check
  check (referencia = any (array['orcamento_enviado', 'link_pagamento', 'pedido_entregue', 'pedido_pago', 'conversa_parada', 'checkout_aberto',
                                 'anuncio_parado', 'recusa_preco', 'carrinho_abandonado', 'ad_3h']));

insert into public.followup_regras (codigo, descricao, referencia, atraso_minutos, hora_min, hora_max, ativo, revisar)
values ('F2_AD3H', 'Teste de 14 dias: lead de anúncio com orçamento ou link sem pagamento recebe um toque 2 h 30 depois do último contato da Laura (texto livre na janela de 24 h), no lugar do lembrete de 20 h',
        'ad_3h', 150, 8, 20, true, false)
on conflict (codigo) do nothing;

insert into public.app_settings (key, value)
values ('followup_teste_ad', jsonb_build_object('ligado', true, 'inicio', now(), 'fim', now() + interval '14 days', 'atraso_min', 150))
on conflict (key) do nothing;

-- Configuração do teste enquanto ele está valendo (null fora do período ou desligado)
create or replace function private.fu_teste_ad(p_agora timestamptz default now())
returns jsonb language sql stable security definer set search_path = '' as $$
  select s.value from public.app_settings s
   where s.key = 'followup_teste_ad' and coalesce((s.value ->> 'ligado')::boolean, false)
     and p_agora >= (s.value ->> 'inicio')::timestamptz and p_agora < (s.value ->> 'fim')::timestamptz;
$$;
revoke all on function private.fu_teste_ad(timestamptz) from public, anon, authenticated;

create or replace function private.fu_agendar_ad3h(p_agora timestamptz default now())
returns integer language plpgsql security definer set search_path = '' as $$
declare r public.followup_regras%rowtype; v_cfg jsonb; v_n integer := 0; v_c integer; v_atraso integer;
begin
  v_cfg := private.fu_teste_ad(p_agora);
  if v_cfg is null then return 0; end if;
  select * into r from public.followup_regras where codigo = 'F2_AD3H' and ativo;
  if not found then return 0; end if;
  v_atraso := coalesce((v_cfg ->> 'atraso_min')::integer, r.atraso_minutos);

  -- no lugar do lembrete de 20 h: a F2 pendente de contato de anúncio sai da fila durante o teste
  update public.followup_fila f set status = 'cancelado', motivo = 'substituido_pelo_teste_ad_3h'
   where f.regra_codigo = 'F2' and f.status = 'pendente'
     and exists (select 1 from public.contacts c left join public.conversations v on v.contact_id = c.id
                  where c.id = f.contact_id and (c.first_referral is not null or v.last_referral is not null));

  -- 1) orçamento enviado e ainda válido
  insert into public.followup_fila (contact_id, conversation_id, orcamento_id, order_id, regra_codigo, chave, agendado_para, teste, produto)
  select cv.contact_id, cv.id, o.id, o.order_id, r.codigo, r.codigo || ':' || o.id::text,
         private.fu_proxima_janela(ult.criado + make_interval(mins => v_atraso), r.hora_min, r.hora_max),
         'teste' = any (coalesce(ct.tags, '{}')) or coalesce(ct.is_teste, false),
         (select left(i.descricao, 80) from public.orcamento_itens i where i.orcamento_id = o.id order by i.criado_em limit 1)
    from public.conversations cv join public.contacts ct on ct.id = cv.contact_id
    cross join lateral (select m.created_at as criado, m.direction as dir from public.messages m where m.conversation_id = cv.id order by m.created_at desc limit 1) ult
    cross join lateral (select oo.* from public.orcamentos oo where oo.contact_id = cv.contact_id and oo.status = 'enviado' and oo.pdf_enviado_em is not null
                           and oo.pdf_enviado_em > p_agora - interval '3 days' and (oo.validade_ate is null or oo.validade_ate > p_agora)
                         order by oo.pdf_enviado_em desc limit 1) o
   where (cv.last_referral is not null or ct.first_referral is not null)
     and ult.dir = 'out' and ult.criado > p_agora - interval '10 hours'
     and cv.last_inbound_at is not null and cv.last_inbound_at > p_agora - interval '23 hours' and cv.last_inbound_at < ult.criado
     and coalesce(cv.modo_atendimento, 'ia') = 'ia' and coalesce(cv.ai_handled, true) and not coalesce(ct.optout, false)
     and not exists (select 1 from public.orders x where x.contact_id = cv.contact_id and x.excluido_em is null
                        and (x.payment_status = 'aprovado' or x.stage in ('pago', 'arte', 'prova', 'producao', 'entregue')) and coalesce(x.paid_at, x.created_at) > p_agora - interval '10 days')
     and not exists (select 1 from public.followup_fila y where y.contact_id = cv.contact_id and y.regra_codigo = r.codigo and y.criado_em > p_agora - interval '3 days')
  on conflict (chave) do nothing;
  get diagnostics v_c = row_count; v_n := v_n + v_c;

  -- 2) link de pagamento ativo (pedido sem orçamento enviado, que o item 1 já cobre)
  insert into public.followup_fila (contact_id, conversation_id, order_id, regra_codigo, chave, agendado_para, teste, produto)
  select cv.contact_id, cv.id, ord.id, r.codigo, r.codigo || ':' || ord.id::text,
         private.fu_proxima_janela(ult.criado + make_interval(mins => v_atraso), r.hora_min, r.hora_max),
         'teste' = any (coalesce(ct.tags, '{}')) or coalesce(ct.is_teste, false), left(coalesce(ord.title, 'pedido'), 80)
    from public.orders ord join public.contacts ct on ct.id = ord.contact_id
    join public.conversations cv on cv.contact_id = ct.id
    cross join lateral (select m.created_at as criado, m.direction as dir from public.messages m where m.conversation_id = cv.id order by m.created_at desc limit 1) ult
   where (cv.last_referral is not null or ct.first_referral is not null)
     and ord.excluido_em is null and ord.payment_status <> 'aprovado' and ord.stage in ('novo', 'cotando', 'aguardando_pagamento')
     and exists (select 1 from public.pagamentos p where p.order_id = ord.id and p.eh_link and p.link_ativo and p.status = 'pendente'
                    and p.criado_em > p_agora - interval '3 days' and (p.expira_em is null or p.expira_em > p_agora))
     and not exists (select 1 from public.orcamentos oo where oo.order_id = ord.id and oo.status = 'enviado' and oo.pdf_enviado_em is not null)
     and ult.dir = 'out' and ult.criado > p_agora - interval '10 hours'
     and cv.last_inbound_at is not null and cv.last_inbound_at > p_agora - interval '23 hours' and cv.last_inbound_at < ult.criado
     and coalesce(cv.modo_atendimento, 'ia') = 'ia' and coalesce(cv.ai_handled, true) and not coalesce(ct.optout, false)
     and not exists (select 1 from public.orders x where x.contact_id = cv.contact_id and x.excluido_em is null and x.id <> ord.id
                        and (x.payment_status = 'aprovado' or x.stage in ('pago', 'arte', 'prova', 'producao', 'entregue')) and coalesce(x.paid_at, x.created_at) > p_agora - interval '10 days')
     and not exists (select 1 from public.followup_fila y where y.contact_id = cv.contact_id and y.regra_codigo = r.codigo and y.criado_em > p_agora - interval '3 days')
  on conflict (chave) do nothing;
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  return v_n;
end $$;
revoke all on function private.fu_agendar_ad3h(timestamptz) from public, anon, authenticated;

-- followup_agendar: acrescenta o agendamento do teste, sem mudar o resto
create or replace function public.followup_agendar(p_agora timestamptz default now())
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_ad integer := 0; v_rc integer := 0; v_t integer := 0;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  v := private.followup_agendar_base(p_agora);
  begin v_ad := private.fu_agendar_anuncio(p_agora); exception when others then raise warning 'agendar anúncio: %', sqlerrm; end;
  begin v_rc := private.fu_agendar_recusa(p_agora); exception when others then raise warning 'agendar recusa: %', sqlerrm; end;
  begin v_t := private.fu_agendar_ad3h(p_agora); exception when others then raise warning 'agendar ad3h: %', sqlerrm; end;
  return v || jsonb_build_object('anuncio', v_ad, 'recusa_preco', v_rc, 'ad_3h', v_t);
end $$;

-- Texto do toque (sempre texto livre dentro da janela de 24 h; nunca template pago nem promoção)
create or replace function private.followup_montar_ad3h(p_fila uuid, p_agora timestamptz default now())
returns jsonb language plpgsql security definer set search_path = '' as $$
declare f public.followup_fila%rowtype; cv public.conversations%rowtype; ct public.contacts%rowtype; o public.orcamentos%rowtype; ord public.orders%rowtype;
        n text; v_sauda text; v_prod text; v_qtd numeric; v_valor numeric; v_val text; v_num text; v_texto text;
begin
  select * into f from public.followup_fila where id = p_fila;
  if not found then return jsonb_build_object('ok', false, 'acao', 'pular', 'motivo', 'fila_inexistente'); end if;
  if private.fu_teste_ad(p_agora) is null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'teste_encerrado'); end if;
  select * into cv from public.conversations where id = f.conversation_id;
  select * into ct from public.contacts where id = f.contact_id;
  if cv.id is null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'sem_conversa'); end if;
  if cv.last_inbound_at is not null and cv.last_inbound_at > f.criado_em then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'cliente_respondeu'); end if;
  if cv.last_inbound_at is null or cv.last_inbound_at + interval '24 hours' < p_agora then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'janela_fechada'); end if;
  if exists (select 1 from (select m.body from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.body is not null and m.deleted_at is null order by m.created_at desc limit 2) z
              where z.body ~* '(n[aã]o,? *(n[aã]o|obrigad[oa]|valeu)|sem interesse|n[aã]o (quero|preciso|tenho interesse|faz sentido)|desist|j[aá] (fechei|resolvi|comprei|contratei)|deixa (pra l[aá]|quieto|assim)|por enquanto n[aã]o|j[aá] tenho (gr[aá]fica|fornecedor))') then
    return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'cliente_recusou');
  end if;
  n := private.fu_nome(ct.name);
  v_sauda := coalesce('Oi, ' || n, 'Oi');
  if f.orcamento_id is not null then
    select * into o from public.orcamentos where id = f.orcamento_id;
    if o.id is null or o.status not in ('enviado', 'aceito') then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'orcamento_encerrado'); end if;
    if o.validade_ate is not null and o.validade_ate < p_agora then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'orcamento_vencido'); end if;
    select i.quantidade into v_qtd from public.orcamento_itens i where i.orcamento_id = o.id order by i.criado_em limit 1;
    v_valor := o.total; v_num := private.orcamento_numero(o.numero);
    v_val := case when o.validade_ate is not null then to_char(o.validade_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"') else null end;
    v_prod := coalesce(f.produto, 'seu pedido') || case when v_qtd is not null then ' (' || trim(to_char(v_qtd, 'FM999999990')) || ' un.)' else '' end;
    v_texto := format('%s! Passando pra lembrar do seu orçamento %s: %s, no valor de %s%s. Dá pra pagar no Pix ou no cartão em até 2x sem juros. Posso te mandar o link de pagamento?',
                      v_sauda, v_num, v_prod, private.brl(v_valor), case when v_val is not null then ', válido até ' || v_val else '' end);
  else
    select * into ord from public.orders where id = f.order_id;
    if ord.id is null or ord.payment_status = 'aprovado' then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'pago'); end if;
    if not exists (select 1 from public.pagamentos p where p.order_id = ord.id and p.eh_link and p.link_ativo and p.status = 'pendente' and (p.expira_em is null or p.expira_em > p_agora)) then
      return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'link_inativo');
    end if;
    select total into v_valor from public.order_financials where order_id = ord.id;
    v_texto := format('%s! Passando pra lembrar do seu pedido %s (%s), no valor de %s. Seu link de pagamento continua ativo, com Pix ou cartão em até 2x sem juros. Quer que eu reenvie o link?',
                      v_sauda, 'SG-' || lpad(ord.number::text, 4, '0'), coalesce(f.produto, 'pedido'), private.brl(coalesce(v_valor, 0)));
  end if;
  return jsonb_build_object('ok', true, 'acao', 'enviar', 'via', 'livre', 'texto', v_texto, 'template', null, 'params', null,
    'conversation_id', cv.id, 'regra', f.regra_codigo, 'janela_ate', cv.last_inbound_at + interval '24 hours', 'com_condicao', false,
    'simular', 'teste' = any (coalesce(ct.tags, '{}')) or f.teste);
end $$;
revoke all on function private.followup_montar_ad3h(uuid, timestamptz) from public, anon, authenticated;

-- Lembrete de orçamento em UTILITY: troca o template MARKETING pelo UTILITY, só se ele já foi aprovado como UTILITY
create or replace function private.followup_montar_utilidade(r jsonb, p_fila uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare f public.followup_fila%rowtype; o public.orcamentos%rowtype; ct public.contacts%rowtype; v_n integer; v_prod text; v_qtd text; v_val text;
begin
  if coalesce(r ->> 'acao', '') <> 'enviar' or r ->> 'template' is distinct from 'orcamento_vence_hoje' then return r; end if;
  if not exists (select 1 from public.templates_cache t where t.name = 'orcamento_lembrete_pedido' and t.status = 'APPROVED' and t.category = 'UTILITY') then return r; end if;
  select * into f from public.followup_fila where id = p_fila;
  if not found or f.orcamento_id is null then return r; end if;
  select * into o from public.orcamentos where id = f.orcamento_id;
  if o.id is null then return r; end if;
  select * into ct from public.contacts where id = f.contact_id;
  select count(*) into v_n from public.orcamento_itens where orcamento_id = o.id;
  select left(i.descricao, 80), trim(to_char(i.quantidade, 'FM999999990')) into v_prod, v_qtd from public.orcamento_itens i where i.orcamento_id = o.id order by i.criado_em limit 1;
  v_val := case when o.validade_ate is not null then to_char(o.validade_ate at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24"h"') else 'a data combinada' end;
  return jsonb_set(jsonb_set(r, '{template}', to_jsonb('orcamento_lembrete_pedido'::text)), '{params}', jsonb_build_array(
    coalesce(private.fu_nome(ct.name), 'você'), private.orcamento_numero(o.numero),
    coalesce(v_prod, 'seu pedido') || case when v_n > 1 then ' e mais ' || (v_n - 1)::text || ' item(ns)' else '' end,
    case when v_n > 1 then 'conforme o orçamento' else coalesce(v_qtd, 'conforme o orçamento') end,
    private.brl(o.total), v_val));
end $$;
revoke all on function private.followup_montar_utilidade(jsonb, uuid) from public, anon, authenticated;

create or replace function public.followup_montar(p_fila uuid, p_agora timestamptz default now())
returns jsonb language plpgsql security definer set search_path = '' as $$
declare f public.followup_fila%rowtype; cv public.conversations%rowtype; ct public.contacts%rowtype; v_texto text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into f from public.followup_fila where id = p_fila;
  if found and f.regra_codigo = 'F2_AD3H' then return private.followup_montar_ad3h(p_fila, p_agora); end if;
  if not found or f.regra_codigo <> 'Q2_RECUSA' then return private.followup_montar_utilidade(private.followup_montar_pre_recusa(p_fila, p_agora), p_fila); end if;

  select * into cv from public.conversations where id = f.conversation_id;
  select * into ct from public.contacts where id = f.contact_id;
  if cv.id is null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'sem_conversa'); end if;
  if exists (select 1 from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.created_at > f.criado_em and not private.fu_resposta_fria(m.body)) then
    return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'cliente_respondeu');
  end if;
  if cv.last_inbound_at is null or cv.last_inbound_at + interval '24 hours' < p_agora then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'janela_fechada'); end if;
  if exists (select 1 from public.orders x where x.contact_id = f.contact_id and x.excluido_em is null) then
    return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'ja_tem_pedido');
  end if;
  v_texto := private.fu_texto_tiragens_menores(cv.id, private.fu_nome(ct.name));
  if v_texto is null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'sem_tiragem_menor'); end if;
  return jsonb_build_object('ok', true, 'acao', 'enviar', 'via', 'livre', 'texto', v_texto, 'template', null, 'params', null,
    'conversation_id', cv.id, 'regra', f.regra_codigo, 'janela_ate', cv.last_inbound_at + interval '24 hours', 'com_condicao', false,
    'simular', 'teste' = any (coalesce(ct.tags, '{}')) or f.teste);
end $$;
