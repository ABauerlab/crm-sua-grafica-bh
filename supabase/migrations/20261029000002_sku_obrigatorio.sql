-- Agente de IA, Etapa 2 (2/3): SKU obrigatório em orçamento, pedido e kit; item fora do catálogo chama o dono.
-- Registros antigos ficam isentos (NOT VALID); só os novos são checados.

-- ---------------------------------------------------------------- 1. chaves estrangeiras para catalogo.sku
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'orcamento_itens_sku_fk') then
    alter table public.orcamento_itens add constraint orcamento_itens_sku_fk foreign key (sku) references public.catalogo (sku) not valid;
  end if;
  -- no pedido o SKU mora em order_items.code (nome antigo, mantido); null passa na chave, quem barra é o gatilho abaixo
  if not exists (select 1 from pg_constraint where conname = 'order_items_code_sku_fk') then
    alter table public.order_items add constraint order_items_code_sku_fk foreign key (code) references public.catalogo (sku) not valid;
  end if;
end $$;
create index if not exists order_items_code_idx on public.order_items (code);
create index if not exists orcamento_itens_sku_idx on public.orcamento_itens (sku);

-- kits passam a ser listas de SKUs
alter table public.kit_items add column if not exists sku text references public.catalogo (sku);
update public.kit_items k set sku = c.sku from public.catalogo c where k.product_id = c.id and k.sku is null and c.sku is not null;
create or replace view public.kit_itens with (security_invoker = true) as
select id, kit_id, sku, description as descricao, qty as quantidade from public.kit_items;
revoke all on public.kit_itens from anon;

-- ---------------------------------------------------------------- 2. orçamento: SKU existente e vendável, preço acima do piso duro
create or replace function private.orcamento_itens_validar() returns trigger
language plpgsql set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_cost numeric; v_vendavel boolean;
  v_pct numeric;
begin
  if new.sku is null or btrim(new.sku) = '' then
    raise exception 'Item sem SKU não pode entrar no orçamento.' using errcode = 'P0001';
  end if;
  select c.custo, c.vendavel and c.active into v_cost, v_vendavel from public.catalogo c where c.sku = new.sku;
  if not found then
    raise exception 'SKU % não existe no catálogo.', new.sku using errcode = 'P0001';
  end if;
  if not v_vendavel then
    raise exception 'O SKU % não está disponível para venda.', new.sku using errcode = 'P0001';
  end if;
  select * into pr from public.parametros_comerciais where id = 1;
  v_pct := (private.taxa_pagamento(null) ->> 'pct')::numeric;
  if new.preco_unitario * new.quantidade * (1 - pr.imposto_pct / 100 - v_pct / 100) < v_cost * new.quantidade then
    raise exception 'Preço abaixo do piso duro: o item daria prejuízo. Ajuste o preço.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------- 3. pedido: SKU obrigatório (liga o parâmetro da Etapa 1) e produção só com SKU em tudo
update public.parametros_comerciais set exigir_sku_pedidos = true where id = 1;

-- Item fora do catálogo: guarda o que o cliente pediu, chama o dono (gravidade alta) e o item fica sem_sku.
create table if not exists public.itens_fora_catalogo (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid references public.contacts (id) on delete set null,
  conversation_id uuid references public.conversations (id) on delete set null,
  descricao text not null,
  quantidade integer,
  detalhe jsonb not null default '{}'::jsonb,
  status text not null default 'sem_sku' check (status in ('sem_sku', 'resolvido', 'descartado')),
  sku_resolvido text references public.catalogo (sku),
  alerta_id uuid references public.alertas (id) on delete set null,
  criado_em timestamptz not null default now(),
  resolvido_em timestamptz
);
create index if not exists itens_fora_catalogo_status_idx on public.itens_fora_catalogo (status, criado_em desc);
alter table public.itens_fora_catalogo enable row level security;
revoke all on public.itens_fora_catalogo from anon;
drop policy if exists itens_fora_catalogo_dono on public.itens_fora_catalogo;
create policy itens_fora_catalogo_dono on public.itens_fora_catalogo for all to authenticated using (private.is_staff()) with check (private.is_staff());

-- Cria o alerta alto (uma vez a cada 30 minutos por conversa e tipo)
create or replace function private.alerta_item_sem_sku(p_conv uuid, p_contact uuid, p_order uuid, p_motivo text) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if p_conv is not null and exists (select 1 from public.alertas where conversation_id = p_conv and tipo = 'item_sem_sku' and criado_em > now() - interval '30 minutes') then
    return null;
  end if;
  insert into public.alertas (tipo, gravidade, contact_id, conversation_id, order_id, motivo)
  values ('item_sem_sku', 'alta', p_contact, p_conv, p_order, p_motivo) returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function private.alerta_item_sem_sku(uuid, uuid, uuid, text) from public, anon, authenticated;

-- Ferramenta do agente: registrar_item_sem_sku (o n8n chama com a service role). Não monta orçamento nem manda link.
create or replace function public.registrar_item_sem_sku(p_conversation uuid, p_descricao text, p_quantidade integer default null, p_detalhe jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_contact uuid; v_alerta uuid; v_id uuid;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select contact_id into v_contact from public.conversations where id = p_conversation;
  v_alerta := private.alerta_item_sem_sku(p_conversation, v_contact, null, left('Pedido fora do catálogo ou sem SKU: ' || coalesce(p_descricao, ''), 300));
  insert into public.itens_fora_catalogo (contact_id, conversation_id, descricao, quantidade, detalhe, alerta_id)
  values (v_contact, p_conversation, left(p_descricao, 300), p_quantidade, coalesce(p_detalhe, '{}'::jsonb), v_alerta) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'dono_avisado', v_alerta is not null, 'orientacao', 'nao_montar_orcamento_nem_enviar_link');
end;
$$;
revoke execute on function public.registrar_item_sem_sku(uuid, text, integer, jsonb) from public, anon;

-- Regras de transição: igual à versão da Fase 1, mais (a) Produção exige SKU em todos os itens, (b) pedido pago com item sem SKU alerta o dono.
-- O pagamento confirmado NUNCA é bloqueado (a trava de Pago continua só olhando o pagamento).
create or replace function private.orders_before_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sem_sku integer;
begin
  new.updated_at := now();

  if new.payment_status = 'aprovado' and old.payment_status is distinct from 'aprovado' then
    new.paid_at := coalesce(new.paid_at, now());
    new.payment_confirmed_at := coalesce(new.payment_confirmed_at, now());
  end if;
  if new.art_status = 'aprovada' and old.art_status is distinct from 'aprovada' then
    new.art_approved_at := coalesce(new.art_approved_at, now());
  end if;

  if new.stage is distinct from old.stage then
    if new.stage = 'pago' and new.payment_status <> 'aprovado' and not new.payment_manual then
      raise exception 'Só é possível mover para Pago com o pagamento confirmado. Confirme o pagamento manualmente se já recebeu.' using errcode = 'P0001';
    end if;
    if new.stage in ('pago', 'producao') then
      select count(*) into v_sem_sku from public.order_items i where i.order_id = new.id and (i.code is null or btrim(i.code) = '');
    end if;
    if new.stage = 'producao' and v_sem_sku > 0 then
      raise exception 'Há % item(ns) sem SKU. Informe o SKU do fornecedor antes de mandar para Produção.', v_sem_sku using errcode = 'P0001';
    end if;
    if new.stage = 'pago' and v_sem_sku > 0 then
      perform private.alerta_item_sem_sku(new.conversation_id, new.contact_id, new.id, 'Pedido pago com item sem SKU: informe o código para poder produzir.');
    end if;
    if new.stage = 'producao' and new.art_status <> 'aprovada' then
      raise exception 'Só é possível mover para Produção com a arte aprovada pelo cliente.' using errcode = 'P0001';
    end if;
    new.stage_entered_at := now();
    if new.stage = 'entregue' and new.delivered_at is null then
      new.delivered_at := now();
    end if;
  end if;
  return new;
end;
$$;

-- Pedido para a fábrica: tudo o que se manda ao fornecedor, de um pedido pago (só o dono; contém SKU, que é interno)
create or replace function public.pedido_para_fabrica(p_order uuid)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
declare o record; v_itens jsonb; v_arte jsonb;
begin
  select ord.id, ord.title, ord.stage, ord.due_date, ord.art_status, ord.payment_status, ord.payment_manual, ord.delivery_method,
         ct.name as nome, ct.wa_id, ct.bairro
    into o from public.orders ord left join public.contacts ct on ct.id = ord.contact_id where ord.id = p_order;
  if not found then return jsonb_build_object('ok', false, 'erro', 'pedido_nao_encontrado'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', i.code, 'quantidade_pedida', i.qty, 'descricao', i.description,
           'especificacao', concat_ws(' · ', c.categoria, c.cores, c.tamanho_mm, case when c.gramatura_g is not null then c.gramatura_g || ' g' end, case when c.quantidade is not null then c.quantidade || ' un' end),
           'prazo_dias_uteis', coalesce(i.lead_days, c.prazo_dias_uteis)) order by i.created_at), '[]'::jsonb)
    into v_itens from public.order_items i left join public.catalogo c on c.sku = i.code where i.order_id = p_order;
  select coalesce(jsonb_agg(jsonb_build_object('arquivo', f.filename, 'path', f.path, 'versao', f.version) order by f.version), '[]'::jsonb)
    into v_arte from public.order_files f where f.order_id = p_order and f.kind in ('arte', 'prova') and f.status = 'aprovada';
  return jsonb_build_object('ok', true, 'pedido', o.title, 'etapa', o.stage, 'pronto_ate', o.due_date, 'arte_status', o.art_status,
    'pago', o.payment_status = 'aprovado' or o.payment_manual, 'entrega', o.delivery_method,
    'cliente', jsonb_build_object('nome', o.nome, 'whatsapp', o.wa_id, 'bairro', o.bairro), 'itens', v_itens, 'arquivos_arte_aprovada', v_arte,
    'itens_sem_sku', (select count(*) from public.order_items x where x.order_id = p_order and (x.code is null or btrim(x.code) = '')));
end;
$$;
revoke execute on function public.pedido_para_fabrica(uuid) from public, anon;

-- Preço de um kit a partir dos SKUs dele, pela mesma fórmula (calcular_preco). Nunca abaixo do piso do conjunto.
-- A Etapa 3 refina o preço do conjunto (lucro mínimo uma vez só, e não por item). Hoje vale a soma dos itens, que é sempre segura.
create or replace function public.kit_preco(p_kit uuid)
returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
declare
  it record; j jsonb; v_total numeric := 0; v_custo numeric := 0; v_itens jsonb := '[]'::jsonb; v_sem integer := 0;
  pr public.parametros_comerciais%rowtype; v_piso_conjunto numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  for it in select k.sku, k.qty, k.description from public.kit_items k where k.kit_id = p_kit loop
    if it.sku is null then v_sem := v_sem + 1; continue; end if;
    j := public.calcular_preco(it.sku, 1, '{}'::jsonb);
    if not coalesce((j ->> 'ok')::boolean, false) then v_sem := v_sem + 1; continue; end if;
    v_total := v_total + (j ->> 'preco_total')::numeric * it.qty;
    v_custo := v_custo + (select c.custo from public.catalogo c where c.sku = it.sku) * it.qty;
    v_itens := v_itens || jsonb_build_array(jsonb_build_object('sku', it.sku, 'quantidade', it.qty, 'preco', (j ->> 'preco_total')::numeric));
  end loop;
  v_piso_conjunto := ceil(greatest(v_custo * pr.multiplicador_piso, private.receita_para_lucro(v_custo, private.custos_operacionais(null), pr.lucro_liquido_minimo, null)) * 100) / 100;
  return jsonb_build_object('ok', true, 'preco', greatest(v_total, v_piso_conjunto), 'itens', v_itens, 'itens_sem_sku', v_sem,
    'abaixo_do_piso_conjunto', v_total < v_piso_conjunto);
end;
$$;
revoke execute on function public.kit_preco(uuid) from public, anon;
