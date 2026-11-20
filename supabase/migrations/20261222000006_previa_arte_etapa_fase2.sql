-- Fase 2 (Plano de Ação): gerador de prévia de arte com marca d'água (/previa/<token>).
-- Página pública temporária (48h), limite rígido por orçamento (2 gerações + 1 rodada de ajuste),
-- fila assíncrona processada por um worker fora do banco (Edge Function + API oficial configurável
-- por variável de ambiente, nunca credencial de assinatura pessoal). O banco só guarda a fila e as
-- travas; a geração em si (HTML/CSS/SVG -> PNG via Gotenberg, com marca d'água) roda na Edge Function.

-- ---------------------------------------------------------------- 1. tabela da fila
create table if not exists public.previas_arte (
  id uuid primary key default gen_random_uuid(),
  token text not null unique default replace(gen_random_uuid()::text, '-', ''),
  orcamento_id uuid not null references public.orcamentos(id),
  order_id uuid references public.orders(id),
  contact_id uuid references public.contacts(id),
  conversation_id uuid references public.conversations(id),
  sku text not null,
  produto_descricao text,
  produto_foto_path text,
  status text not null default 'pendente' check (status in ('pendente', 'processando', 'pronta', 'erro', 'aguardando_limite')),
  fase text not null default 'geracao' check (fase in ('geracao', 'ajuste')),
  geracoes integer not null default 0,
  ajustes integer not null default 0,
  briefing jsonb not null default '{}'::jsonb,
  uploads jsonb not null default '[]'::jsonb,
  feedback text,
  resultado_path text,
  erro_detalhe text,
  processando_desde timestamptz,
  expira_em timestamptz not null default now() + interval '48 hours',
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (orcamento_id)
);
create index if not exists previas_arte_fila_idx on public.previas_arte (status, criado_em) where status = 'pendente';

alter table public.previas_arte enable row level security;
drop policy if exists previas_arte_staff_ler on public.previas_arte;
create policy previas_arte_staff_ler on public.previas_arte for select to authenticated using (private.is_staff());
-- Sem policy de escrita: toda escrita é por service role (Edge Function), nunca pelo front.

-- ---------------------------------------------------------------- 2. storage
insert into storage.buckets (id, name, public) values ('previas-uploads', 'previas-uploads', false) on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('previas-arte', 'previas-arte', false) on conflict (id) do nothing;
drop policy if exists previas_uploads_staff_ler on storage.objects;
create policy previas_uploads_staff_ler on storage.objects for select to authenticated using (bucket_id = 'previas-uploads' and private.is_staff());
drop policy if exists previas_arte_staff_ler on storage.objects;
create policy previas_arte_staff_ler on storage.objects for select to authenticated using (bucket_id = 'previas-arte' and private.is_staff());

-- ---------------------------------------------------------------- 3. criar (chamada pelo n8n via gerar_link_previa, ou pelo painel)
create or replace function public.previa_arte_criar(p_orcamento uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  o public.orcamentos%rowtype;
  v public.previas_arte%rowtype;
  v_sku text;
  v_desc text;
  v_foto text;
  v_existe boolean;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'orcamento_nao_encontrado'); end if;
  if o.status in ('cancelado', 'pago', 'perdido') then return jsonb_build_object('ok', false, 'motivo', 'orcamento_encerrado'); end if;

  select * into v from public.previas_arte where orcamento_id = p_orcamento;
  v_existe := found;
  if v_existe and v.expira_em > now() then
    return jsonb_build_object('ok', true, 'token', v.token, 'status', v.status, 'reutilizado', true);
  end if;

  select i.sku, coalesce(i.descricao, i.especificacao) into v_sku, v_desc
    from public.orcamento_itens i where i.orcamento_id = p_orcamento order by i.criado_em, i.id limit 1;
  if v_sku is null then return jsonb_build_object('ok', false, 'motivo', 'orcamento_sem_item'); end if;
  select (p.fotos ->> 0) into v_foto from public.ecommerce_products p where p.sku = v_sku;

  if v_existe then
    update public.previas_arte set
      token = replace(gen_random_uuid()::text, '-', ''), status = 'pendente', fase = 'geracao',
      sku = v_sku, produto_descricao = v_desc, produto_foto_path = v_foto, conversation_id = o.conversation_id,
      briefing = '{}'::jsonb, uploads = '[]'::jsonb, feedback = null, resultado_path = null, erro_detalhe = null,
      geracoes = 0, ajustes = 0, processando_desde = null,
      expira_em = now() + interval '48 hours', criado_em = now(), atualizado_em = now()
    where id = v.id
    returning * into v;
    return jsonb_build_object('ok', true, 'token', v.token, 'status', v.status, 'reutilizado', false);
  end if;

  insert into public.previas_arte (orcamento_id, order_id, contact_id, conversation_id, sku, produto_descricao, produto_foto_path)
  values (p_orcamento, o.order_id, o.contact_id, o.conversation_id, v_sku, v_desc, v_foto)
  returning * into v;
  return jsonb_build_object('ok', true, 'token', v.token, 'status', v.status, 'reutilizado', false);
end;
$function$;

-- ---------------------------------------------------------------- 4. status público (o token é o comprovante, como /pagar/<token>)
create or replace function public.previa_arte_status(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare v public.previas_arte%rowtype;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  select * into v from public.previas_arte where token = p_token;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  if v.expira_em <= now() then return jsonb_build_object('ok', false, 'motivo', 'expirado'); end if;
  return jsonb_build_object(
    'ok', true, 'status', v.status, 'sku', v.sku, 'produto_descricao', v.produto_descricao,
    'produto_foto_path', v.produto_foto_path, 'briefing', v.briefing, 'uploads', v.uploads, 'feedback', v.feedback,
    'resultado_path', v.resultado_path, 'erro_detalhe', case when v.status = 'erro' then v.erro_detalhe else null end,
    'geracoes', v.geracoes, 'ajustes', v.ajustes,
    'pode_gerar_de_novo', v.status = 'pronta' and v.geracoes < 2 and v.ajustes = 0,
    'pode_ajustar', v.status = 'pronta' and v.ajustes < 1,
    'expira_em', v.expira_em, 'order_id', v.order_id
  );
end;
$function$;

-- ---------------------------------------------------------------- 5. briefing inicial (1ª geração)
create or replace function public.previa_arte_enviar_briefing(p_token text, p_briefing jsonb, p_uploads jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v public.previas_arte%rowtype;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  select * into v from public.previas_arte where token = p_token for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  if v.expira_em <= now() then return jsonb_build_object('ok', false, 'motivo', 'expirado'); end if;
  if v.geracoes > 0 then return jsonb_build_object('ok', false, 'motivo', 'ja_enviado', 'alternativa', 'Use previa_arte_regenerar ou previa_arte_ajustar.'); end if;
  if jsonb_typeof(p_uploads) <> 'array' or jsonb_array_length(p_uploads) > 2 then
    return jsonb_build_object('ok', false, 'motivo', 'uploads_invalidos', 'alternativa', 'No máximo 2 imagens.');
  end if;
  update public.previas_arte set briefing = coalesce(p_briefing, '{}'::jsonb), uploads = p_uploads,
    status = 'pendente', fase = 'geracao', atualizado_em = now()
  where id = v.id;
  return jsonb_build_object('ok', true, 'status', 'pendente');
end;
$function$;

-- ---------------------------------------------------------------- 6. gerar de novo (2ª geração, sem feedback)
create or replace function public.previa_arte_regenerar(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v public.previas_arte%rowtype;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  select * into v from public.previas_arte where token = p_token for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  if v.expira_em <= now() then return jsonb_build_object('ok', false, 'motivo', 'expirado'); end if;
  if v.status <> 'pronta' then return jsonb_build_object('ok', false, 'motivo', 'ainda_nao_pronta'); end if;
  if v.geracoes >= 2 then return jsonb_build_object('ok', false, 'motivo', 'limite_geracao_atingido', 'alternativa', 'Use previa_arte_ajustar com feedback.'); end if;
  if v.ajustes > 0 then return jsonb_build_object('ok', false, 'motivo', 'ja_em_rodada_de_ajuste'); end if;
  update public.previas_arte set status = 'pendente', fase = 'geracao', erro_detalhe = null, atualizado_em = now() where id = v.id;
  return jsonb_build_object('ok', true, 'status', 'pendente');
end;
$function$;

-- ---------------------------------------------------------------- 7. ajuste por feedback (1 rodada, conta à parte das gerações)
create or replace function public.previa_arte_ajustar(p_token text, p_feedback text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v public.previas_arte%rowtype; v_fb text;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  v_fb := nullif(btrim(coalesce(p_feedback, '')), '');
  if v_fb is null then return jsonb_build_object('ok', false, 'motivo', 'feedback_vazio'); end if;
  select * into v from public.previas_arte where token = p_token for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  if v.expira_em <= now() then return jsonb_build_object('ok', false, 'motivo', 'expirado'); end if;
  if v.status <> 'pronta' then return jsonb_build_object('ok', false, 'motivo', 'ainda_nao_pronta'); end if;
  if v.ajustes >= 1 then
    -- Limite de IA esgotado: o feedback ainda é salvo para a equipe de criação aplicar na arte final pós-pagamento.
    update public.previas_arte set feedback = left(v_fb, 2000), atualizado_em = now() where id = v.id;
    update public.orcamentos set alternativas = coalesce(alternativas, '[]'::jsonb) ||
      jsonb_build_object('feedback_previa', left(v_fb, 2000), 'em', now())
      where id = v.orcamento_id;
    return jsonb_build_object('ok', true, 'motivo', 'feedback_salvo_sem_nova_geracao', 'status', v.status);
  end if;
  update public.previas_arte set feedback = left(v_fb, 2000), status = 'pendente', fase = 'ajuste', erro_detalhe = null, atualizado_em = now() where id = v.id;
  return jsonb_build_object('ok', true, 'status', 'pendente');
end;
$function$;

-- ---------------------------------------------------------------- 8. fechar agora (botão "Gostei, quero fechar agora" -> /pagar/<token>)
create or replace function public.previa_arte_fechar(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v public.previas_arte%rowtype; v_val jsonb; v_order uuid; v_checkout text;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  select * into v from public.previas_arte where token = p_token;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'link_invalido'); end if;
  if v.expira_em <= now() then return jsonb_build_object('ok', false, 'motivo', 'expirado'); end if;
  v_val := public.validar_margem(v.orcamento_id);
  if v_val ->> 'status' <> 'ok' then return jsonb_build_object('ok', false, 'motivo', v_val ->> 'motivo', 'alternativa', 'Chame o dono.'); end if;
  v_order := private.orcamento_para_pedido(v.orcamento_id);
  select checkout_token into v_checkout from public.orders where id = v_order;
  update public.previas_arte set order_id = v_order, atualizado_em = now() where id = v.id;
  return jsonb_build_object('ok', true, 'checkout_token', v_checkout);
end;
$function$;

-- ---------------------------------------------------------------- 9. fila do worker (service role só)
create or replace function public.previa_arte_proxima()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v public.previas_arte%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  -- Destrava automaticamente itens travados em 'processando' há mais de 10 minutos (worker caiu no meio)
  update public.previas_arte set status = 'pendente', processando_desde = null
  where status = 'processando' and processando_desde <= now() - interval '10 minutes';
  -- Tenta de novo os que esbarraram em limite de taxa/cota da API, depois de um tempo de espera
  update public.previas_arte set status = 'pendente'
  where status = 'aguardando_limite' and atualizado_em <= now() - interval '5 minutes';

  select * into v from public.previas_arte
   where id = (select id from public.previas_arte where status = 'pendente' and expira_em > now() order by criado_em limit 1 for update skip locked);
  if not found then return jsonb_build_object('ok', false, 'motivo', 'fila_vazia'); end if;
  update public.previas_arte set status = 'processando', processando_desde = now() where id = v.id;
  return jsonb_build_object('ok', true, 'id', v.id, 'token', v.token, 'sku', v.sku, 'produto_descricao', v.produto_descricao,
    'produto_foto_path', v.produto_foto_path, 'briefing', v.briefing, 'uploads', v.uploads, 'feedback', v.feedback, 'fase', v.fase,
    'conversation_id', v.conversation_id, 'vinha_de_limite', v.erro_detalhe is not null);
end;
$function$;

create or replace function public.previa_arte_concluir(p_id uuid, p_status text, p_resultado_path text default null, p_erro text default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v public.previas_arte%rowtype; v_estava_no_limite boolean;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_status not in ('pronta', 'erro', 'aguardando_limite') then return jsonb_build_object('ok', false, 'motivo', 'status_invalido'); end if;
  select * into v from public.previas_arte where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'nao_encontrada'); end if;
  v_estava_no_limite := v.erro_detalhe is not null;
  update public.previas_arte set
    status = p_status,
    resultado_path = case when p_status = 'pronta' then p_resultado_path else resultado_path end,
    erro_detalhe = case when p_status in ('erro', 'aguardando_limite') then left(coalesce(p_erro, ''), 500) else null end,
    geracoes = case when p_status = 'pronta' and v.fase = 'geracao' then geracoes + 1 else geracoes end,
    ajustes = case when p_status = 'pronta' and v.fase = 'ajuste' then ajustes + 1 else ajustes end,
    processando_desde = null, atualizado_em = now()
  where id = p_id;
  return jsonb_build_object('ok', true, 'recuperou_de_limite', p_status = 'pronta' and v_estava_no_limite,
    'conversation_id', v.conversation_id, 'token', v.token);
end;
$function$;
