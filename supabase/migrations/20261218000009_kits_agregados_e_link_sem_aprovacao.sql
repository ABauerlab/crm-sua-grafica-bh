-- 18/11/2026: (1) kit agregado "Crachá + cordão" calculado a partir dos SKUs e custos reais;
-- (2) o link de pagamento não depende mais de "APROVADO" (sai logo depois do PDF, pelo orcamento-pdf).
-- Aditiva e idempotente.

-- ---------------------------------------------------------------- kits agregados
create table if not exists public.kits_agregados (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  nome text not null,
  descricao text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

create table if not exists public.kits_agregados_componentes (
  id uuid primary key default gen_random_uuid(),
  kit_id uuid not null references public.kits_agregados(id) on delete cascade,
  papel text not null,
  -- expressão regular (sem diferenciar maiúsculas) aplicada à descrição do SKU do catálogo
  padrao_descricao text not null,
  -- o abatimento do kit sai da linha deste componente (nunca abaixo do piso de 1,5x o custo e do piso duro)
  recebe_abatimento boolean not null default false,
  unique (kit_id, papel)
);

alter table public.kits_agregados enable row level security;
alter table public.kits_agregados_componentes enable row level security;
drop policy if exists kits_agregados_leitura on public.kits_agregados;
create policy kits_agregados_leitura on public.kits_agregados for select to authenticated using (private.is_staff());
drop policy if exists kits_agregados_escrita on public.kits_agregados;
create policy kits_agregados_escrita on public.kits_agregados for all to authenticated using (private.is_admin()) with check (private.is_admin());
drop policy if exists kits_agregados_comp_leitura on public.kits_agregados_componentes;
create policy kits_agregados_comp_leitura on public.kits_agregados_componentes for select to authenticated using (private.is_staff());
drop policy if exists kits_agregados_comp_escrita on public.kits_agregados_componentes;
create policy kits_agregados_comp_escrita on public.kits_agregados_componentes for all to authenticated using (private.is_admin()) with check (private.is_admin());

alter table public.orcamentos add column if not exists kit_agregado_id uuid references public.kits_agregados(id) on delete set null;
alter table public.orcamentos add column if not exists kit_abatimento numeric(12,2);

insert into public.kits_agregados (slug, nome, descricao)
values ('cracha-cordao', 'Crachá + cordão',
        'Crachá e cordão no mesmo pedido. O lucro bruto mínimo do pedido vale uma vez só, então a linha do cordão abate o excedente. Os dois itens continuam com SKU e custo reais; nunca abaixo de 1,5x o custo, do piso duro nem do lucro bruto mínimo do conjunto.')
on conflict (slug) do nothing;

insert into public.kits_agregados_componentes (kit_id, papel, padrao_descricao, recebe_abatimento)
select k.id, v.papel, v.padrao, v.recebe
  from public.kits_agregados k
  cross join (values ('cracha', '^CRACH', false), ('cordao', '^CORD', true)) as v(papel, padrao, recebe)
 where k.slug = 'cracha-cordao'
on conflict (kit_id, papel) do nothing;

-- ---------------------------------------------------------------- aplicar o kit a um orçamento recém-montado
create or replace function private.kit_agregado_aplicar(p_orcamento uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $f$
declare
  k record;
  pr public.parametros_comerciais%rowtype;
  v_comp record;
  v_alvo record;
  v_falta boolean;
  v_val jsonb;
  v_linha numeric;
  v_piso numeric;
  v_cap numeric;
  v_r numeric;
  v_novo numeric;
  v_unit numeric;
  v_tent numeric[] := array[65, 50, 40, 30, 20, 10];
  t numeric;
  v_abatido numeric;
  v_fin jsonb;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  if exists (select 1 from public.orcamentos where id = p_orcamento and kit_agregado_id is not null) then return null; end if;

  for k in select * from public.kits_agregados where ativo order by criado_em loop
    v_falta := false;
    for v_comp in select * from public.kits_agregados_componentes where kit_id = k.id loop
      if not exists (select 1 from public.orcamento_itens i where i.orcamento_id = p_orcamento and i.descricao ~* v_comp.padrao_descricao) then
        v_falta := true;
      end if;
    end loop;
    if v_falta then continue; end if;

    select i.id, i.quantidade, i.preco_unitario, i.sku, coalesce(c.custo, 0) as custo_pacote, coalesce(i.piso_duro, 0) as piso_duro
      into v_alvo
      from public.orcamento_itens i
      join public.kits_agregados_componentes kc on kc.kit_id = k.id and kc.recebe_abatimento and i.descricao ~* kc.padrao_descricao
      left join public.catalogo c on c.sku = i.sku
     where i.orcamento_id = p_orcamento
     order by i.quantidade * i.preco_unitario desc
     limit 1;
    if not found or v_alvo.sku is null then continue; end if;

    v_linha := v_alvo.quantidade * v_alvo.preco_unitario;
    v_piso := greatest(v_alvo.custo_pacote * v_alvo.quantidade * pr.multiplicador_piso, v_alvo.piso_duro);
    v_cap := v_linha - v_piso;
    if v_cap < 5 then continue; end if;

    foreach t in array v_tent loop
      v_r := least(t, v_cap);
      -- novo total da linha termina em ,90 como o resto da tabela, sem passar do abatimento tentado
      v_novo := floor(v_linha - v_r - 0.90) + 0.90;
      if v_novo < v_piso or v_novo >= v_linha then continue; end if;
      v_unit := ceil(v_novo / v_alvo.quantidade * 100) / 100;
      begin
        update public.orcamento_itens set preco_unitario = v_unit where id = v_alvo.id;
        v_val := public.validar_margem(p_orcamento);
        if v_val ->> 'status' is distinct from 'ok' then
          raise exception 'kit_recusado_pela_trava';
        end if;
        v_abatido := round(v_linha - v_alvo.quantidade * v_unit, 2);
        update public.orcamentos set kit_agregado_id = k.id, kit_abatimento = v_abatido where id = p_orcamento;
        v_fin := private.orcamento_financeiro(p_orcamento);
        update public.orcamentos
           set custo_total = (v_fin ->> 'custo')::numeric + (v_fin ->> 'extra')::numeric,
               lucro_liquido = (v_fin ->> 'lucro')::numeric,
               margem_liquida_pct = round((v_fin ->> 'lucro')::numeric / nullif((v_fin ->> 'receita')::numeric, 0) * 100, 1)
         where id = p_orcamento;
        return jsonb_build_object('kit', k.nome, 'abatimento', v_abatido);
      exception when others then
        null; -- a atualização do bloco volta sozinha; tenta um abatimento menor
      end;
    end loop;
  end loop;
  return null;
end
$f$;

-- ---------------------------------------------------------------- montar_orcamento passa pelo kit
do $mig$
begin
  if not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'montar_orcamento_pre_kit') then
    alter function public.montar_orcamento(uuid, jsonb, jsonb) rename to montar_orcamento_pre_kit;
  end if;
end
$mig$;

create or replace function public.montar_orcamento(p_contact uuid, p_itens jsonb, p_opcoes jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $f$
declare
  v_res jsonb;
  v_id uuid;
  v_kit jsonb;
  v_itens jsonb;
begin
  v_res := public.montar_orcamento_pre_kit(p_contact, p_itens, p_opcoes);
  if jsonb_typeof(v_res) <> 'object' or v_res ->> 'status' is distinct from 'ok' then return v_res; end if;
  begin
    v_id := (v_res ->> 'orcamento_id')::uuid;
    v_kit := private.kit_agregado_aplicar(v_id);
    if v_kit is not null then
      select coalesce(jsonb_agg(jsonb_build_object(
               'descricao', i.descricao, 'especificacao', i.especificacao, 'quantidade', i.quantidade,
               'acabamento', i.acabamento, 'area_m2', i.area_m2, 'valor_unitario', i.preco_unitario,
               'valor_total', i.quantidade * i.preco_unitario) order by i.criado_em, i.id), '[]'::jsonb)
        into v_itens from public.orcamento_itens i where i.orcamento_id = v_id;
      v_res := v_res || jsonb_build_object(
        'itens', v_itens,
        'subtotal', (select subtotal from public.orcamentos where id = v_id),
        'total', (select total from public.orcamentos where id = v_id),
        'kit', v_kit || jsonb_build_object('orientacao', 'Kit crachá + cordão: apresente o conjunto com o total desta resposta (o valor do cordão já está ajustado). Não fale em desconto nem em abatimento; é o preço do kit.'));
      if jsonb_array_length(v_itens) > 1 then
        v_res := v_res || jsonb_build_object('resumo_composto', private.resumo_composto(v_id));
      end if;
    end if;
  exception when others then
    raise warning 'montar_orcamento: kit ignorado: %', sqlerrm;
  end;
  return v_res;
end
$f$;

revoke execute on function public.montar_orcamento(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.montar_orcamento(uuid, jsonb, jsonb) to authenticated, service_role;
revoke execute on function public.montar_orcamento_pre_kit(uuid, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.montar_orcamento_pre_kit(uuid, jsonb, jsonb) to service_role;
revoke execute on function private.kit_agregado_aplicar(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- link de pagamento sem "APROVADO"
create or replace function public.preparar_link_pagamento(p_orcamento uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $f$
declare
  o public.orcamentos%rowtype;
  v_val jsonb;
  v_order uuid;
  v_tot numeric;
  v_horas numeric;
  v_pago text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orcamentos where id = p_orcamento for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'orcamento_nao_encontrado'); end if;
  if o.status in ('pago', 'cancelado', 'perdido') then return jsonb_build_object('ok', false, 'motivo', 'orcamento_encerrado'); end if;
  if o.status = 'expirado' or o.validade_ate is null or o.validade_ate <= now() then
    return jsonb_build_object('ok', false, 'motivo', 'orcamento_vencido', 'alternativa', 'Gerar um novo orçamento (orcamento_renovar) antes de cobrar.');
  end if;
  if o.pdf_enviado_em is null then
    return jsonb_build_object('ok', false, 'motivo', 'pdf_formal_nao_enviado', 'alternativa', 'Envie o PDF formal do orçamento; o link sai logo depois dele.');
  end if;
  -- 18/11/2026 (decisão do dono): o link não espera mais o cliente responder APROVADO; a trava de lucro continua valendo.
  v_val := public.validar_margem(p_orcamento);
  if v_val ->> 'status' <> 'ok' then
    return jsonb_build_object('ok', false, 'motivo', v_val ->> 'motivo', 'alternativa', 'Não envie o link. Chame o dono.');
  end if;
  v_order := private.orcamento_para_pedido(p_orcamento);
  select payment_status into v_pago from public.orders where id = v_order;
  if v_pago = 'aprovado' then return jsonb_build_object('ok', false, 'motivo', 'pedido_ja_pago'); end if;
  select total into v_tot from public.order_financials where order_id = v_order;
  if abs(coalesce(v_tot, 0) - o.total) > 0.01 then
    return jsonb_build_object('ok', false, 'motivo', 'valor_do_pedido_diferente_do_orcamento', 'alternativa', 'Chame o dono para conferir o pedido.');
  end if;
  v_horas := greatest(round(extract(epoch from (o.validade_ate - now())) / 3600.0, 2), 0.1);
  return jsonb_build_object('ok', true, 'order_id', v_order, 'expira_horas', v_horas, 'total', o.total,
    'numero', private.orcamento_numero(o.numero), 'texto_curto', 'Pode pagar por Pix ou cartão pelo link. O valor já está certinho.');
end;
$f$;
