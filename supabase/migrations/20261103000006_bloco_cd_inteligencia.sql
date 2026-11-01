-- Etapa 7B, Blocos C e D: preço por dimensão (estrutura), inteligência comercial e dados. Aditiva e idempotente.

-- ---------------------------------------------------------------- C. fórmulas de custo por dimensão (SEM custo exposto ao agente)
create table if not exists public.catalogo_formulas (
  id uuid primary key default gen_random_uuid(),
  sku text not null references public.catalogo (sku) on delete cascade,
  tipo text not null default 'm2' check (tipo in ('m2', 'faixas')),
  custo_m2 numeric(12, 4),
  custo_minimo numeric(12, 2),
  largura_min_mm integer, largura_max_mm integer, altura_min_mm integer, altura_max_mm integer,
  faixas jsonb,
  origem text not null check (origem in ('fornecedor_api', 'tabela_do_fornecedor', 'amostras_validadas', 'consulta_automatizada')),
  erro_max_amostras_pct numeric(6, 3),
  validada_em timestamptz,
  ativo boolean not null default false,
  criado_em timestamptz not null default now(),
  unique (sku)
);
alter table public.catalogo_formulas enable row level security;
drop policy if exists catalogo_formulas_dono on public.catalogo_formulas;
create policy catalogo_formulas_dono on public.catalogo_formulas for select to authenticated using (private.is_staff());
revoke all on public.catalogo_formulas from anon;

-- Só uma fórmula validada (erro das amostras <= 1%) e ativa vale. O custo devolvido passa SEMPRE por calcular_preco; nunca vai ao agente.
create or replace function private.custo_por_dimensao(p_sku text, p_largura_mm integer, p_altura_mm integer) returns numeric
language plpgsql stable security definer set search_path = ''
as $$
declare f public.catalogo_formulas%rowtype; v_m2 numeric; v_custo numeric;
begin
  if not private.dono_ou_servidor() then return null; end if;
  select * into f from public.catalogo_formulas where sku = p_sku and ativo and coalesce(erro_max_amostras_pct, 100) <= 1;
  if not found then return null; end if;   -- sem fórmula validada: NÃO gera oferta definitiva (o agente diz que vai confirmar)
  if (f.largura_min_mm is not null and p_largura_mm < f.largura_min_mm) or (f.largura_max_mm is not null and p_largura_mm > f.largura_max_mm)
     or (f.altura_min_mm is not null and p_altura_mm < f.altura_min_mm) or (f.altura_max_mm is not null and p_altura_mm > f.altura_max_mm) then return null; end if;
  v_m2 := (p_largura_mm::numeric / 1000) * (p_altura_mm::numeric / 1000);
  v_custo := greatest(coalesce(f.custo_minimo, 0), round(v_m2 * f.custo_m2, 2));
  return v_custo;
end;
$$;
revoke execute on function private.custo_por_dimensao(text, integer, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------- D3. complementares por regra (nunca em toda venda)
create table if not exists public.produtos_complementares (
  id uuid primary key default gen_random_uuid(),
  grupo_base text not null,
  sku_complementar text not null references public.catalogo (sku) on delete cascade,
  quantidade_minima integer not null default 1,
  segmento text,
  motivo text not null,
  ativo boolean not null default true,
  unique (grupo_base, sku_complementar)
);
alter table public.produtos_complementares enable row level security;
drop policy if exists produtos_complementares_dono on public.produtos_complementares;
create policy produtos_complementares_dono on public.produtos_complementares for select to authenticated using (private.is_staff());

-- Só existe oportunidade real se o complementar é vendável, passa na margem e a quantidade do pedido justifica
create or replace function public.complementar_sugerir(p_sku text, p_quantidade integer, p_segmento text default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare base record; r record; j jsonb; v_min numeric;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select grupo_produto into base from public.catalogo where sku = p_sku;
  select lucro_liquido_minimo into v_min from public.parametros_comerciais where id = 1;
  for r in select pc.* from public.produtos_complementares pc join public.catalogo c on c.sku = pc.sku_complementar
            where pc.ativo and pc.grupo_base = base.grupo_produto and c.vendavel and c.active and p_quantidade >= pc.quantidade_minima
              and (pc.segmento is null or lower(pc.segmento) = lower(coalesce(p_segmento, ''))) order by pc.quantidade_minima desc loop
    j := public.calcular_preco(r.sku_complementar, 1, '{}'::jsonb);
    if coalesce((j ->> 'ok')::boolean, false) and (j ->> 'lucro_liquido')::numeric >= v_min - 0.05 then
      return jsonb_build_object('ok', true, 'sugerir', true, 'sku', r.sku_complementar, 'motivo', r.motivo, 'preco', (j ->> 'preco_total')::numeric);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'sugerir', false);
end;
$$;
revoke execute on function public.complementar_sugerir(text, integer, text) from public, anon;
grant execute on function public.complementar_sugerir(text, integer, text) to authenticated, service_role;

-- ---------------------------------------------------------------- D5. estudo diário em modo sugestão
create table if not exists public.melhorias_sugeridas (
  id uuid primary key default gen_random_uuid(),
  criado_em timestamptz not null default now(),
  origem text not null default 'estudo_diario',
  alvo text not null check (alvo in ('conhecimento', 'resposta_pronta', 'followup_texto', 'prompt', 'preco', 'margem', 'piso', 'desconto', 'prazo', 'pagamento', 'politica', 'credencial', 'outro')),
  problema text not null, evidencia text not null, melhoria text not null, resultado_esperado text, risco text, como_medir text,
  exige_autorizacao boolean not null default true,
  status text not null default 'sugerida' check (status in ('sugerida', 'aprovada', 'recusada', 'aplicada_em_teste', 'revertida')),
  decidido_em timestamptz, decidido_por uuid,
  -- NUNCA muda preço, margem, piso, desconto, prazo, pagamento, política, prompt ou credencial sem aprovação do dono
  constraint melhorias_alvo_critico_exige_autorizacao check (alvo not in ('prompt', 'preco', 'margem', 'piso', 'desconto', 'prazo', 'pagamento', 'politica', 'credencial') or exige_autorizacao)
);
alter table public.melhorias_sugeridas enable row level security;
drop policy if exists melhorias_sugeridas_dono on public.melhorias_sugeridas;
create policy melhorias_sugeridas_dono on public.melhorias_sugeridas for select to authenticated using (private.is_staff());
create or replace function public.melhoria_decidir(p_id uuid, p_aprovar boolean) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_staff() then raise exception 'Não autorizado.' using errcode = '42501'; end if;
  update public.melhorias_sugeridas set status = case when p_aprovar then 'aprovada' else 'recusada' end, decidido_em = now(), decidido_por = auth.uid() where id = p_id and status = 'sugerida';
  return jsonb_build_object('ok', found);
end;
$$;
revoke execute on function public.melhoria_decidir(uuid, boolean) from public, anon;
grant execute on function public.melhoria_decidir(uuid, boolean) to authenticated;

-- Dados do dia para o estudo (conversas, perdas e objeções reais), sem texto de cliente além de trechos curtos
create or replace function public.estudo_diario_coletar(p_dia date default (now() at time zone 'America/Sao_Paulo')::date - 1) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return jsonb_build_object('dia', p_dia,
    'conversas', (select count(distinct conversation_id) from public.messages where direction = 'in' and (created_at at time zone 'America/Sao_Paulo')::date = p_dia),
    'orcamentos_enviados', (select count(*) from public.orcamentos where not teste and (pdf_enviado_em at time zone 'America/Sao_Paulo')::date = p_dia),
    'orcamentos_perdidos_por_motivo', coalesce((select jsonb_object_agg(motivo_perda, n) from (select motivo_perda, count(*) n from public.orcamentos where not teste and motivo_perda_em::date = p_dia group by 1) x), '{}'::jsonb),
    'lacunas_conhecimento', coalesce((select jsonb_agg(left(pergunta, 120)) from (select pergunta from public.conhecimento_lacunas where ultima_em::date = p_dia limit 20) x), '[]'::jsonb),
    'objecoes', coalesce((select jsonb_agg(left(body, 140)) from (select body from public.messages where direction = 'in' and (created_at at time zone 'America/Sao_Paulo')::date = p_dia
        and body ~* '(caro|desconto|mais barato|vou pensar|sem dinheiro|achei em outro|parcel)' limit 20) x), '[]'::jsonb));
end;
$$;
revoke execute on function public.estudo_diario_coletar(date) from public, anon, authenticated;
grant execute on function public.estudo_diario_coletar(date) to service_role;

-- ---------------------------------------------------------------- D6. experimentos controlados (só texto e momento)
create table if not exists public.experimentos (
  id uuid primary key default gen_random_uuid(),
  criado_em timestamptz not null default now(),
  hipotese text not null, metrica text not null default 'conversao_e_lucro',
  tipo text not null check (tipo in ('texto', 'momento')),   -- nunca regra crítica
  variantes jsonb not null check (jsonb_typeof(variantes) = 'array' and jsonb_array_length(variantes) >= 2),
  inicio date, fim date, amostra_minima integer not null default 100 check (amostra_minima >= 30),
  status text not null default 'rascunho' check (status in ('rascunho', 'rodando', 'encerrado')),
  resultado jsonb
);
create table if not exists public.experimento_grupos (
  experimento_id uuid not null references public.experimentos (id) on delete cascade,
  contact_id uuid not null references public.contacts (id) on delete cascade,
  variante text not null, criado_em timestamptz not null default now(),
  primary key (experimento_id, contact_id)
);
alter table public.experimentos enable row level security;
alter table public.experimento_grupos enable row level security;
drop policy if exists experimentos_dono on public.experimentos;
create policy experimentos_dono on public.experimentos for select to authenticated using (private.is_staff());
drop policy if exists experimento_grupos_dono on public.experimento_grupos;
create policy experimento_grupos_dono on public.experimento_grupos for select to authenticated using (private.is_staff());

-- Grupos equivalentes: a variante é decidida pelo hash do contato (determinística e sem viés de horário)
create or replace function public.experimento_variante(p_experimento uuid, p_contact uuid) returns text
language plpgsql security definer set search_path = ''
as $$
declare e public.experimentos%rowtype; v_idx integer; v_nome text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into e from public.experimentos where id = p_experimento and status = 'rodando';
  if not found then return null; end if;
  select variante into v_nome from public.experimento_grupos where experimento_id = p_experimento and contact_id = p_contact;
  if v_nome is not null then return v_nome; end if;
  v_idx := abs(('x' || substr(md5(p_experimento::text || p_contact::text), 1, 8))::bit(32)::int) % jsonb_array_length(e.variantes);
  v_nome := e.variantes ->> v_idx;
  insert into public.experimento_grupos (experimento_id, contact_id, variante) values (p_experimento, p_contact, v_nome) on conflict do nothing;
  return v_nome;
end;
$$;
revoke execute on function public.experimento_variante(uuid, uuid) from public, anon, authenticated;
grant execute on function public.experimento_variante(uuid, uuid) to service_role;

-- Mede conversão E lucro por variante. Amostra pequena: nunca declara vencedor.
create or replace function public.experimento_resultado(p_experimento uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare e public.experimentos%rowtype; r jsonb;
begin
  if not private.is_staff() and coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into e from public.experimentos where id = p_experimento;
  if not found then return null; end if;
  select jsonb_agg(jsonb_build_object('variante', g.variante, 'contatos', g.n, 'compraram', g.compraram, 'conversao_pct', round(g.compraram::numeric / nullif(g.n, 0) * 100, 1), 'lucro_liquido', g.lucro))
    into r from (
      select eg.variante, count(*) n, count(distinct o.contact_id) filter (where o.payment_status = 'aprovado') compraram,
             coalesce(sum(f.net_profit) filter (where o.payment_status = 'aprovado'), 0) lucro
        from public.experimento_grupos eg left join public.orders o on o.contact_id = eg.contact_id and o.created_at >= eg.criado_em and not coalesce(o.teste, false)
        left join public.order_financials f on f.order_id = o.id where eg.experimento_id = p_experimento group by eg.variante) g;
  return jsonb_build_object('variantes', coalesce(r, '[]'::jsonb),
    'amostra_total', (select count(*) from public.experimento_grupos where experimento_id = p_experimento),
    'amostra_minima_por_variante', e.amostra_minima,
    'vencedor', null,
    'conclusao', case when (select min(n) from (select count(*) n from public.experimento_grupos where experimento_id = p_experimento group by variante) q) >= e.amostra_minima
                      then 'amostra suficiente: compare conversão e lucro antes de decidir' else 'inconclusivo: amostra pequena, não declare vencedor' end);
end;
$$;
revoke execute on function public.experimento_resultado(uuid) from public, anon;
grant execute on function public.experimento_resultado(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- D7. indicações (infraestrutura mínima, sem recompensa)
alter table public.contacts add column if not exists codigo_indicacao text unique;
create table if not exists public.indicacoes (
  id uuid primary key default gen_random_uuid(),
  indicador_id uuid not null references public.contacts (id) on delete cascade,
  indicado_id uuid not null references public.contacts (id) on delete cascade unique,
  criado_em timestamptz not null default now(),
  compra_valida_em timestamptz,
  order_id uuid references public.orders (id) on delete set null,
  custo_beneficio numeric(12, 2) not null default 0,   -- sem recompensa até o dono definir
  check (indicador_id <> indicado_id)
);
alter table public.indicacoes enable row level security;
drop policy if exists indicacoes_dono on public.indicacoes;
create policy indicacoes_dono on public.indicacoes for select to authenticated using (private.is_staff());

create or replace function public.indicacao_codigo(p_contact uuid) returns text
language plpgsql security definer set search_path = ''
as $$
declare v text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select codigo_indicacao into v from public.contacts where id = p_contact;
  if v is null then
    v := 'SG' || upper(substr(md5(p_contact::text || 'sg-indica'), 1, 6));
    update public.contacts set codigo_indicacao = v where id = p_contact;
  end if;
  return v;
end;
$$;
revoke execute on function public.indicacao_codigo(uuid) from public, anon, authenticated;
grant execute on function public.indicacao_codigo(uuid) to service_role;

create or replace function public.indicacao_registrar(p_codigo text, p_indicado uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_ind uuid;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select id into v_ind from public.contacts where codigo_indicacao = upper(trim(p_codigo));
  if v_ind is null or v_ind = p_indicado then return jsonb_build_object('ok', false, 'motivo', 'codigo_invalido'); end if;
  insert into public.indicacoes (indicador_id, indicado_id) values (v_ind, p_indicado) on conflict (indicado_id) do nothing;
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.indicacao_registrar(text, uuid) from public, anon, authenticated;
grant execute on function public.indicacao_registrar(text, uuid) to service_role;

create or replace function private.indicacao_compra_valida() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.payment_status = 'aprovado' and old.payment_status is distinct from 'aprovado' and not coalesce(new.teste, false) then
    update public.indicacoes set compra_valida_em = now(), order_id = new.id where indicado_id = new.contact_id and compra_valida_em is null;
  end if;
  return new;
end;
$$;
revoke execute on function private.indicacao_compra_valida() from public, anon, authenticated;
drop trigger if exists orders_indicacao_compra on public.orders;
create trigger orders_indicacao_compra after update of payment_status on public.orders for each row execute function private.indicacao_compra_valida();

-- ---------------------------------------------------------------- D1/D4. atribuição, painel Comercial e rentabilidade por cliente (só o dono)
create or replace view public.atribuicao_pedidos with (security_invoker = true) as
select o.id as order_id, o.number, o.contact_id, o.created_at, o.payment_status, o.origin_ad_id, c.first_referral ->> 'source_type' as plataforma_origem,
       c.first_referral_at as primeiro_contato_em, ae.campaign_name as campanha, ae.adset_name as conjunto, ae.ad_name as anuncio,
       c.first_referral ->> 'headline' as criativo, c.first_referral ->> 'source_url' as origem_url, f.total, f.net_profit
  from public.orders o join public.contacts c on c.id = o.contact_id
  left join public.ad_entities ae on ae.ad_id = o.origin_ad_id left join public.order_financials f on f.order_id = o.id
 where not coalesce(o.teste, false) and o.excluido_em is null;
revoke all on public.atribuicao_pedidos from anon;

create or replace function public.painel_comercial(p_de date default current_date - 30, p_ate date default current_date) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_ini timestamptz := p_de::timestamp at time zone 'America/Sao_Paulo'; v_fim timestamptz := (p_ate + 1)::timestamp at time zone 'America/Sao_Paulo'; v_gasto numeric; v_fat numeric; v_lucro numeric; v_pagos int;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select coalesce(sum(spend), 0) + coalesce((select sum(amount) from public.ad_manual_spend where day between p_de and p_ate), 0) into v_gasto from public.ad_daily where day between p_de and p_ate;
  select count(*), coalesce(sum(f.total), 0), coalesce(sum(f.net_profit), 0) into v_pagos, v_fat, v_lucro
    from public.orders o join public.order_financials f on f.order_id = o.id
   where not coalesce(o.teste, false) and o.excluido_em is null and o.payment_status = 'aprovado' and o.paid_at >= v_ini and o.paid_at < v_fim;
  return jsonb_build_object('periodo', jsonb_build_object('de', p_de, 'ate', p_ate),
    'aquisicao', jsonb_build_object('contatos_novos', (select count(*) from public.contacts where created_at >= v_ini and created_at < v_fim),
        'vindos_de_anuncio', (select count(*) from public.contacts where first_referral is not null and created_at >= v_ini and created_at < v_fim),
        'gasto_anuncios', v_gasto),
    'conversao', jsonb_build_object('orcamentos_enviados', (select count(*) from public.orcamentos where not teste and origem_id is null and pdf_enviado_em >= v_ini and pdf_enviado_em < v_fim),
        'pedidos_pagos', v_pagos,
        'perdidos_por_motivo', coalesce((select jsonb_object_agg(motivo_perda, n) from (select motivo_perda, count(*) n from public.orcamentos where not teste and motivo_perda_em >= v_ini and motivo_perda_em < v_fim group by 1) x), '{}'::jsonb)),
    'rentabilidade', jsonb_build_object('faturamento', v_fat, 'lucro_liquido', v_lucro, 'ticket_medio', round(v_fat / nullif(v_pagos, 0), 2),
        'lucro_menos_anuncios', v_lucro - v_gasto, 'custo_por_pedido', round(v_gasto / nullif(v_pagos, 0), 2),
        'roas_faturamento', round(v_fat / nullif(v_gasto, 0), 2), 'roas_lucro', round(v_lucro / nullif(v_gasto, 0), 2)),
    'fidelizacao', jsonb_build_object('clientes_que_recompraram', (select count(*) from public.contact_stats where paid_orders >= 2), 'clientes_com_compra', (select count(*) from public.contact_stats where paid_orders >= 1)),
    'operacao', jsonb_build_object('pedidos_atrasados', (select count(*) from public.orders o where o.excluido_em is null and public.pedido_esta_atrasado(o.stage::text, o.due_date, o.delivered_at)),
        'pedidos_urgentes_abertos', (select count(*) from public.orders o where o.urgente and o.excluido_em is null and o.stage not in ('entregue', 'recompra')),
        'alertas_nao_lidos', (select count(*) from public.alertas where lido_em is null)));
end;
$$;
revoke execute on function public.painel_comercial(date, date) from public, anon;
grant execute on function public.painel_comercial(date, date) to authenticated;

create or replace function public.rentabilidade_cliente(p_limite integer default 50) returns table (contact_id uuid, nome text, compras bigint, faturamento numeric, lucro_acumulado numeric, primeira_compra timestamptz, ultima_compra timestamptz, custo_aquisicao numeric)
language sql stable security definer set search_path = ''
as $$
  select c.id, c.name, count(o.id), coalesce(sum(f.total), 0), coalesce(sum(f.net_profit), 0), min(o.paid_at), max(o.paid_at),
         coalesce((select sum(d.spend) / nullif((select count(*) from public.contacts c2 where c2.first_referral ->> 'source_id' = c.first_referral ->> 'source_id'), 0)
                     from public.ad_daily d where d.ad_id = c.first_referral ->> 'source_id'), 0)
    from public.contacts c join public.orders o on o.contact_id = c.id and o.payment_status = 'aprovado' and not coalesce(o.teste, false) and o.excluido_em is null
    join public.order_financials f on f.order_id = o.id
   where private.is_staff() group by c.id order by 5 desc limit p_limite;
$$;
revoke execute on function public.rentabilidade_cliente(integer) from public, anon;
grant execute on function public.rentabilidade_cliente(integer) to authenticated;
