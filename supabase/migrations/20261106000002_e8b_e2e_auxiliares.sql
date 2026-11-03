-- Etapa 8B: auxiliares do teste ponta a ponta (aditiva e idempotente). Só a service role (e o dono pelo MCP) executa.
-- e2e_criar_caso: cria o caso de teste de um turno. e2e_aguardar: espera o turno terminar (dentro do banco) e devolve o retrato da conversa.
-- e2e_snapshot: o que o juiz e as verificações determinísticas precisam saber da conversa de teste.

create or replace function public.e2e_criar_caso(p_nome text, p_entradas jsonb) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if p_nome !~ '^e2e-' then raise exception 'nome de caso e2e precisa começar com e2e-'; end if;
  insert into public.testes_conversa (nome, descricao, entradas, esperado)
  values (p_nome, 'E2E 8B', p_entradas, '{"sem_vazamento": true}'::jsonb) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.e2e_snapshot(p_caso uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  c record;
  v_conv uuid;
  v_contact uuid;
  v_ferr text[];
  v_valores jsonb;
  v_links text[];
  v_links_orc text[];
  v_tok bigint; v_custo numeric;
  v_lucro boolean;
begin
  select * into c from public.testes_conversa where id = p_caso;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'caso_inexistente'); end if;
  v_conv := (c.ultimo_resultado ->> 'conversation_id')::uuid;
  v_contact := (c.ultimo_resultado ->> 'contact_id')::uuid;
  select coalesce(array_agg(distinct ferramenta), '{}') into v_ferr from public.agent_logs where conversation_id = v_conv and action = 'ferramenta' and ferramenta is not null;
  select coalesce(jsonb_agg(distinct v), '[]'::jsonb) into v_valores from public.agente_execucoes e, lateral unnest(coalesce(e.valores_vistos, '{}')) v where e.conversation_id = v_conv;
  select coalesce(array_agg(distinct m[1]), '{}') into v_links from public.agent_logs l, lateral regexp_matches(coalesce(l.result::text, ''), '(https?://[^\s"\\)]+)', 'g') m where l.conversation_id = v_conv;
  select coalesce(array_agg(link_pagamento) filter (where link_pagamento is not null), '{}') into v_links_orc from public.orcamentos where contact_id = v_contact;
  select coalesce(sum(coalesce(tokens_entrada, 0) + coalesce(tokens_saida, 0)), 0), coalesce(sum(custo_estimado), 0) into v_tok, v_custo from public.agente_execucoes where conversation_id = v_conv;
  select exists (
    select 1 from public.orcamentos o join public.orcamento_itens i on i.orcamento_id = o.id
     where o.contact_id = v_contact
       and ((i.piso_duro is not null and i.valor_total is not null and i.valor_total + 0.005 < i.piso_duro) or (i.lucro_liquido is not null and i.lucro_liquido < -0.005))
  ) into v_lucro;
  return jsonb_build_object('ok', true, 'status', c.ultimo_status, 'saidas', coalesce(c.ultimo_resultado -> 'saidas', '[]'::jsonb),
    'conversation_id', v_conv, 'contact_id', v_contact, 'ferramentas', to_jsonb(v_ferr), 'valores_vistos', v_valores,
    'links_vistos', to_jsonb(v_links), 'links_orcamento', to_jsonb(v_links_orc), 'tokens', v_tok, 'custo', v_custo,
    'alerta', exists (select 1 from public.alertas where conversation_id = v_conv), 'violacao_lucro', v_lucro);
end;
$$;

-- Espera (no banco) o turno terminar: o WF1 grava ultimo_status ao final. Volta o retrato mesmo se estourar o tempo (status nulo).
create or replace function public.e2e_aguardar(p_caso uuid, p_max_seg int default 110) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_fim timestamptz := clock_timestamp() + make_interval(secs => p_max_seg); v_status text;
begin
  loop
    select ultimo_status into v_status from public.testes_conversa where id = p_caso;
    exit when v_status is not null or clock_timestamp() > v_fim;
    perform pg_sleep(2);
  end loop;
  return public.e2e_snapshot(p_caso);
end;
$$;

create or replace function public.e2e_apagar_casos(p_rodada text) returns int
language plpgsql security definer set search_path = ''
as $$
declare n int;
begin
  delete from public.testes_conversa where nome like 'e2e-' || p_rodada || '-%';
  get diagnostics n = row_count;
  return n;
end;
$$;

do $$ declare f text; begin
  foreach f in array array['e2e_criar_caso(text, jsonb)', 'e2e_snapshot(uuid)', 'e2e_aguardar(uuid, integer)', 'e2e_apagar_casos(text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
