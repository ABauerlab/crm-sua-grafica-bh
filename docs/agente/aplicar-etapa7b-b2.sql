-- Etapa 7B, Bloco B8: cupom de recompra INCONDICIONAL (5% na próxima compra de quem já concluiu um pedido, sem relação com avaliação).
-- Nasce DESLIGADO. Antes de ligar, rode public.cupom_recompra_simular() e aprove a simulação de margem.
-- Aplicado só por função, respeitando o piso, uma vez por cliente, com validade e registro.
insert into public.app_settings (key, value) values ('cupom_recompra', jsonb_build_object('ativo', false, 'percentual', 5, 'validade_dias', 30, 'fracao_gordura_max', 0.5))
on conflict (key) do nothing;

create table if not exists public.cupons_recompra (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid not null references public.contacts (id) on delete cascade,
  order_origem uuid references public.orders (id) on delete set null,
  percentual numeric(4, 2) not null,
  valido_ate timestamptz not null,
  usado_em timestamptz,
  orcamento_id uuid references public.orcamentos (id) on delete set null,
  desconto_valor numeric(12, 2),
  criado_em timestamptz not null default now(),
  unique (contact_id)
);
alter table public.cupons_recompra enable row level security;
drop policy if exists cupons_recompra_dono on public.cupons_recompra;
create policy cupons_recompra_dono on public.cupons_recompra for select to authenticated using (private.is_staff());

-- Quem concluiu (entregou) um pedido pago ganha o cupom, uma vez. Sem relação com avaliar; não registra nem exige avaliação.
create or replace function public.cupom_recompra_emitir(p_order uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare cfg jsonb; o public.orders%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select value into cfg from public.app_settings where key = 'cupom_recompra';
  if not coalesce((cfg ->> 'ativo')::boolean, false) then return jsonb_build_object('ok', true, 'emitido', false, 'motivo', 'desligado'); end if;
  select * into o from public.orders where id = p_order;
  if not found or o.payment_status <> 'aprovado' or o.delivered_at is null or coalesce(o.teste, false) then return jsonb_build_object('ok', true, 'emitido', false, 'motivo', 'pedido_nao_concluido'); end if;
  insert into public.cupons_recompra (contact_id, order_origem, percentual, valido_ate)
  values (o.contact_id, o.id, (cfg ->> 'percentual')::numeric, now() + make_interval(days => (cfg ->> 'validade_dias')::int))
  on conflict (contact_id) do nothing;
  return jsonb_build_object('ok', true, 'emitido', found);
end;
$$;
revoke execute on function public.cupom_recompra_emitir(uuid) from public, anon, authenticated;
grant execute on function public.cupom_recompra_emitir(uuid) to service_role;

-- Aplica o cupom ao orçamento: nunca passa de 5%, nunca consome mais que a fração da gordura acima do piso e é recusado pela trava de lucro.
create or replace function public.cupom_recompra_aplicar(p_orcamento uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  cfg jsonb; o public.orcamentos%rowtype; c public.cupons_recompra%rowtype; v_itens numeric; v_piso numeric; v_desc numeric; v_val jsonb;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select value into cfg from public.app_settings where key = 'cupom_recompra';
  if not coalesce((cfg ->> 'ativo')::boolean, false) then return jsonb_build_object('ok', true, 'aplicado', false, 'motivo', 'desligado'); end if;
  select * into o from public.orcamentos where id = p_orcamento;
  if not found or o.desconto_valor > 0 then return jsonb_build_object('ok', true, 'aplicado', false, 'motivo', 'orcamento_ja_tem_desconto'); end if;
  select * into c from public.cupons_recompra where contact_id = o.contact_id and usado_em is null and valido_ate > now();
  if not found then return jsonb_build_object('ok', true, 'aplicado', false, 'motivo', 'sem_cupom_valido'); end if;
  select coalesce(sum(quantidade * preco_unitario), 0), coalesce(sum(coalesce(piso, 0)), 0) into v_itens, v_piso from public.orcamento_itens where orcamento_id = p_orcamento;
  v_desc := floor(least(v_itens * c.percentual / 100, greatest(v_itens - v_piso, 0) * (cfg ->> 'fracao_gordura_max')::numeric) * 100) / 100;
  if v_desc < 5 then return jsonb_build_object('ok', true, 'aplicado', false, 'motivo', 'sem_margem_para_o_cupom'); end if;
  update public.orcamentos set desconto_valor = v_desc, total = total - v_desc where id = p_orcamento;
  v_val := public.validar_margem(p_orcamento);
  if v_val ->> 'status' <> 'ok' then
    update public.orcamentos set desconto_valor = 0, total = total + v_desc where id = p_orcamento;
    return jsonb_build_object('ok', true, 'aplicado', false, 'motivo', 'recusado_pela_trava_de_lucro');
  end if;
  update public.cupons_recompra set usado_em = now(), orcamento_id = p_orcamento, desconto_valor = v_desc where id = c.id;
  return jsonb_build_object('ok', true, 'aplicado', true, 'desconto', v_desc, 'texto_curto', 'Como cliente que já comprou com a gente, você tem um cupom de recompra nesta compra.');
end;
$$;
revoke execute on function public.cupom_recompra_aplicar(uuid) from public, anon, authenticated;
grant execute on function public.cupom_recompra_aplicar(uuid) to service_role;

-- Simulação de margem ANTES de ativar: o pior caso (cartão em 2x) com 5% de desconto sobre o preço de cada SKU amostrado
create or replace function public.cupom_recompra_simular(p_amostra integer default 300) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare cfg jsonb; r record; j jsonb; v_pct numeric; v_n int := 0; v_ok int := 0; v_sem int := 0; v_lucro_antes numeric := 0; v_lucro_depois numeric := 0; v_custo numeric; v_extra numeric; v_desc numeric; v_menor numeric := null; v_l numeric;
begin
  if not private.is_staff() and coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select value into cfg from public.app_settings where key = 'cupom_recompra';
  v_pct := coalesce((cfg ->> 'percentual')::numeric, 5);
  v_extra := private.custos_operacionais(null);
  for r in select c.sku, c.custo from public.catalogo c where c.vendavel and c.active and c.custo > 0 order by md5(c.sku) limit p_amostra loop
    j := public.calcular_preco(r.sku, 1, '{}'::jsonb);
    continue when not coalesce((j ->> 'ok')::boolean, false);
    v_n := v_n + 1;
    v_desc := floor(least((j ->> 'preco_total')::numeric * v_pct / 100, greatest((j ->> 'preco_total')::numeric - (j ->> 'piso')::numeric, 0) * (cfg ->> 'fracao_gordura_max')::numeric) * 100) / 100;
    if v_desc < 5 then v_sem := v_sem + 1; v_desc := 0; end if;
    v_l := private.lucro((j ->> 'preco_total')::numeric - v_desc, r.custo, v_extra, null);
    v_lucro_antes := v_lucro_antes + (j ->> 'lucro_liquido')::numeric; v_lucro_depois := v_lucro_depois + v_l;
    if v_l >= 0 then v_ok := v_ok + 1; end if;
    v_menor := least(coalesce(v_menor, v_l), v_l);
  end loop;
  return jsonb_build_object('amostra', v_n, 'sem_margem_para_o_cupom', v_sem, 'com_lucro_nao_negativo', v_ok, 'menor_lucro_no_pior_caso', v_menor,
    'lucro_medio_antes', round(v_lucro_antes / nullif(v_n, 0), 2), 'lucro_medio_depois', round(v_lucro_depois / nullif(v_n, 0), 2), 'percentual', v_pct,
    'leitura', 'O cupom só é concedido quando sobra gordura acima do piso (no máximo metade dela) e passa na trava de lucro. Para ligar: update app_settings set value = jsonb_set(value, ''{ativo}'', ''true'') where key = ''cupom_recompra''.');
end;
$$;
revoke execute on function public.cupom_recompra_simular(integer) from public, anon;
grant execute on function public.cupom_recompra_simular(integer) to authenticated, service_role;
