-- Etapa 4: origem declarada do cliente ("como nos conheceu?") para quem chega SEM anúncio.
-- Aditiva e idempotente. Nada de prompt do WF2: a instrução vai no contexto que a Laura já recebe (diretrizes_closer),
-- só para contato sem anúncio, que ainda não respondeu, que nunca foi perguntado e que já recebeu o PDF do orçamento.
--  * contacts.origem_declarada (+ detalhe, fonte, datas) com valores fechados.
--  * "Já perguntou" é marcado quando a mensagem enviada contém a pergunta (gatilho em messages), então nunca repete.
--  * A resposta entra pela ferramenta salvar_contato (origem, origem_detalhe) ou, de reserva, pela leitura das 2 primeiras
--    respostas do cliente depois da pergunta (palavras-chave; sem Gemini).
--  * Quem já pagou antes não é perguntado.

alter table public.contacts add column if not exists origem_declarada text;
alter table public.contacts add column if not exists origem_detalhe text;
alter table public.contacts add column if not exists origem_fonte text;
alter table public.contacts add column if not exists origem_declarada_em timestamptz;
alter table public.contacts add column if not exists origem_perguntada_em timestamptz;
alter table public.contacts drop constraint if exists contacts_origem_declarada_check;
alter table public.contacts add constraint contacts_origem_declarada_check
  check (origem_declarada is null or origem_declarada in ('anuncio', 'instagram', 'google', 'site', 'indicacao', 'ja_era_cliente', 'balcao', 'outro'));
alter table public.contacts drop constraint if exists contacts_origem_fonte_check;
alter table public.contacts add constraint contacts_origem_fonte_check
  check (origem_fonte is null or origem_fonte in ('laura', 'texto', 'dono'));

-- Texto livre -> valor fechado (null quando não reconhece)
create or replace function private.origem_normalizar(p text)
returns text language sql immutable set search_path = '' as $$
  select case
    when t is null or t = '' then null
    when t in ('anuncio', 'instagram', 'google', 'site', 'indicacao', 'ja_era_cliente', 'balcao', 'outro') then t
    when t ~ '(j[aá] (comprei|sou cliente|fui cliente|era cliente)|cliente de (voc|vc)|comprei (a[ií]|com (voc|vc)))' then 'ja_era_cliente'
    when t ~ 'insta' then 'instagram'
    when t ~ '(google|pesquis|busca)' then 'google'
    when t ~ '(indic|amig|conhecid|colega|parente|recomend)' then 'indicacao'
    when t ~ '(\msite\M|loja online|e-?commerce)' then 'site'
    when t ~ '(an[uú]ncio|facebook|propaganda|\mface\M|patrocinad)' then 'anuncio'
    when t ~ '(passei|ao lado|balc[aã]o|pra[cç]a|perto|vitrine|na rua|presencial)' then 'balcao'
    else null end
  from (select lower(btrim(coalesce(p, ''))) as t) x;
$$;
revoke all on function private.origem_normalizar(text) from public, anon, authenticated;

-- O que o contexto da Laura mostra e quando ela deve perguntar
create or replace function private.origem_contexto(p_contact uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'declarada', c.origem_declarada,
    'detalhe', c.origem_detalhe,
    'ja_perguntada', c.origem_perguntada_em is not null,
    'perguntar', (
      c.first_referral is null and v.last_referral is null
      and c.origem_declarada is null and c.origem_perguntada_em is null
      and not coalesce(c.is_teste, false)
      and not exists (select 1 from public.orders o where o.contact_id = c.id and o.payment_status = 'aprovado' and o.excluido_em is null)
      and exists (select 1 from public.orcamentos q where q.contact_id = c.id and q.pdf_enviado_em is not null)))
  from public.contacts c left join public.conversations v on v.contact_id = c.id where c.id = p_contact;
$$;
revoke all on function private.origem_contexto(uuid) from public, anon, authenticated;

-- Contexto da Laura: embrulha a função existente (sem copiar o corpo) e acrescenta a origem
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'agente_contexto_base_v0' and pronamespace = 'public'::regnamespace) then
    alter function public.agente_contexto_base(uuid) rename to agente_contexto_base_v0;
  end if;
end $$;
create or replace function public.agente_contexto_base(p_conversation uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb; v_ct uuid; o jsonb;
begin
  r := public.agente_contexto_base_v0(p_conversation);
  if not coalesce((r ->> 'ok')::boolean, false) then return r; end if;
  begin
    select contact_id into v_ct from public.conversations where id = p_conversation;
    o := private.origem_contexto(v_ct);
    r := jsonb_set(r, '{contato,origem}', o, true);
    if coalesce((o ->> 'perguntar')::boolean, false) then
      r := jsonb_set(r, '{regras_comerciais,diretrizes_closer,origem_do_cliente}', to_jsonb(
        'Este contato chegou sem anúncio e ainda não contou como nos conheceu. Pergunte UMA vez só, agora que o orçamento já foi enviado, em uma frase curta e natural, antes da pergunta de avanço do fechamento, por exemplo: "E só pra eu saber, como você conheceu a Sua Gráfica?". Não repita nem insista, e não deixe essa pergunta tomar o lugar do fechamento. Quando o cliente responder, salve com salvar_contato(origem = anuncio, instagram, google, site, indicacao, ja_era_cliente, balcao ou outro; se foi indicação, origem_detalhe = quem indicou). Se ele ignorar, siga o atendimento normalmente.'::text), true);
    end if;
  exception when others then
    raise warning 'agente_contexto_base origem: %', sqlerrm;
  end;
  return r;
end $$;
revoke all on function public.agente_contexto_base(uuid) from public, anon, authenticated;
grant execute on function public.agente_contexto_base(uuid) to service_role;

-- salvar_contato: embrulha a existente e grava a origem sem sobrescrever uma resposta do próprio cliente
do $$
begin
  if not exists (select 1 from pg_proc where proname = 'agente_salvar_contato_v0' and pronamespace = 'public'::regnamespace) then
    alter function public.agente_salvar_contato(uuid, jsonb) rename to agente_salvar_contato_v0;
  end if;
end $$;
create or replace function public.agente_salvar_contato(p_contact uuid, p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb; v_txt text := nullif(btrim(coalesce(p_dados ->> 'origem', p_dados ->> 'como_conheceu', '')), '');
        v_det text := nullif(btrim(coalesce(p_dados ->> 'origem_detalhe', p_dados ->> 'indicado_por', '')), ''); v_o text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  r := public.agente_salvar_contato_v0(p_contact, p_dados);
  if v_txt is not null and coalesce((r ->> 'ok')::boolean, false) then
    v_o := coalesce(private.origem_normalizar(v_txt), 'outro');
    update public.contacts set origem_declarada = v_o,
           origem_detalhe = coalesce(v_det, case when v_o = 'outro' then left(v_txt, 120) end, origem_detalhe),
           origem_fonte = 'laura', origem_declarada_em = now(), origem_perguntada_em = coalesce(origem_perguntada_em, now())
     where id = p_contact and (origem_declarada is null or origem_fonte = 'texto');
    r := r || jsonb_build_object('origem_salva', v_o);
  end if;
  return r;
end $$;
revoke all on function public.agente_salvar_contato(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.agente_salvar_contato(uuid, jsonb) to service_role;

-- "Já perguntou" = a pergunta saiu de fato na conversa (nunca repete)
create or replace function private.origem_marcar_pergunta()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.body ~* 'como (voc[eê]|vc|tu)( nos| a gente)? (conheceu|conheceram|achou|descobriu|encontrou|chegou)' then
    update public.contacts c set origem_perguntada_em = coalesce(c.origem_perguntada_em, new.created_at)
     where c.id = (select v.contact_id from public.conversations v where v.id = new.conversation_id);
  end if;
  return new;
exception when others then
  raise warning 'origem_marcar_pergunta: %', sqlerrm;
  return new;
end $$;
revoke all on function private.origem_marcar_pergunta() from public, anon, authenticated;
drop trigger if exists messages_origem_pergunta on public.messages;
create trigger messages_origem_pergunta after insert on public.messages
  for each row when (new.direction = 'out' and new.body is not null) execute function private.origem_marcar_pergunta();

-- Reserva sem IA: lê só as 2 primeiras respostas do cliente nas 12 h seguintes à pergunta
create or replace function private.origem_ler_resposta()
returns trigger language plpgsql security definer set search_path = '' as $$
declare c public.contacts%rowtype; v_o text;
begin
  select ct.* into c from public.contacts ct where ct.id = (select v.contact_id from public.conversations v where v.id = new.conversation_id);
  if not found or c.origem_perguntada_em is null or c.origem_declarada is not null then return new; end if;
  if new.created_at <= c.origem_perguntada_em or new.created_at > c.origem_perguntada_em + interval '12 hours' then return new; end if;
  if (select count(*) from public.messages m where m.conversation_id = new.conversation_id and m.direction = 'in' and m.created_at > c.origem_perguntada_em and m.created_at <= new.created_at) > 2 then return new; end if;
  v_o := private.origem_normalizar(new.body);
  if v_o is not null then
    update public.contacts set origem_declarada = v_o, origem_fonte = 'texto', origem_declarada_em = now() where id = c.id and origem_declarada is null;
  end if;
  return new;
exception when others then
  raise warning 'origem_ler_resposta: %', sqlerrm;
  return new;
end $$;
revoke all on function private.origem_ler_resposta() from public, anon, authenticated;
drop trigger if exists messages_origem_resposta on public.messages;
create trigger messages_origem_resposta after insert on public.messages
  for each row when (new.direction = 'in' and new.type = 'text' and new.body is not null) execute function private.origem_ler_resposta();
