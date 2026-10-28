-- Etapa 3: preço sob demanda, aprendizado e condição especial.
-- Aditiva e idempotente. Não pesquisa em massa e não expõe custo, margem ou piso ao cliente.

-- Cada grupo pode aprender sem alterar o fator global usado como reserva.
create table if not exists public.fatores_competitivos (
  grupo_produto text primary key,
  fator numeric(4,3) not null default 0.930 check (fator between 0.900 and 0.980),
  atualizado_em timestamptz not null default now(),
  atualizado_por text not null default 'carga_inicial'
);

create table if not exists public.ajustes_fator_preco (
  id uuid primary key default gen_random_uuid(),
  grupo_produto text not null,
  fator_antes numeric(4,3) not null,
  fator_depois numeric(4,3) not null,
  conversao numeric(6,3) not null,
  orcamentos integer not null,
  motivo text not null,
  criado_em timestamptz not null default now()
);
create index if not exists ajustes_fator_preco_grupo_idx on public.ajustes_fator_preco (grupo_produto, criado_em desc);

-- Uma consulta representa a pesquisa sob demanda. As linhas de precos_mercado guardam as fontes.
create table if not exists public.consultas_preco_mercado (
  id uuid primary key default gen_random_uuid(),
  chave_especificacao text not null,
  sku text references public.catalogo(sku) on delete set null,
  especificacao jsonb not null default '{}'::jsonb,
  status text not null default 'pendente' check (status in ('pendente','concluida','sem_dado','erro','cache')),
  confianca text check (confianca in ('alta','media','baixa')),
  mediana numeric(12,2),
  minimo numeric(12,2),
  maximo numeric(12,2),
  fontes_validas smallint not null default 0,
  duracao_ms integer,
  erro text,
  criado_em timestamptz not null default now(),
  concluido_em timestamptz
);
create index if not exists consultas_preco_mercado_chave_idx on public.consultas_preco_mercado (chave_especificacao, criado_em desc);

alter table public.precos_mercado add column if not exists consulta_id uuid references public.consultas_preco_mercado(id) on delete set null;
alter table public.precos_mercado add column if not exists especificacao jsonb not null default '{}'::jsonb;
alter table public.precos_mercado add column if not exists normalizado boolean not null default true;
alter table public.precos_mercado add column if not exists expira_em timestamptz;
alter table public.precos_mercado add column if not exists texto_origem text;
alter table public.precos_mercado add column if not exists motivo_descarte text;
create index if not exists precos_mercado_cache_valido_idx on public.precos_mercado (chave_especificacao, coletado_em desc) where invalidado_em is null and not outlier;
update public.precos_mercado set normalizado = true where normalizado is false and consulta_id is null;

-- O orçamento sempre registra de onde saiu o preço. Isto também alimenta o aprendizado.
alter table public.orcamento_itens add column if not exists preco_mercado_id uuid references public.precos_mercado(id) on delete set null;
alter table public.orcamento_itens add column if not exists fontes_mercado smallint;
alter table public.orcamento_itens add column if not exists nao_competitivo boolean not null default false;
alter table public.orcamento_itens add column if not exists piso numeric(12,2);
alter table public.orcamento_itens add column if not exists piso_duro numeric(12,2);
alter table public.orcamento_itens add column if not exists lucro_liquido numeric(12,2);
alter table public.condicoes_especiais add column if not exists substitui_orcamento_id uuid references public.orcamentos(id) on delete set null;
alter table public.condicoes_especiais add column if not exists link_anterior_invalidado_em timestamptz;

-- Política nunca pode ser salva se permitir desconto que ultrapasse a gordura ou preço negativo.
create or replace function private.validar_politica_desconto_etapa3() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.tipo = 'desconto' and (new.percentual > 10 or new.fracao_gordura_max > 1 or new.desconto_max_reais < 0) then
    raise exception 'Política de desconto inválida: poderia gerar prejuízo.' using errcode = '23514';
  end if;
  if new.validade_horas <= 0 or new.intervalo_dias_contato < 0 then
    raise exception 'Validade e intervalo devem ser positivos.' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke execute on function private.validar_politica_desconto_etapa3() from public, anon, authenticated;
drop trigger if exists politica_desconto_validar_etapa3 on public.politica_desconto;
create trigger politica_desconto_validar_etapa3 before insert or update on public.politica_desconto
  for each row execute function private.validar_politica_desconto_etapa3();

-- Grava resultados de uma pesquisa somente depois de a automação normalizar a mesma especificação.
create or replace function public.registrar_pesquisa_mercado(
  p_consulta uuid, p_fontes jsonb, p_duracao_ms integer default null, p_erro text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  c public.consultas_preco_mercado%rowtype;
  f jsonb; v_preco numeric; v_mediana numeric; v_min numeric; v_max numeric; v_n integer; v_mad numeric;
  v_conf text; v_outliers integer := 0;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão para registrar pesquisa.' using errcode = '42501'; end if;
  select * into c from public.consultas_preco_mercado where id = p_consulta for update;
  if not found then raise exception 'Consulta não encontrada.' using errcode = 'P0001'; end if;
  if c.status in ('concluida','cache') then return jsonb_build_object('ok', true, 'status', c.status); end if;

  for f in select * from jsonb_array_elements(coalesce(p_fontes, '[]'::jsonb)) loop
    v_preco := nullif(f ->> 'preco','')::numeric;
    if v_preco is not null and v_preco > 0 and coalesce((f ->> 'mesma_especificacao')::boolean, false) then
      insert into public.precos_mercado (consulta_id, sku, chave_especificacao, descricao, quantidade, fonte, url, preco, especificacao, normalizado, texto_origem, expira_em)
      values (c.id, c.sku, c.chave_especificacao, f ->> 'descricao', nullif(f ->> 'quantidade','')::integer,
              coalesce(nullif(f ->> 'fonte',''), 'fonte_sem_nome'), nullif(f ->> 'url',''), v_preco, c.especificacao, true,
              left(coalesce(f ->> 'texto',''), 4000), now() + interval '14 days');
    end if;
  end loop;

  select percentile_cont(0.5) within group (order by preco), min(preco), max(preco), count(*)
    into v_mediana, v_min, v_max, v_n
  from public.precos_mercado where consulta_id = c.id and normalizado and not outlier;
  if v_n > 2 then
    select percentile_cont(0.5) within group (order by abs(preco - v_mediana)) into v_mad
    from public.precos_mercado where consulta_id = c.id and normalizado and not outlier;
    if coalesce(v_mad, 0) > 0 then
      update public.precos_mercado set outlier = true, motivo_descarte = 'fora_de_3_mad'
      where consulta_id = c.id and normalizado and abs(preco - v_mediana) > 3 * v_mad;
      get diagnostics v_outliers = row_count;
      select percentile_cont(0.5) within group (order by preco), min(preco), max(preco), count(*)
        into v_mediana, v_min, v_max, v_n
      from public.precos_mercado where consulta_id = c.id and normalizado and not outlier;
    end if;
  end if;
  v_conf := case when v_n >= 3 then 'alta' when v_n = 2 then 'media' when v_n = 1 then 'baixa' else null end;
  update public.precos_mercado set confianca = v_conf where consulta_id = c.id and not outlier;
  update public.consultas_preco_mercado
     set status = case when v_n = 0 then case when p_erro is null then 'sem_dado' else 'erro' end else 'concluida' end,
         confianca = v_conf, mediana = v_mediana, minimo = v_min, maximo = v_max, fontes_validas = v_n,
         duracao_ms = p_duracao_ms, erro = p_erro, concluido_em = now()
   where id = c.id;
  return jsonb_build_object('ok', true, 'status', case when v_n = 0 then 'sem_dado' else 'concluida' end,
    'mediana', v_mediana, 'minimo', v_min, 'maximo', v_max, 'confianca', v_conf, 'fontes', v_n, 'outliers', v_outliers);
end;
$$;

-- Cache primeiro: o workflow só inicia busca quando esta função devolver precisa_pesquisar=true.
create or replace function public.consultar_cache_preco_mercado(p_sku text, p_especificacao jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_chave text; v_consulta uuid; v_reg record;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select coalesce(nullif(especificacao_normalizada,''), sku) into v_chave from public.catalogo where sku = p_sku;
  if v_chave is null then return jsonb_build_object('ok',false,'erro','sku_nao_encontrado'); end if;
  select percentile_cont(0.5) within group (order by preco) as mediana, min(preco) as minimo, max(preco) as maximo, count(*) as fontes
    into v_reg from public.precos_mercado
   where (chave_especificacao = v_chave or sku = p_sku) and normalizado and not outlier and invalidado_em is null
     and coletado_em >= now() - interval '14 days';
  if v_reg.fontes > 0 then
    return jsonb_build_object('ok',true,'cache',true,'precisa_pesquisar',false,'chave_especificacao',v_chave,
      'mediana',v_reg.mediana,'minimo',v_reg.minimo,'maximo',v_reg.maximo,'fontes',v_reg.fontes,
      'confianca',case when v_reg.fontes >= 3 then 'alta' when v_reg.fontes = 2 then 'media' else 'baixa' end);
  end if;
  insert into public.consultas_preco_mercado (sku,chave_especificacao,especificacao)
  values (p_sku,v_chave,coalesce(p_especificacao,'{}'::jsonb)) returning id into v_consulta;
  return jsonb_build_object('ok',true,'cache',false,'precisa_pesquisar',true,'consulta_id',v_consulta,'chave_especificacao',v_chave);
end;
$$;

-- Preço único: mercado da especificação, fator por grupo, âncora de vendas e travas.
create or replace function public.calcular_preco(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable set search_path = ''
as $$
declare pr public.parametros_comerciais%rowtype; prod record; v_qtd integer := greatest(coalesce(p_quantidade,1),1);
  v_metodo text := p_contexto ->> 'metodo'; v_outros_receita numeric := coalesce((p_contexto ->> 'receita_outros')::numeric,0);
  v_outros_custo numeric := coalesce((p_contexto ->> 'custo_outros')::numeric,0); v_custo numeric; v_extra numeric;
  v_piso numeric; v_piso_duro numeric; v_base numeric; v_mediana numeric; v_n integer; v_fator numeric; v_ancora numeric;
  v_alvo numeric; v_preco numeric; v_regra text; v_conf text; v_nao boolean := false; v_lucro numeric; v_avisos text[] := '{}';
begin
  select * into pr from public.parametros_comerciais where id=1;
  select custo, active, vendavel, grupo_produto, especificacao_normalizada into prod from public.catalogo where sku=p_sku;
  if not found or not prod.active then return jsonb_build_object('ok',false,'erro','sku_nao_encontrado'); end if;
  if not prod.vendavel then return jsonb_build_object('ok',false,'erro','item_nao_vendavel'); end if;
  v_custo := prod.custo*v_qtd + v_outros_custo; v_extra := private.custos_operacionais(p_contexto ->> 'entrega');
  v_piso := ceil(greatest(prod.custo*v_qtd*pr.multiplicador_piso, private.receita_para_lucro(v_custo,v_extra,pr.lucro_liquido_minimo,v_metodo)-v_outros_receita)*100)/100;
  v_piso_duro := ceil((private.receita_para_lucro(v_custo,v_extra,0,v_metodo)-v_outros_receita)*100)/100;
  v_base := private.arredonda_90(prod.custo*v_qtd*private.multiplicador_faixa(prod.custo*v_qtd));
  select percentile_cont(0.5) within group (order by preco), count(*) into v_mediana,v_n from public.precos_mercado m
   where (m.chave_especificacao=coalesce(nullif(prod.especificacao_normalizada,''),p_sku) or m.sku=p_sku) and m.normalizado and not m.outlier and m.invalidado_em is null and m.coletado_em >= now()-interval '14 days';
  select coalesce(fator,pr.fator_competitivo) into v_fator from public.fatores_competitivos where grupo_produto=prod.grupo_produto;
  v_fator := coalesce(v_fator,pr.fator_competitivo);
  select avg(preco_total) into v_ancora from public.precos_praticados pp
   where pp.sku=p_sku and pp.resultado='ganho' and pp.criado_em >= now()-interval '90 days';
  if (select count(*) from public.precos_praticados pp where pp.sku=p_sku and pp.resultado='ganho' and pp.criado_em >= now()-interval '90 days') < 3 then v_ancora:=null; end if;
  if v_n > 0 then
    v_alvo := private.arredonda_90(v_mediana*v_qtd*v_fator);
    if v_ancora is not null then v_alvo := private.arredonda_90(least(v_alvo,(v_alvo+v_ancora)/2)); end if;
    v_regra := case when v_ancora is null then 'mercado' else 'mercado_com_ancora_vendas' end;
    v_conf := case when v_n>=3 then 'alta' when v_n=2 then 'media' else 'baixa' end;
  else v_alvo:=v_base; v_regra:='custo_x_multiplicador'; v_conf:='baixa'; end if;
  if v_alvo < v_piso then v_preco:=private.teto_90(v_piso); v_nao:=v_n>0; if v_nao then v_avisos:=array_append(v_avisos,'mercado_abaixo_do_piso'); end if; else v_preco:=v_alvo; end if;
  v_lucro:=private.lucro(v_preco+v_outros_receita,v_custo,v_extra,v_metodo);
  return jsonb_build_object('ok',true,'sku',p_sku,'quantidade',v_qtd,'preco_unitario',round(v_preco/v_qtd,2),'preco_total',v_preco,
    'regra',v_regra,'confianca',v_conf,'margem_liquida_pct',round(v_lucro/nullif(v_preco+v_outros_receita,0)*100,1),'lucro_liquido',v_lucro,
    'piso',v_piso,'piso_duro',v_piso_duro,'nao_competitivo',v_nao,'fontes_mercado',v_n,'fator_competitivo',v_fator,'avisos',to_jsonb(v_avisos));
end;
$$;

-- Registra cada orçamento e atualiza seu resultado quando pago/perdido/expirado.
create or replace function private.precos_praticados_sincronizar() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare i record; v_resultado text;
begin
  v_resultado := case new.status when 'pago' then 'ganho' when 'perdido' then 'perdido' when 'expirado' then 'expirado' else 'aberto' end;
  if tg_op='INSERT' or (tg_op='UPDATE' and new.status is distinct from old.status) then
    for i in select oi.*, c.grupo_produto from public.orcamento_itens oi left join public.catalogo c on c.sku=oi.sku where oi.orcamento_id=new.id loop
      insert into public.precos_praticados (orcamento_id,contact_id,sku,grupo_produto,quantidade,preco_total,margem_liquida_pct,regra_preco,resultado,fechado_em)
      values (new.id,new.contact_id,i.sku,coalesce(i.grupo_produto,''),i.quantidade,i.preco_unitario*i.quantidade,i.margem_liquida_pct,i.regra_preco,v_resultado,case when v_resultado='aberto' then null else now() end)
      on conflict (orcamento_id,sku) do update set resultado=excluded.resultado, fechado_em=excluded.fechado_em, preco_total=excluded.preco_total, margem_liquida_pct=excluded.margem_liquida_pct;
    end loop;
  end if;
  return new;
end;
$$;
revoke execute on function private.precos_praticados_sincronizar() from public,anon,authenticated;
create unique index if not exists precos_praticados_orc_sku_uniq on public.precos_praticados (orcamento_id,sku) where orcamento_id is not null;
drop trigger if exists orcamentos_precos_praticados on public.orcamentos;
create trigger orcamentos_precos_praticados after insert or update of status on public.orcamentos for each row execute function private.precos_praticados_sincronizar();

create or replace function public.aprender_precos_semana() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r record; pr public.parametros_comerciais%rowtype; v_n integer:=0; v_antes numeric; v_depois numeric;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode='42501'; end if;
  select * into pr from public.parametros_comerciais where id=1;
  for r in select grupo_produto,count(*) n,count(*) filter(where resultado='ganho') ganhos,avg(margem_liquida_pct) margem
      from public.precos_praticados where criado_em>=now()-interval '30 days' group by grupo_produto having count(*)>=8 loop
    if (r.ganhos::numeric/r.n)<.15 and r.margem > 0 then
      insert into public.fatores_competitivos(grupo_produto,fator,atualizado_por) values(r.grupo_produto,greatest(pr.fator_competitivo_min,pr.fator_competitivo-.01),'aprendizado') on conflict do nothing;
      select fator into v_antes from public.fatores_competitivos where grupo_produto=r.grupo_produto;
      update public.fatores_competitivos set fator=greatest(pr.fator_competitivo_min,fator-.01),atualizado_em=now(),atualizado_por='aprendizado' where grupo_produto=r.grupo_produto returning fator into v_depois;
      insert into public.ajustes_fator_preco(grupo_produto,fator_antes,fator_depois,conversao,orcamentos,motivo) values(r.grupo_produto,v_antes,v_depois,r.ganhos::numeric/r.n,r.n,'conversão abaixo de 15% com margem acima da meta'); v_n:=v_n+1;
    elsif (r.ganhos::numeric/r.n)>.45 then
      insert into public.fatores_competitivos(grupo_produto,fator,atualizado_por) values(r.grupo_produto,least(pr.fator_competitivo_max,pr.fator_competitivo+.01),'aprendizado') on conflict do nothing;
      select fator into v_antes from public.fatores_competitivos where grupo_produto=r.grupo_produto;
      update public.fatores_competitivos set fator=least(pr.fator_competitivo_max,fator+.01),atualizado_em=now(),atualizado_por='aprendizado' where grupo_produto=r.grupo_produto returning fator into v_depois;
      insert into public.ajustes_fator_preco(grupo_produto,fator_antes,fator_depois,conversao,orcamentos,motivo) values(r.grupo_produto,v_antes,v_depois,r.ganhos::numeric/r.n,r.n,'conversão acima de 45%'); v_n:=v_n+1;
    end if;
  end loop;
  return jsonb_build_object('ok',true,'ajustes',v_n);
end;
$$;

-- Visão para Catálogo > Saúde de preços; só o dono, com RLS das tabelas base.
create or replace view public.saude_precos with (security_invoker=true) as
select c.grupo_produto,
  count(*) filter(where c.active) itens_ativos,
  count(*) filter(where c.active and exists(select 1 from public.precos_mercado m where m.chave_especificacao=coalesce(nullif(c.especificacao_normalizada,''),c.sku) and m.normalizado and not m.outlier and m.invalidado_em is null and m.coletado_em>=now()-interval '14 days')) cobertura_mercado,
  count(*) filter(where c.status_venda='nao_competitivo') nao_competitivos,
  count(*) filter(where c.status_venda='nao_vender') nao_vender,
  avg(pp.margem_liquida_pct) margem_liquida_media,
  count(pp.id) orcamentos_30d,
  count(pp.id) filter(where pp.resultado='ganho') ganhos_30d
from public.catalogo c left join public.precos_praticados pp on pp.sku=c.sku and pp.criado_em>=now()-interval '30 days'
group by c.grupo_produto;

-- Acesso: só dono e service role. Nenhuma destas rotas fica disponível para anon.
do $$ declare t text; begin
  foreach t in array array['fatores_competitivos','ajustes_fator_preco','consultas_preco_mercado'] loop
    execute format('alter table public.%I enable row level security',t); execute format('revoke all on table public.%I from anon',t);
    execute format('drop policy if exists %I on public.%I',t||'_dono',t); execute format('create policy %I on public.%I for all to authenticated using (private.is_staff()) with check (private.is_staff())',t||'_dono',t);
  end loop;
end $$;
revoke all on public.saude_precos from anon;
revoke execute on function public.registrar_pesquisa_mercado(uuid,jsonb,integer,text), public.consultar_cache_preco_mercado(text,jsonb), public.aprender_precos_semana() from public,anon;
grant execute on function public.registrar_pesquisa_mercado(uuid,jsonb,integer,text), public.consultar_cache_preco_mercado(text,jsonb), public.aprender_precos_semana() to authenticated,service_role;
