-- Etapa 8C: executor dos testes e2e dentro do banco (pg_cron + pg_net), sem precisar de chave de serviço fora.
-- Cada conversa vira uma linha de e2e_execucao. A função e2e_avancar cria o caso de cada turno, dispara o
-- webhook de TESTE (guardado em e2e_config, nunca no repositório), espera o retrato e segue para o turno seguinte.
-- Nada vai ao WhatsApp: o webhook é o do clone de teste do WF2, que só aceita teste=true.
create table if not exists public.e2e_config (
  chave text primary key,
  valor text not null
);
create table if not exists public.e2e_execucao (
  id uuid primary key default gen_random_uuid(),
  rodada text not null,
  cenario text not null,
  formulacao integer not null,
  persona text,
  turnos jsonb not null,
  turno_atual integer not null default 0,
  caso_id uuid,
  conversation_id uuid,
  estado text not null default 'pendente' check (estado in ('pendente', 'aguardando', 'concluida', 'erro')),
  disparado_em timestamptz,
  retratos jsonb not null default '[]'::jsonb,
  erro text,
  criado_em timestamptz not null default now(),
  unique (rodada, cenario, formulacao)
);
alter table public.e2e_config enable row level security;
alter table public.e2e_execucao enable row level security;
revoke all on table public.e2e_config, public.e2e_execucao from anon, authenticated;

create or replace function public.e2e_enfileirar(p_rodada text, p_tarefas jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  insert into public.e2e_execucao (rodada, cenario, formulacao, persona, turnos)
  select p_rodada, t ->> 'cenario', (t ->> 'formulacao')::integer, t ->> 'persona', t -> 'turnos'
    from jsonb_array_elements(p_tarefas) t
  on conflict (rodada, cenario, formulacao) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.e2e_iniciar_turno(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare x public.e2e_execucao%rowtype; v_n integer; v_ent jsonb; v_caso uuid; v_url text;
begin
  select * into x from public.e2e_execucao where id = p_id;
  v_n := x.turno_atual + 1;
  v_ent := x.turnos -> (v_n - 1);
  if v_n > 1 then v_ent := replace(v_ent::text, '__CONVERSA__', coalesce(x.conversation_id::text, ''))::jsonb; end if;
  v_caso := public.e2e_criar_caso('e2e-' || x.rodada || '-' || x.cenario || '-f' || x.formulacao || '-t' || v_n, v_ent);
  update public.e2e_execucao set turno_atual = v_n, caso_id = v_caso, estado = 'aguardando', disparado_em = now() where id = p_id;
  select valor into v_url from public.e2e_config where chave = 'url_teste';
  if v_url is null then raise exception 'e2e_config.url_teste ausente'; end if;
  perform net.http_post(url := v_url, body := jsonb_build_object('caso_id', v_caso, 'limpar', false),
                        headers := '{"content-type":"application/json"}'::jsonb, timeout_milliseconds := 10000);
end $$;

create or replace function public.e2e_avancar(p_rodada text, p_paralelo integer default 5, p_timeout_seg integer default 240, p_janela_seg integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  x public.e2e_execucao%rowtype; v_snap jsonb; v_fim timestamptz := clock_timestamp() + make_interval(secs => p_janela_seg);
  v_ag integer; v_pend integer; v_custo numeric; v_teto numeric := coalesce((select valor::numeric from public.e2e_config where chave = 'teto_custo'), 15);
  v_ret jsonb; v_cli jsonb;
begin
  if not pg_try_advisory_lock(hashtext('e2e_avancar')) then return jsonb_build_object('ocupado', true); end if;
  begin
    loop
      for x in select * from public.e2e_execucao where rodada = p_rodada and estado = 'aguardando' order by criado_em loop
        v_snap := public.e2e_snapshot(x.caso_id);
        if v_snap ->> 'status' is not null or now() - x.disparado_em > make_interval(secs => p_timeout_seg) then
          select coalesce(jsonb_agg(m ->> 'texto'), '[]'::jsonb) into v_cli from jsonb_array_elements(x.turnos -> (x.turno_atual - 1) -> 'mensagens') m;
          v_ret := x.retratos || jsonb_build_array(jsonb_build_object('n', x.turno_atual, 'cliente', v_cli, 'snapshot', v_snap - 'ok'));
          if v_snap ->> 'status' is null then
            update public.e2e_execucao set retratos = v_ret, estado = 'erro', erro = 'tempo esgotado no turno ' || x.turno_atual where id = x.id;
          elsif x.turno_atual >= jsonb_array_length(x.turnos) then
            update public.e2e_execucao set retratos = v_ret, estado = 'concluida', conversation_id = (v_snap ->> 'conversation_id')::uuid where id = x.id;
          else
            update public.e2e_execucao set retratos = v_ret, conversation_id = (v_snap ->> 'conversation_id')::uuid, estado = 'pendente' where id = x.id;
            perform public.e2e_iniciar_turno(x.id);
          end if;
        end if;
      end loop;
      select coalesce(sum((r -> 'snapshot' ->> 'custo')::numeric), 0) into v_custo from public.e2e_execucao e, lateral jsonb_array_elements(e.retratos) r where e.rodada = p_rodada;
      select count(*) into v_ag from public.e2e_execucao where rodada = p_rodada and estado = 'aguardando';
      while v_ag < p_paralelo and v_custo < v_teto loop
        select * into x from public.e2e_execucao where rodada = p_rodada and estado = 'pendente' and turno_atual = 0 order by criado_em limit 1 for update skip locked;
        exit when not found;
        perform public.e2e_iniciar_turno(x.id);
        v_ag := v_ag + 1;
      end loop;
      select count(*) into v_pend from public.e2e_execucao where rodada = p_rodada and estado in ('pendente', 'aguardando');
      exit when v_pend = 0 or clock_timestamp() > v_fim or v_custo >= v_teto;
      perform pg_sleep(3);
    end loop;
  exception when others then
    perform pg_advisory_unlock(hashtext('e2e_avancar'));
    raise;
  end;
  perform pg_advisory_unlock(hashtext('e2e_avancar'));
  return public.e2e_andamento(p_rodada) || jsonb_build_object('custo', v_custo, 'teto_custo', v_teto);
end $$;

create or replace function public.e2e_andamento(p_rodada text)
returns jsonb language sql security definer set search_path = '' as $$
  select jsonb_build_object('rodada', p_rodada, 'pendente', count(*) filter (where estado = 'pendente'), 'aguardando', count(*) filter (where estado = 'aguardando'),
                            'concluida', count(*) filter (where estado = 'concluida'), 'erro', count(*) filter (where estado = 'erro'))
    from public.e2e_execucao where rodada = p_rodada
$$;

-- Corpo da rodada para a máquina de avaliação. Só responde com o token guardado em e2e_config (dados de teste, sem segredos).
create or replace function public.e2e_exportar(p_token text, p_rodada text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if p_token is null or p_token is distinct from (select valor from public.e2e_config where chave = 'token_export') then return null; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('cenario', cenario, 'formulacao', formulacao, 'persona', persona, 'estado', estado, 'erro', erro, 'turnos', retratos) order by cenario, formulacao)
                     from public.e2e_execucao where rodada = p_rodada), '[]'::jsonb);
end $$;

revoke all on function public.e2e_enfileirar(text, jsonb), public.e2e_iniciar_turno(uuid), public.e2e_avancar(text, integer, integer, integer), public.e2e_andamento(text) from public, anon, authenticated;
grant execute on function public.e2e_enfileirar(text, jsonb), public.e2e_iniciar_turno(uuid), public.e2e_avancar(text, integer, integer, integer), public.e2e_andamento(text) to service_role;
revoke all on function public.e2e_exportar(text, text) from public;
grant execute on function public.e2e_exportar(text, text) to anon, authenticated, service_role;
