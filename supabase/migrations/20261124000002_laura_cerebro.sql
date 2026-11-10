-- Fase 11: cérebro de contexto da Laura (conversations.brain). Calculado no banco a cada mensagem recebida, sem modelo de IA.
-- Guarda o que o cliente pediu (itens, quantidades, acabamento), o assunto atual, os últimos assuntos e as dúvidas ainda sem resposta,
-- para a Laura retomar de onde parou mesmo quando o cliente muda de assunto. Nunca guarda SKU, custo, piso nem margem.

alter table public.conversations add column if not exists brain jsonb not null default '{}'::jsonb;

create or replace function private.cerebro_assunto(p text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p ~* '(prazo|entrega|frete|retirar|retirada|bairro|\mcep\M|quando fica)' then 'entrega'
    when p ~* '(nota fiscal|nf-?e|cnpj|\mcpf\M)' then 'nota_fiscal'
    when p ~* '(\mpix\M|cart[aã]o de cr|pagar|pagamento|parcel|link)' then 'pagamento'
    when p ~* '(pre[cç]o|valor|quanto|or[cç]amento|desconto|caro|barato|concorr)' then 'preco'
    when p ~* '(\marte\M|layout|logo|arquivo|gabarito|design)' then 'arte'
    when p ~* '(foto|imagem|exemplo|modelo|papel|acabamento|lamina|verniz|tamanho|couch)' then 'produto'
    else 'outro' end;
$$;

create or replace function private.cerebro_recalcular(p_conversation uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c record; v_ult_out timestamptz; v_in text; v_assunto text; v_duv jsonb; v_itens jsonb := '[]'::jsonb; v_orc jsonb := null;
  v_ant jsonb; v_rec jsonb; v_brain jsonb; o record;
begin
  select cv.id, cv.contact_id, cv.collected_data, cv.brain into c from public.conversations cv where cv.id = p_conversation;
  if not found then return null; end if;
  select max(m.created_at) into v_ult_out from public.messages m where m.conversation_id = p_conversation and m.direction = 'out';
  select m.body into v_in from public.messages m
   where m.conversation_id = p_conversation and m.direction = 'in' and m.body is not null and m.deleted_at is null
   order by m.created_at desc limit 1;
  v_assunto := case when v_in is null then c.brain ->> 'assunto_atual' else private.cerebro_assunto(v_in) end;
  select coalesce(jsonb_agg(left(x.body, 160) order by x.created_at), '[]'::jsonb) into v_duv from (
    select m.body, m.created_at from public.messages m
     where m.conversation_id = p_conversation and m.direction = 'in' and m.body ~ '\?' and m.deleted_at is null
       and (v_ult_out is null or m.created_at > v_ult_out)
     order by m.created_at desc limit 3) x;
  select q.id, q.numero, q.status, q.total into o from public.orcamentos q
   where q.contact_id = c.contact_id and q.status in ('rascunho', 'enviado', 'pago') order by q.criado_em desc limit 1;
  if found then
    v_orc := jsonb_build_object('numero', o.numero, 'status', o.status, 'total', o.total);
    select coalesce(jsonb_agg(jsonb_build_object('produto', left(i.descricao, 120), 'quantidade', i.quantidade, 'acabamento', i.acabamento) order by i.criado_em), '[]'::jsonb)
      into v_itens from (select * from public.orcamento_itens where orcamento_id = o.id order by criado_em limit 20) i;
  end if;
  v_ant := coalesce(c.brain -> 'assuntos_recentes', '[]'::jsonb);
  select coalesce(jsonb_agg(y.a order by y.mo), '[]'::jsonb) into v_rec from (
    select z.a, min(z.ord) mo from (
      select v_assunto a, 0::bigint ord where v_assunto is not null
      union all select t.e, t.n from jsonb_array_elements_text(v_ant) with ordinality t(e, n)) z
    group by z.a order by min(z.ord) limit 5) y;
  v_brain := jsonb_build_object(
    'versao', 1,
    'interesse', nullif(left(coalesce(c.collected_data ->> 'interesse', ''), 120), ''),
    'quantidade', nullif(left(coalesce(c.collected_data ->> 'quantidade', ''), 20), ''),
    'itens', v_itens,
    'orcamento', v_orc,
    'assunto_atual', v_assunto,
    'assuntos_recentes', v_rec,
    'duvidas_pendentes', v_duv,
    'atualizado_em', now());
  update public.conversations set brain = v_brain where id = p_conversation;
  return v_brain;
end $$;
revoke all on function private.cerebro_recalcular(uuid) from public, anon, authenticated;

create or replace function public.agente_cerebro_atualizar(p_conversation uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return private.cerebro_recalcular(p_conversation);
end $$;
revoke all on function public.agente_cerebro_atualizar(uuid) from public, anon;
grant execute on function public.agente_cerebro_atualizar(uuid) to authenticated, service_role;

-- A cada mensagem recebida que a Laura vai processar, o cérebro é atualizado (falha aqui nunca derruba o atendimento)
create or replace function public.agente_entrada(p_message uuid, p_teste boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb; p jsonb;
begin
  r := public.agente_entrada_base(p_message, p_teste);
  if coalesce((r ->> 'processar')::boolean, false) and r ->> 'conversation_id' is not null then
    p := public.agente_persona((r ->> 'conversation_id')::uuid);
    r := r || jsonb_build_object('persona', p, 'nome_atendente', p ->> 'nome', 'fase', p ->> 'fase');
    begin
      perform private.cerebro_recalcular((r ->> 'conversation_id')::uuid);
    exception when others then null;
    end;
  end if;
  return r;
end $$;

-- O contexto da Laura passa a levar o cérebro
create or replace function public.agente_contexto(p_conversation uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r jsonb; p jsonb; b jsonb;
begin
  r := public.agente_contexto_base(p_conversation);
  if r ? 'erro' then return r; end if;
  p := public.agente_persona(p_conversation);
  select cv.brain into b from public.conversations cv where cv.id = p_conversation;
  return r || jsonb_build_object('persona', p, 'nome_atendente', p ->> 'nome', 'fase', p ->> 'fase', 'cerebro', coalesce(b, '{}'::jsonb));
end $$;
