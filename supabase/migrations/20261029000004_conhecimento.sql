-- Agente de IA, Etapa 2 (4/4): banco de conhecimento enxuto (RAG de vendedor), lacunas, cache de perguntas frequentes e variáveis comerciais.
-- Estende a tabela conhecimento da Etapa 1 (vazia). Embedding gte-small (384 dimensões), gerado pela Edge Function "conhecimento".
-- Nenhum trecho leva preço de produto, custo, prazo de item nem o nome do fornecedor (o teste npm run test:conhecimento confere).

-- ---------------------------------------------------------------- 1. formato do trecho
alter table public.conhecimento add column if not exists slug text;
alter table public.conhecimento add column if not exists quando_usar text;
alter table public.conhecimento add column if not exists resposta_pronta text;
alter table public.conhecimento add column if not exists fatos text;
alter table public.conhecimento add column if not exists proximo_passo text;
alter table public.conhecimento add column if not exists embedding_texto text;
alter table public.conhecimento add column if not exists embedding_em timestamptz;
alter table public.conhecimento add column if not exists revisado_em timestamptz;
alter table public.conhecimento alter column conteudo drop not null;
alter table public.conhecimento alter column conteudo set default '';
create unique index if not exists conhecimento_slug_uq on public.conhecimento (slug) where slug is not null;

-- gte-small gera 384 dimensões (a tabela estava vazia com 768, reservado para outro modelo)
drop index if exists public.conhecimento_embedding_idx;
alter table public.conhecimento alter column embedding type extensions.vector(384) using null;
create index if not exists conhecimento_embedding_idx on public.conhecimento using hnsw (embedding extensions.vector_cosine_ops);

-- Texto que vira vetor: titulo + quando_usar + resposta_pronta. Mudou, o vetor antigo sai e a reindexação automática refaz.
create or replace function private.conhecimento_antes() returns trigger
language plpgsql set search_path = ''
as $$
declare v_texto text;
begin
  v_texto := concat_ws('. ', new.titulo, new.quando_usar, new.resposta_pronta);
  if tg_op = 'INSERT' then
    new.embedding_texto := null;
  elsif new.embedding_texto is distinct from v_texto and (new.titulo is distinct from old.titulo or new.quando_usar is distinct from old.quando_usar or new.resposta_pronta is distinct from old.resposta_pronta) then
    new.embedding := null;
    new.embedding_em := null;
  end if;
  -- editou o conteúdo sem mexer na marca de revisão: volta a pedir revisão (quem marca "revisado" na mesma edição mantém)
  if tg_op = 'UPDATE' and not old.revisar and new.revisar is not distinct from old.revisar
     and (new.titulo is distinct from old.titulo or new.quando_usar is distinct from old.quando_usar or new.resposta_pronta is distinct from old.resposta_pronta
          or new.fatos is distinct from old.fatos or new.proximo_passo is distinct from old.proximo_passo) then
    new.revisar := true;
  end if;
  if new.revisar = false and (tg_op = 'INSERT' or old.revisar) then new.revisado_em := now(); end if;
  new.atualizado_em := now();
  return new;
end;
$$;
revoke execute on function private.conhecimento_antes() from public, anon, authenticated;
drop trigger if exists conhecimento_toca on public.conhecimento;
drop trigger if exists conhecimento_antes on public.conhecimento;
create trigger conhecimento_antes before insert or update on public.conhecimento for each row execute function private.conhecimento_antes();

-- ---------------------------------------------------------------- 2. variáveis resolvidas em tempo de execução
create or replace function private.horario_texto() returns text
language plpgsql stable set search_path = ''
as $$
declare
  h jsonb; chaves text[] := array['seg', 'ter', 'qua', 'qui', 'sex']; nomes text[] := array['segunda', 'terça', 'quarta', 'quinta', 'sexta'];
  i integer; v_ini integer := 1; v_atual text; v_prox text; v_out text[] := '{}'; v_fim integer;
begin
  select horario_atendimento into h from public.parametros_comerciais where id = 1;
  for i in 1..5 loop
    v_atual := coalesce(h -> chaves[i] ->> 'abre', '') || '|' || coalesce(h -> chaves[i] ->> 'fecha', '');
    v_prox := case when i < 5 then coalesce(h -> chaves[i + 1] ->> 'abre', '') || '|' || coalesce(h -> chaves[i + 1] ->> 'fecha', '') end;
    if v_prox is distinct from v_atual then
      v_fim := i;
      if v_atual <> '|' then
        v_out := array_append(v_out, (case when v_ini = v_fim then nomes[v_ini] else nomes[v_ini] || ' a ' || nomes[v_fim] end)
          || ' das ' || regexp_replace(regexp_replace(split_part(v_atual, '|', 1), '^0', ''), ':00$', 'h') || ' às '
          || regexp_replace(regexp_replace(split_part(v_atual, '|', 2), '^0', ''), ':00$', 'h'));
      end if;
      v_ini := i + 1;
    end if;
  end loop;
  return replace(replace(array_to_string(v_out, ', '), 'h:', 'h'), ':', 'h') || ', sábado e domingo fechado';
end;
$$;

-- {{arte_basica}} {{arte_frete}} {{pedido_minimo}} {{validade}} {{horario}}
create or replace function public.conhecimento_resolver(p_texto text) returns text
language plpgsql stable security definer set search_path = ''
as $$
declare pr public.parametros_comerciais%rowtype; t text := p_texto;
begin
  if t is null then return null; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  t := replace(t, '{{arte_basica}}', private.brl(pr.arte_valor));
  t := replace(t, '{{arte_frete}}', private.brl(pr.arte_frete_valor));
  t := replace(t, '{{pedido_minimo}}', private.brl(pr.pedido_minimo_frete_gratis));
  t := replace(t, '{{validade}}', pr.validade_orcamento_dias || case when pr.validade_orcamento_dias = 1 then ' dia' else ' dias' end);
  t := replace(t, '{{horario}}', private.horario_texto());
  return t;
end;
$$;
revoke execute on function public.conhecimento_resolver(text) from public, anon;
grant execute on function public.conhecimento_resolver(text) to authenticated, service_role;

-- ---------------------------------------------------------------- 3. lacunas, consultas (taxa de acerto) e FAQ
create table if not exists public.conhecimento_lacunas (
  id uuid primary key default gen_random_uuid(),
  pergunta text not null,
  pergunta_norm text not null unique,
  ocorrencias integer not null default 1,
  melhor_score numeric(5, 3),
  conversation_id uuid references public.conversations (id) on delete set null,
  status text not null default 'aberta' check (status in ('aberta', 'resolvida', 'ignorada')),
  trecho_id uuid references public.conhecimento (id) on delete set null,
  primeira_em timestamptz not null default now(),
  ultima_em timestamptz not null default now()
);
create index if not exists conhecimento_lacunas_status_idx on public.conhecimento_lacunas (status, ultima_em desc);

create table if not exists public.conhecimento_consultas (
  id bigint generated always as identity primary key,
  pergunta_norm text not null,
  encontrou boolean not null,
  melhor_score numeric(5, 3),
  trecho_id uuid references public.conhecimento (id) on delete set null,
  via text not null default 'busca' check (via in ('busca', 'faq')),
  criado_em timestamptz not null default now()
);
create index if not exists conhecimento_consultas_dia_idx on public.conhecimento_consultas (criado_em desc);

create table if not exists public.faq_cache (
  pergunta_norm text primary key,
  pergunta text not null,
  resposta text not null,
  trecho_id uuid references public.conhecimento (id) on delete set null,
  ativo boolean not null default true,
  usos integer not null default 0,
  atualizado_em timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['conhecimento_lacunas', 'conhecimento_consultas', 'faq_cache'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('drop policy if exists %I on public.%I', t || '_dono', t);
    execute format('create policy %I on public.%I for all to authenticated using (private.is_staff()) with check (private.is_staff())', t || '_dono', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- 4. busca de conhecimento (híbrida: vetor + texto)
-- Limiares calibráveis. Semântico: cosseno do gte-small. Lexical: trigram + palavras em comum com título, quando_usar e tags.
alter table public.parametros_comerciais add column if not exists conhecimento_limiar_semantico numeric(4, 3) not null default 0.800;
alter table public.parametros_comerciais add column if not exists conhecimento_limiar_lexico numeric(4, 3) not null default 0.350;
alter table public.parametros_comerciais add column if not exists conhecimento_max_palavras smallint not null default 120;

-- Pontuação de texto de uma pergunta contra um trecho (0 a 1)
create or replace function private.conhecimento_score_texto(p_pergunta_norm text, p_titulo text, p_quando text, p_tags text[]) returns numeric
language plpgsql immutable set search_path = ''
as $$
declare
  v_stop constant text[] := array['de','da','do','das','dos','para','pra','com','e','um','uma','por','favor','me','o','a','os','as','em','no','na','que','eh','ai','oi','ola','vcs','voce','voces','tem','ter','posso','pode','quero','queria','como','qual','quais','isso','esse','essa','la','ne','so','se','eu','meu','minha'];
  v_pal text[]; v_alvo text; v_tags text; v_hit numeric := 0; v_tot numeric := 0; w text; v_tag_max numeric := 0; t text;
begin
  v_alvo := private.norm_busca(concat_ws(' ', p_titulo, p_quando));
  v_pal := array(select x from regexp_split_to_table(p_pergunta_norm, ' ') x where x <> '' and not (x = any (v_stop)));
  foreach w in array v_pal loop
    v_tot := v_tot + 1;
    if (' ' || v_alvo || ' ') like ('% ' || w || ' %') or length(w) > 3 and v_alvo like ('%' || w || '%') then v_hit := v_hit + 1; end if;
  end loop;
  -- tags são frases curtas que o cliente realmente escreve: contêm a frase inteira ou estão contidas nela
  foreach t in array coalesce(p_tags, '{}') loop
    t := private.norm_busca(t);
    if t = '' then continue; end if;
    if p_pergunta_norm = t then v_tag_max := greatest(v_tag_max, 1);
    elsif (' ' || p_pergunta_norm || ' ') like ('% ' || t || ' %') then v_tag_max := greatest(v_tag_max, 0.9);
    else v_tag_max := greatest(v_tag_max, (extensions.similarity(p_pergunta_norm, t) * 0.9)::numeric); end if;
  end loop;
  return greatest(
    v_tag_max,
    case when v_tot > 0 then v_hit / v_tot * 0.8 else 0 end,
    extensions.similarity(p_pergunta_norm, v_alvo)::numeric);
end;
$$;

-- Devolve até 3 trechos acima do limiar. Abaixo dele: encontrou = false, a pergunta vai para conhecimento_lacunas e o agente chama o dono (gravidade baixa).
-- p_embedding vem da Edge Function (gte-small da pergunta); sem ele a busca é só textual.
create or replace function public.buscar_conhecimento(p_pergunta text, p_embedding extensions.vector(384) default null, p_limite integer default 3, p_conversation uuid default null, p_registrar boolean default true)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_norm text := private.norm_busca(p_pergunta);
  v_faq record; v_res jsonb; v_melhor numeric; v_melhor_id uuid;
begin
  if not private.atendente_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  if length(v_norm) < 2 then return jsonb_build_object('ok', false, 'erro', 'pergunta_vazia'); end if;

  -- 1. pergunta exata comum: responde sem modelo
  select * into v_faq from public.faq_cache f where f.pergunta_norm = v_norm and f.ativo;
  if found then
    update public.faq_cache set usos = usos + 1 where pergunta_norm = v_norm;
    if p_registrar then insert into public.conhecimento_consultas (pergunta_norm, encontrou, melhor_score, trecho_id, via) values (v_norm, true, 1, v_faq.trecho_id, 'faq'); end if;
    return jsonb_build_object('ok', true, 'encontrou', true, 'via', 'faq', 'resposta_direta', public.conhecimento_resolver(v_faq.resposta),
      'trechos', coalesce((select jsonb_build_array(jsonb_build_object('id', k.id, 'titulo', k.titulo, 'proximo_passo', k.proximo_passo, 'score', 1)) from public.conhecimento k where k.id = v_faq.trecho_id), '[]'::jsonb));
  end if;

  with cand as (
    select k.id, k.slug, k.titulo, k.resposta_pronta, k.fatos, k.proximo_passo,
           case when p_embedding is not null and k.embedding is not null then (1 - (k.embedding operator(extensions.<=>) p_embedding))::numeric end as sem,
           private.conhecimento_score_texto(v_norm, k.titulo, k.quando_usar, k.tags) as lex
      from public.conhecimento k where k.ativo and k.resposta_pronta is not null
  ), pont as (
    select *,
           (coalesce(sem, 0) >= pr.conhecimento_limiar_semantico or lex >= pr.conhecimento_limiar_lexico) as passa
      from cand
  ), top as (
    select * from pont where passa order by greatest(coalesce(sem, 0), lex) desc, lex desc limit least(greatest(p_limite, 1), 3)
  )
  select jsonb_agg(jsonb_build_object('id', id, 'slug', slug, 'titulo', titulo, 'resposta_pronta', public.conhecimento_resolver(resposta_pronta),
           'fatos', public.conhecimento_resolver(fatos), 'proximo_passo', public.conhecimento_resolver(proximo_passo),
           'score', round(greatest(coalesce(sem, 0), lex), 3)) order by greatest(coalesce(sem, 0), lex) desc),
         max(greatest(coalesce(sem, 0), lex)), (array_agg(id order by greatest(coalesce(sem, 0), lex) desc))[1]
    into v_res, v_melhor, v_melhor_id from top;

  if v_res is null then
    if p_registrar then
      insert into public.conhecimento_lacunas (pergunta, pergunta_norm, conversation_id) values (left(p_pergunta, 500), v_norm, p_conversation)
      on conflict (pergunta_norm) do update set ocorrencias = public.conhecimento_lacunas.ocorrencias + 1, ultima_em = now(),
        status = case when public.conhecimento_lacunas.status = 'resolvida' then 'aberta' else public.conhecimento_lacunas.status end;
      insert into public.conhecimento_consultas (pergunta_norm, encontrou) values (v_norm, false);
    end if;
    return jsonb_build_object('ok', true, 'encontrou', false, 'trechos', '[]'::jsonb,
      'orientacao', 'dizer_que_vai_confirmar_e_chamar_dono_gravidade_baixa');
  end if;
  if p_registrar then insert into public.conhecimento_consultas (pergunta_norm, encontrou, melhor_score, trecho_id) values (v_norm, true, v_melhor, v_melhor_id); end if;
  return jsonb_build_object('ok', true, 'encontrou', true, 'trechos', v_res);
end;
$$;
revoke execute on function public.buscar_conhecimento(text, extensions.vector, integer, uuid, boolean) from public, anon;
grant execute on function public.buscar_conhecimento(text, extensions.vector, integer, uuid, boolean) to authenticated, service_role;

-- Taxa de acerto dos últimos N dias (para a tela)
create or replace function public.conhecimento_taxa(p_dias integer default 30) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select jsonb_build_object('consultas', count(*), 'acertos', count(*) filter (where encontrou), 'via_faq', count(*) filter (where via = 'faq'),
    'taxa_pct', case when count(*) > 0 then round(count(*) filter (where encontrou)::numeric / count(*) * 100, 1) end)
  from public.conhecimento_consultas where criado_em >= now() - make_interval(days => p_dias);
$$;

-- Reindexação automática: a cada 5 minutos a função "conhecimento" refaz o vetor dos trechos editados (embedding vazio)
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
do $$
begin
  if exists (select 1 from cron.job where jobname = 'conhecimento-reindexar') then
    perform cron.unschedule('conhecimento-reindexar');
  end if;
  perform cron.schedule(
    'conhecimento-reindexar',
    '*/5 * * * *',
    $job$
      select net.http_post(
        url := 'https://bhlosshvwmlyzhbghsrc.supabase.co/functions/v1/conhecimento',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret' limit 1)
        ),
        body := '{"acao":"indexar"}'::jsonb
      );
    $job$
  );
end $$;
