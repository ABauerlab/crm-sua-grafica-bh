-- Etapa 4B: aplicar no SQL Editor do Supabase (migrations 20261030000001 e 20261030000002). Idempotente.
-- Agente de IA, Etapa 4B: fotos de produto para o agente enviar no chat.
-- Aditiva e idempotente. A origem das imagens é INTERNA: o endereço dela fica em app_settings.fotos (preenchido pelo dono, nunca no repositório)
-- e a coluna url_origem só é legível pelo dono. O agente e o cliente nunca recebem origem.
-- Atenção: as Edge Functions (service role) não alcançam o schema private; por isso tudo que elas chamam está em public.

-- ---------------------------------------------------------------- 1. parâmetros
insert into public.app_settings (key, value) values ('fotos', jsonb_build_object(
  'origem_base', '',                 -- endereço do site de origem (o dono preenche pelo painel; fora do repositório)
  'ligado', true,
  'cache_dias', 30,
  'aquecer_ligado', false,           -- aquecer o cache dos 30 grupos mais pedidos, em lotes pequenos de madrugada
  'verificar_marca', true,           -- confere com modelo de visão se a imagem tem logotipo ou nome de empresa
  'max_por_pedido', 3,
  'pedidos_por_minuto', 1,
  'imagens_por_contato_dia', 10
)) on conflict (key) do nothing;

-- ---------------------------------------------------------------- 2. tabelas
create table if not exists public.produto_fotos (
  id uuid primary key default gen_random_uuid(),
  grupo_produto text not null,
  url_origem text,                                -- INTERNA: só o dono lê
  arquivo_storage text,                           -- nome neutro (hash) no bucket produto-fotos
  largura integer,
  altura integer,
  bytes integer,
  hash text,
  status text not null default 'pendente' check (status in ('pendente', 'aprovada', 'bloqueada', 'sem_foto')),
  revisar boolean not null default false,
  motivo text,                                    -- por que foi bloqueada ou precisa de revisão (texto interno)
  aproximada boolean not null default true,       -- true: foto do grupo, não do item exato (a legenda diz que é ilustrativa)
  ordem integer not null default 0,
  atualizado_em timestamptz not null default now(),
  criado_em timestamptz not null default now()
);
create unique index if not exists produto_fotos_hash_idx on public.produto_fotos (grupo_produto, hash) where hash is not null;
create index if not exists produto_fotos_grupo_idx on public.produto_fotos (grupo_produto, status);

-- Um registro por grupo: controla o cache de 30 dias (a origem é consultada no máximo uma vez por grupo nesse período)
create table if not exists public.produto_fotos_grupos (
  grupo_produto text primary key,
  situacao text not null default 'ok' check (situacao in ('ok', 'sem_foto', 'erro')),
  buscado_em timestamptz not null default now(),
  expira_em timestamptz not null,
  detalhe text,
  pedidos integer not null default 0                -- quantas vezes pediram foto deste grupo (ranking para aquecer o cache)
);

-- Registro dos envios (alimenta os limites por conversa e por contato)
create table if not exists public.produto_fotos_envios (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references public.conversations (id) on delete set null,
  contact_id uuid references public.contacts (id) on delete set null,
  grupo_produto text,
  quantidade integer not null default 0,
  bytes integer not null default 0,
  via text check (via in ('cache', 'busca')),
  resultado text not null default 'enviada',        -- enviada, sem_foto, muito_rapido, limite_diario, erro
  criado_em timestamptz not null default now()
);
create index if not exists produto_fotos_envios_conversa_idx on public.produto_fotos_envios (conversation_id, criado_em desc);
create index if not exists produto_fotos_envios_contato_idx on public.produto_fotos_envios (contact_id, criado_em desc);

alter table public.produto_fotos enable row level security;
alter table public.produto_fotos_grupos enable row level security;
alter table public.produto_fotos_envios enable row level security;
revoke all on public.produto_fotos, public.produto_fotos_grupos, public.produto_fotos_envios from anon, authenticated;
-- só o dono lê pelo CRM; a escrita é sempre pelas funções abaixo (definer) ou pela Edge Function (service role)
grant select on public.produto_fotos, public.produto_fotos_grupos, public.produto_fotos_envios to authenticated;
drop policy if exists produto_fotos_dono on public.produto_fotos;
create policy produto_fotos_dono on public.produto_fotos for select to authenticated using (private.is_staff());
drop policy if exists produto_fotos_grupos_dono on public.produto_fotos_grupos;
create policy produto_fotos_grupos_dono on public.produto_fotos_grupos for select to authenticated using (private.is_staff());
drop policy if exists produto_fotos_envios_dono on public.produto_fotos_envios;
create policy produto_fotos_envios_dono on public.produto_fotos_envios for select to authenticated using (private.is_staff());

-- bucket privado; o CRM lê por link assinado e o WhatsApp recebe o arquivo por link assinado de curta duração
insert into storage.buckets (id, name, public) values ('produto-fotos', 'produto-fotos', false) on conflict (id) do nothing;
drop policy if exists produto_fotos_ler on storage.objects;
create policy produto_fotos_ler on storage.objects for select to authenticated using (bucket_id = 'produto-fotos' and private.is_staff());

-- ---------------------------------------------------------------- 3. resolver o grupo (SKU ou termo)
-- Devolve só o grupo. SKU exato primeiro; depois sinônimos (mais longo vence); depois palavras da descrição.
create or replace function public.foto_resolver_grupo(p_termo text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_norm text := private.norm_busca(p_termo);
  v_grupo text; v_exato boolean := false; v_sin text;
begin
  if not private.dono_ou_servidor() and not private.atendente_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if v_norm = '' then return jsonb_build_object('ok', false, 'motivo', 'termo_vazio'); end if;

  select c.grupo_produto into v_grupo from public.catalogo c where upper(c.sku) = upper(btrim(p_termo)) and c.grupo_produto is not null limit 1;
  if v_grupo is not null then v_exato := true; end if;

  if v_grupo is null then
    select s.grupo into v_sin from public.sinonimos s
     where v_norm = s.termo or v_norm like s.termo || ' %' or v_norm like '% ' || s.termo or v_norm like '% ' || s.termo || ' %'
     order by length(s.termo) desc limit 1;
    if v_sin is not null then
      select c.grupo_produto into v_grupo from public.catalogo c
       where c.grupo_produto is not null and (private.norm_busca(c.grupo_produto) = v_sin or private.norm_busca(c.grupo_produto) like v_sin || '%' or private.norm_busca(c.categoria) like '%' || v_sin || '%')
       group by c.grupo_produto order by count(*) desc limit 1;
    end if;
  end if;

  if v_grupo is null then
    select c.grupo_produto into v_grupo from public.catalogo c
     where c.grupo_produto is not null and private.norm_busca(coalesce(c.descricao, '')) like '%' || v_norm || '%'
     group by c.grupo_produto order by count(*) desc limit 1;
  end if;

  if v_grupo is null then return jsonb_build_object('ok', false, 'motivo', 'grupo_nao_encontrado'); end if;
  return jsonb_build_object('ok', true, 'grupo', v_grupo, 'exato_por_sku', v_exato);
end;
$$;
revoke execute on function public.foto_resolver_grupo(text) from public, anon;
grant execute on function public.foto_resolver_grupo(text) to authenticated, service_role;

-- ---------------------------------------------------------------- 4. cache e limites
-- Estado do cache de um grupo: fresco (dentro do prazo) e fotos aprovadas disponíveis
create or replace function public.foto_estado_grupo(p_grupo text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare g public.produto_fotos_grupos; v_aprovadas integer; v_cache integer := coalesce((select (value ->> 'cache_dias')::integer from public.app_settings where key = 'fotos'), 30);
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  select * into g from public.produto_fotos_grupos where grupo_produto = p_grupo;
  select count(*) into v_aprovadas from public.produto_fotos where grupo_produto = p_grupo and status = 'aprovada' and arquivo_storage is not null;
  insert into public.produto_fotos_grupos (grupo_produto, situacao, buscado_em, expira_em, pedidos)
    values (p_grupo, 'ok', now() - make_interval(days => v_cache + 1), now() - interval '1 day', 1)
    on conflict (grupo_produto) do update set pedidos = public.produto_fotos_grupos.pedidos + 1;
  return jsonb_build_object('existe', g.grupo_produto is not null, 'fresco', g.grupo_produto is not null and g.expira_em > now(),
    'situacao', g.situacao, 'aprovadas', v_aprovadas, 'cache_dias', v_cache);
end;
$$;
revoke execute on function public.foto_estado_grupo(text) from public, anon;
grant execute on function public.foto_estado_grupo(text) to authenticated, service_role;

-- Limites: 1 pedido de foto por minuto por conversa, 10 imagens por contato por dia, máximo 3 por pedido
create or replace function public.foto_limites(p_conversation uuid, p_contact uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_min integer; v_dia integer; cfg jsonb := coalesce((select value from public.app_settings where key = 'fotos'), '{}'::jsonb);
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  select count(*) into v_min from public.produto_fotos_envios
   where conversation_id = p_conversation and criado_em > now() - interval '1 minute' and resultado in ('enviada', 'sem_foto');
  select coalesce(sum(quantidade), 0) into v_dia from public.produto_fotos_envios
   where contact_id = p_contact and criado_em > date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo' and resultado = 'enviada';
  return jsonb_build_object('pedidos_ultimo_minuto', v_min, 'imagens_hoje', v_dia,
    'max_por_pedido', coalesce((cfg ->> 'max_por_pedido')::integer, 3), 'por_minuto', coalesce((cfg ->> 'pedidos_por_minuto')::integer, 1),
    'por_dia', coalesce((cfg ->> 'imagens_por_contato_dia')::integer, 10));
end;
$$;
revoke execute on function public.foto_limites(uuid, uuid) from public, anon;
grant execute on function public.foto_limites(uuid, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- 5. gravação pela Edge Function
create or replace function public.foto_registrar(p_grupo text, p_url_origem text, p_arquivo text, p_largura integer, p_altura integer, p_bytes integer, p_hash text, p_aproximada boolean, p_ordem integer default 0)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_status text;
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  insert into public.produto_fotos (grupo_produto, url_origem, arquivo_storage, largura, altura, bytes, hash, status, aproximada, ordem)
    values (p_grupo, p_url_origem, p_arquivo, p_largura, p_altura, p_bytes, p_hash, 'pendente', coalesce(p_aproximada, true), coalesce(p_ordem, 0))
    on conflict (grupo_produto, hash) where hash is not null do update set atualizado_em = now()
    returning id, status into v_id, v_status;
  return v_id;
end;
$$;
revoke execute on function public.foto_registrar(text, text, text, integer, integer, integer, text, boolean, integer) from public, anon;
grant execute on function public.foto_registrar(text, text, text, integer, integer, integer, text, boolean, integer) to authenticated, service_role;

-- Resultado da verificação whitelabel (modelo de visão) ou decisão do dono. Marca marcada = bloqueada + revisar.
create or replace function public.foto_decidir(p_id uuid, p_status text, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare f public.produto_fotos;
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  if p_status not in ('aprovada', 'bloqueada', 'sem_foto', 'pendente') then raise exception 'Situação inválida.'; end if;
  update public.produto_fotos set status = p_status, revisar = (p_status = 'bloqueada'), motivo = p_motivo, atualizado_em = now()
   where id = p_id returning * into f;
  if f.id is null then return jsonb_build_object('ok', false, 'motivo', 'nao_encontrada'); end if;
  return jsonb_build_object('ok', true, 'id', f.id, 'status', f.status);
end;
$$;
revoke execute on function public.foto_decidir(uuid, text, text) from public, anon;
grant execute on function public.foto_decidir(uuid, text, text) to authenticated, service_role;

create or replace function public.foto_fechar_busca(p_grupo text, p_situacao text, p_detalhe text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_cache integer := coalesce((select (value ->> 'cache_dias')::integer from public.app_settings where key = 'fotos'), 30);
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  -- erro de rede não fixa 30 dias de "sem foto": tenta de novo em 1 hora
  insert into public.produto_fotos_grupos (grupo_produto, situacao, buscado_em, expira_em, detalhe)
    values (p_grupo, p_situacao, now(), now() + case when p_situacao = 'erro' then interval '1 hour' else make_interval(days => v_cache) end, left(p_detalhe, 300))
    on conflict (grupo_produto) do update set situacao = excluded.situacao, buscado_em = excluded.buscado_em, expira_em = excluded.expira_em, detalhe = excluded.detalhe;
end;
$$;
revoke execute on function public.foto_fechar_busca(text, text, text) from public, anon;
grant execute on function public.foto_fechar_busca(text, text, text) to authenticated, service_role;

create or replace function public.foto_registrar_envio(p_conversation uuid, p_contact uuid, p_grupo text, p_quantidade integer, p_bytes integer, p_via text, p_resultado text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  insert into public.produto_fotos_envios (conversation_id, contact_id, grupo_produto, quantidade, bytes, via, resultado)
    values (p_conversation, p_contact, p_grupo, coalesce(p_quantidade, 0), coalesce(p_bytes, 0), p_via, p_resultado);
  -- log do agente sem origem e sem conteúdo de mensagem
  insert into public.agent_logs (conversation_id, actor, action, detail, result, workflow, ferramenta)
    values (p_conversation, 'ia', 'enviar_foto_produto',
            jsonb_build_object('grupo', p_grupo, 'quantidade', p_quantidade, 'bytes', p_bytes, 'via', p_via),
            p_resultado, 'FERRAMENTA', 'enviar_foto_produto');
end;
$$;
revoke execute on function public.foto_registrar_envio(uuid, uuid, text, integer, integer, text, text) from public, anon;
grant execute on function public.foto_registrar_envio(uuid, uuid, text, integer, integer, text, text) to authenticated, service_role;

-- Fotos aprovadas de um grupo, SEM url_origem (é o que a Edge Function usa para enviar)
create or replace function public.foto_aprovadas(p_grupo text, p_quantidade integer)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'arquivo', arquivo_storage, 'bytes', bytes, 'aproximada', aproximada) order by aproximada, ordem, criado_em)
    from (select * from public.produto_fotos where grupo_produto = p_grupo and status = 'aprovada' and arquivo_storage is not null
          order by aproximada, ordem, criado_em limit greatest(1, least(coalesce(p_quantidade, 1), 3))) x), '[]'::jsonb);
end;
$$;
revoke execute on function public.foto_aprovadas(text, integer) from public, anon;
grant execute on function public.foto_aprovadas(text, integer) to authenticated, service_role;

-- Painel do dono (Catálogo > Fotos): grupos com situação, contagens e pedidos; inclui grupos do catálogo ainda sem registro
create or replace function public.fotos_painel()
returns table (grupo_produto text, itens bigint, situacao text, aprovadas bigint, pendentes bigint, bloqueadas bigint, revisar bigint, pedidos integer, buscado_em timestamptz, expira_em timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_staff() then raise exception 'Só o dono.' using errcode = '42501'; end if;
  return query
  select g.grupo, g.itens, coalesce(pg.situacao, 'nao_buscado'),
         count(f.*) filter (where f.status = 'aprovada'), count(f.*) filter (where f.status = 'pendente'), count(f.*) filter (where f.status = 'bloqueada'),
         count(f.*) filter (where f.revisar), coalesce(pg.pedidos, 0), pg.buscado_em, pg.expira_em
    from (select c.grupo_produto as grupo, count(*) as itens from public.catalogo c where c.grupo_produto is not null group by c.grupo_produto) g
    left join public.produto_fotos_grupos pg on pg.grupo_produto = g.grupo
    left join public.produto_fotos f on f.grupo_produto = g.grupo
   group by g.grupo, g.itens, pg.situacao, pg.pedidos, pg.buscado_em, pg.expira_em
   order by coalesce(pg.pedidos, 0) desc, g.itens desc;
end;
$$;
revoke execute on function public.fotos_painel() from public, anon;
grant execute on function public.fotos_painel() to authenticated;

-- Grupos mais pedidos, para aquecer o cache de madrugada (opcional, desligado por padrão)
create or replace function public.fotos_grupos_para_aquecer(p_limite integer default 5)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  if not coalesce((select (value ->> 'aquecer_ligado')::boolean from public.app_settings where key = 'fotos'), false) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(grupo_produto) from (
    select pg.grupo_produto from public.produto_fotos_grupos pg where pg.expira_em <= now() and pg.pedidos > 0
    union all select g.grupo from (select c.grupo_produto as grupo, count(*) n from public.catalogo c where c.grupo_produto is not null group by 1 order by n desc limit 30) g
      where not exists (select 1 from public.produto_fotos_grupos x where x.grupo_produto = g.grupo)
    limit greatest(1, least(coalesce(p_limite, 5), 10))) t), '[]'::jsonb);
end;
$$;
revoke execute on function public.fotos_grupos_para_aquecer(integer) from public, anon;
grant execute on function public.fotos_grupos_para_aquecer(integer) to authenticated, service_role;

-- Agente de IA, Etapa 4B: trecho de conhecimento sobre pedido de foto. Idempotente: não sobrescreve se o dono já editou.
-- (O mesmo trecho está em supabase/seed/conhecimento.json, que o lint do npm test confere.)
insert into public.conhecimento (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags, fonte, revisar, ativo)
select * from (values (
  'foto-produto', 'Cliente pede foto do produto', 'guia',
  'Cliente pede foto, imagem, exemplo ou como fica o produto.',
  'Claro! Vou te mandar umas fotos pra você ver como fica. Depois me conta a quantidade e se já tem a arte que eu monto seu orçamento.',
  'Use a ferramenta de foto, no máximo 3 imagens por pedido. A foto pode ser ilustrativa do acabamento e o produto final pode variar. Se não houver foto, diga que vai confirmar com a equipe. Nunca diga de onde veio a imagem.',
  'Depois das fotos, perguntar quantidade e arte e oferecer o orçamento em PDF.',
  array['foto','tem foto','manda foto','me mostra','quero ver como fica','foto do produto','tem exemplo','como fica','imagem do produto','tem imagem'],
  'carga da Etapa 4B', true, true)) as v (slug, titulo, categoria, quando_usar, resposta_pronta, fatos, proximo_passo, tags, fonte, revisar, ativo)
where not exists (select 1 from public.conhecimento k where k.slug = v.slug);
