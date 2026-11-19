-- 19/11/2026: cliente que recebe o preço e responde frio ("ok", "obrigada", "vou ver") declinou.
-- A Laura responde na hora com as tiragens menores do MESMO produto, da menor quantidade até a anterior à pedida.
-- Preço sempre de calcular_preco (planilha + travas de lucro). Aditiva e idempotente.

alter table public.followup_regras drop constraint if exists followup_regras_referencia_check;
alter table public.followup_regras add constraint followup_regras_referencia_check
  check (referencia = any (array['orcamento_enviado', 'link_pagamento', 'pedido_entregue', 'pedido_pago', 'conversa_parada', 'checkout_aberto', 'anuncio_parado', 'recusa_preco']));

insert into public.followup_regras (codigo, descricao, referencia, atraso_minutos, hora_min, hora_max, ativo, revisar)
values ('Q2_RECUSA', 'Cliente respondeu frio ao preço (ok, obrigada, vou ver): 1 minuto depois, tiragens menores do mesmo produto, da menor até a anterior à pedida', 'recusa_preco', 1, 7, 22, true, false)
on conflict (codigo) do nothing;

-- Resposta fria ao preço (texto normalizado, curto)
create or replace function private.fu_resposta_fria(p text) returns boolean
language sql immutable set search_path = '' as $$
  select private.texto_norm(coalesce(p, '')) ~ '^(ok|okay|obrigad[ao]|valeu|beleza|blz|certo|entendi|ta bom|ta ok|vou ver|vou pensar|vou avaliar|depois eu vejo|talvez|ta caro|caro|muito caro|muito alto|ficou caro)([ ,.!]+(ok|okay|obrigad[ao]|valeu|beleza|certo|entendi))*[ .!]*$'
$$;
revoke all on function private.fu_resposta_fria(text) from public, anon, authenticated;

-- Última cotação em texto da conversa: devolve o SKU cotado, a quantidade e o horário
create or replace function private.fu_ultima_cotacao(p_conv uuid)
returns table (sku text, quantidade integer, cotado_em timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare m record; v_preco numeric; v_q integer;
begin
  select x.body, x.created_at into m from public.messages x
   where x.conversation_id = p_conv and x.direction = 'out' and x.body ~ 'R\$ ?[0-9]' and x.body ~* 'unidades'
   order by x.created_at desc limit 1;
  if m.body is null then return; end if;
  v_q := nullif(substring(m.body from '(?i)para ([0-9][0-9.]*) unidades'), '')::integer;
  if v_q is null then v_q := nullif(replace(substring(m.body from '(?i)([0-9][0-9.]*) unidades'), '.', ''), '')::integer; end if;
  v_preco := replace(replace(substring(m.body from 'R\$ ?([0-9][0-9.]*,[0-9]{2})'), '.', ''), ',', '.')::numeric;
  return query
    select c.sku, c.quantidade, m.created_at
      from public.catalogo c
     where c.active and c.vendavel and c.preco_venda is not null
       and c.preco_venda = v_preco and (v_q is null or c.quantidade = replace(v_q::text, '.', '')::integer)
     order by c.sku limit 1;
end $$;
revoke all on function private.fu_ultima_cotacao(uuid) from public, anon, authenticated;

-- Texto: tiragens menores do mesmo produto (menor preço por quantidade), preço de calcular_preco
create or replace function private.fu_texto_tiragens_menores(p_conv uuid, p_nome text) returns text
language plpgsql security definer set search_path = '' as $$
declare k record; b public.catalogo%rowtype; v_linhas text; v_prod text; v_n integer;
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
  select string_agg(E'\n• ' || t.quantidade || ' unidades: ' || private.brl(t.preco), '' order by t.quantidade), count(*)
    into v_linhas, v_n from t where t.preco is not null and t.ok;
  if v_linhas is null then return null; end if;
  v_prod := lower(initcap(lower(b.categoria)));
  return format('%s, tranquilo! Se o valor de %s unidades pesou, dá pra começar com uma tiragem menor do mesmo %s (mesmo papel e tamanho):%s' || E'\n\n' ||
                'O Pix de qualquer banco cai na hora e o cartão vai em até 2x sem juros. Qual dessas cabe melhor pra você?',
                p_nome, b.quantidade, v_prod, v_linhas);
end $$;
revoke all on function private.fu_texto_tiragens_menores(uuid, text) from public, anon, authenticated;

-- Agendamento: depois do preço, só respostas frias do cliente, sem pedido, ainda na janela de 24 h
create or replace function private.fu_agendar_recusa(p_agora timestamptz default now()) returns integer
language plpgsql security definer set search_path = '' as $$
declare r public.followup_regras%rowtype; v_n integer := 0;
begin
  select * into r from public.followup_regras where codigo = 'Q2_RECUSA' and ativo;
  if not found then return 0; end if;
  insert into public.followup_fila (contact_id, conversation_id, regra_codigo, chave, agendado_para, teste)
  select cv.contact_id, cv.id, r.codigo, r.codigo || ':' || cv.id::text || ':' || q.sku,
         private.fu_proxima_janela(cv.last_inbound_at + make_interval(mins => r.atraso_minutos), r.hora_min, r.hora_max),
         'teste' = any (coalesce(ct.tags, '{}'))
    from public.conversations cv
    join public.contacts ct on ct.id = cv.contact_id
    cross join lateral private.fu_ultima_cotacao(cv.id) q
   where cv.last_inbound_at > p_agora - interval '20 hours'
     and coalesce(cv.modo_atendimento, 'ia') = 'ia' and not coalesce(ct.optout, false)
     and exists (select 1 from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.created_at > q.cotado_em)
     and not exists (select 1 from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.created_at > q.cotado_em
                       and not private.fu_resposta_fria(m.body))
     and not exists (select 1 from public.orders xo where xo.contact_id = cv.contact_id and xo.excluido_em is null)
  on conflict (chave) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function private.fu_agendar_recusa(timestamptz) from public, anon, authenticated;

-- Invólucros: acrescentam a regra Q2_RECUSA sem mexer na lógica anterior (a versão atual de followup_montar vira _pre_recusa)
do $$
begin
  if to_regprocedure('private.followup_montar_pre_recusa(uuid,timestamptz)') is null then
    alter function public.followup_montar(uuid, timestamptz) set schema private;
    alter function private.followup_montar(uuid, timestamptz) rename to followup_montar_pre_recusa;
  end if;
end $$;
revoke all on function private.followup_montar_pre_recusa(uuid, timestamptz) from public, anon, authenticated;

create or replace function public.followup_agendar(p_agora timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v jsonb; v_ad integer := 0; v_rc integer := 0;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  v := private.followup_agendar_base(p_agora);
  begin v_ad := private.fu_agendar_anuncio(p_agora); exception when others then raise warning 'agendar anúncio: %', sqlerrm; end;
  begin v_rc := private.fu_agendar_recusa(p_agora); exception when others then raise warning 'agendar recusa: %', sqlerrm; end;
  return v || jsonb_build_object('anuncio', v_ad, 'recusa_preco', v_rc);
end $$;
revoke all on function public.followup_agendar(timestamptz) from public, anon;
grant execute on function public.followup_agendar(timestamptz) to authenticated, service_role;

create or replace function public.followup_montar(p_fila uuid, p_agora timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f public.followup_fila%rowtype; cv public.conversations%rowtype; ct public.contacts%rowtype; v_texto text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into f from public.followup_fila where id = p_fila;
  if not found or f.regra_codigo <> 'Q2_RECUSA' then return private.followup_montar_pre_recusa(p_fila, p_agora); end if;

  select * into cv from public.conversations where id = f.conversation_id;
  select * into ct from public.contacts where id = f.contact_id;
  if cv.id is null then return jsonb_build_object('ok', true, 'acao', 'pular', 'motivo', 'sem_conversa'); end if;
  if cv.last_inbound_at > f.criado_em and exists (select 1 from public.messages m where m.conversation_id = cv.id and m.direction = 'in' and m.created_at > f.criado_em and not private.fu_resposta_fria(m.body)) then
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
revoke all on function public.followup_montar(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.followup_montar(uuid, timestamptz) to service_role;
