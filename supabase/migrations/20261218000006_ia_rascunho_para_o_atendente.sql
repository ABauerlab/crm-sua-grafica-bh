-- Botão "Responder com IA" (18/11/2026): em conversa assumida pelo humano, a IA lê as últimas mensagens do cliente e escreve uma sugestão de resposta
-- no campo do chat para o atendente revisar e enviar. Nada é enviado ao cliente pela IA. Reaproveita o cérebro da Laura (WF2) e as travas de saída.
-- Aplicada pelo conector em duas partes (ia_rascunho_para_o_atendente e ia_rascunho_execucao_sem_mensagem). Este arquivo reúne o estado final. Idempotente.
alter table public.agente_execucoes add column if not exists rascunho boolean not null default false;
-- a execução de rascunho não pertence a uma mensagem (cada mensagem só pode ter uma execução real da Laura)
alter table public.agente_execucoes alter column message_id drop not null;

create table if not exists public.ia_rascunhos (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  execucao_id uuid references public.agente_execucoes (id) on delete set null,
  status text not null default 'gerando' check (status in ('gerando', 'pronto', 'erro')),
  texto text,
  erro text,
  criado_por uuid,
  criado_em timestamptz not null default now(),
  concluido_em timestamptz
);
create index if not exists ia_rascunhos_conversa_idx on public.ia_rascunhos (conversation_id, criado_em desc);
alter table public.ia_rascunhos enable row level security;
do $p$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ia_rascunhos' and policyname = 'ia_rascunhos_leitura') then
    create policy ia_rascunhos_leitura on public.ia_rascunhos for select to authenticated using (private.is_staff());
  end if;
end $p$;
revoke all on public.ia_rascunhos from anon;
grant select on public.ia_rascunhos to authenticated;

create or replace function public.ia_rascunho_preparar(p_conversation uuid, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_conv public.conversations%rowtype; v_msg uuid; v_texto text; v_exec uuid; v_r uuid; v_cfg record; v_ctx jsonb; v_rec public.ia_rascunhos%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into v_conv from public.conversations where id = p_conversation;
  if not found then return jsonb_build_object('ok', false, 'erro', 'Conversa não encontrada.'); end if;
  select * into v_rec from public.ia_rascunhos where conversation_id = p_conversation and status = 'gerando' and criado_em > now() - interval '4 minutes' order by criado_em desc limit 1;
  if found then return jsonb_build_object('ok', true, 'ja_gerando', true, 'rascunho_id', v_rec.id); end if;
  select id into v_msg from public.messages where conversation_id = p_conversation and direction = 'in' and deleted_at is null order by created_at desc limit 1;
  if v_msg is null then return jsonb_build_object('ok', false, 'erro', 'O cliente ainda não mandou mensagem para responder.'); end if;
  select string_agg(x.body, E'\n' order by x.created_at) into v_texto from (
    select m.body, m.created_at from public.messages m
     where m.conversation_id = p_conversation and m.direction = 'in' and m.deleted_at is null and m.body is not null
       and m.created_at > coalesce((select max(o.created_at) from public.messages o where o.conversation_id = p_conversation and o.direction = 'out' and o.deleted_at is null and o.created_at < (select created_at from public.messages where id = v_msg)), '-infinity'::timestamptz)
     order by m.created_at desc limit 8) x;
  if v_texto is null or btrim(v_texto) = '' then
    select string_agg(x.body, E'\n' order by x.created_at) into v_texto from (select m.body, m.created_at from public.messages m where m.conversation_id = p_conversation and m.direction = 'in' and m.deleted_at is null and m.body is not null order by m.created_at desc limit 3) x;
  end if;
  select modelo_padrao, nome_atendente into v_cfg from public.agente_config where id = 1;
  insert into public.agente_execucoes (conversation_id, contact_id, message_id, status, motivo, modelo, teste, rascunho)
  values (p_conversation, v_conv.contact_id, null, 'recebida', 'rascunho', v_cfg.modelo_padrao, false, true) returning id into v_exec;
  insert into public.ia_rascunhos (conversation_id, execucao_id, criado_por) values (p_conversation, v_exec, p_user) returning id into v_r;
  v_ctx := public.agente_contexto(p_conversation) || jsonb_build_object('modo_rascunho', true);
  return jsonb_build_object('ok', true, 'rascunho_id', v_r, 'execucao_id', v_exec, 'conversation_id', p_conversation, 'contact_id', v_conv.contact_id,
    'texto_cliente', left(coalesce(v_texto, ''), 2500), 'contexto', v_ctx, 'modelo', v_cfg.modelo_padrao, 'nome_atendente', v_cfg.nome_atendente);
end $f$;
revoke all on function public.ia_rascunho_preparar(uuid, uuid) from public, anon;
grant execute on function public.ia_rascunho_preparar(uuid, uuid) to authenticated, service_role;

create or replace function public.ia_rascunho_salvar(p_rascunho uuid, p_texto text, p_erro text default null) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare v_r public.ia_rascunhos%rowtype; v_ok boolean := coalesce(btrim(p_texto), '') <> '' and p_erro is null;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.ia_rascunhos set status = case when v_ok then 'pronto' else 'erro' end, texto = case when v_ok then btrim(p_texto) end,
         erro = case when v_ok then null else coalesce(nullif(btrim(p_erro), ''), 'A IA não conseguiu escrever uma resposta agora.') end, concluido_em = now()
   where id = p_rascunho and status = 'gerando' returning * into v_r;
  if found and v_r.execucao_id is not null then
    perform public.agente_finalizar(v_r.execucao_id, case when v_ok then 'concluida' else 'erro' end, 'rascunho');
  end if;
  return jsonb_build_object('ok', found);
end $f$;
revoke all on function public.ia_rascunho_salvar(uuid, text, text) from public, anon, authenticated;
grant execute on function public.ia_rascunho_salvar(uuid, text, text) to service_role;

-- no modo rascunho a IA NÃO executa ações que falam com o cliente ou criam compromissos (PDF, link, foto, condição especial, lembrete, arte, chamar o dono)
do $m$
declare d text; n text; a text := $q$select * into cfg from public.agente_config where id = 1;$q$;
begin
  select pg_get_functiondef('public.agente_tool_inicio(uuid,text)'::regprocedure) into d;
  if position('rascunho_bloqueio' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception 'agente_tool_inicio mudou: âncora não encontrada'; end if;
  n := replace(d, a, a || $q$
  if exists (select 1 from public.agente_execucoes ex where ex.id = p_execucao and ex.rascunho) /* rascunho_bloqueio */
     and p_ferramenta not in ('buscar_produto', 'buscar_conhecimento', 'montar_orcamento', 'verificar_frete', 'salvar_contato') then
    return jsonb_build_object('permitido', false, 'motivo', 'rascunho');
  end if;$q$);
  execute n;
end $m$;
-- URL do gatilho de rascunho do n8n: app_settings.ia_rascunho = {"url": "..."} (lida só pela Edge Function ia-rascunho).
