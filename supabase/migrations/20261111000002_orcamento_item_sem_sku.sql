-- Itens sem SKU (manuais) entram no orçamento. O custo unitário vem do pedido (order_items.unit_cost)
-- e fica gravado em orcamento_itens.custo_unitario, para a trava de piso e o cálculo de lucro continuarem valendo.
-- Pedido sem orçamento ativo ganha um rascunho automaticamente ao sincronizar (assim o PDF existe para pedido novo).
-- Aditiva e idempotente: solta NOT NULL do sku, cria a regra "sku ou custo" e recria as funções.

-- A coluna já existia em produção (criada fora do repositório); if not exists deixa o banco local igual.
alter table public.orcamento_itens add column if not exists custo_unitario numeric;
alter table public.orcamento_itens alter column sku drop not null;

alter table public.orcamento_itens drop constraint if exists orcamento_itens_sku_ou_custo;
alter table public.orcamento_itens add constraint orcamento_itens_sku_ou_custo
  check (sku is not null or custo_unitario is not null);

-- Validação do item: com SKU segue o catálogo; sem SKU usa o custo gravado no item (piso duro igual).
create or replace function private.orcamento_itens_validar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_cost numeric; v_vendavel boolean;
  v_pct numeric;
begin
  new.sku := nullif(btrim(new.sku), '');
  if new.sku is null then
    if new.custo_unitario is null or new.custo_unitario < 0 then
      raise exception 'Item sem SKU precisa de custo unitário.' using errcode = 'P0001';
    end if;
    v_cost := new.custo_unitario;
  else
    select c.custo, c.vendavel and c.active into v_cost, v_vendavel from public.catalogo c where c.sku = new.sku;
    if not found then
      raise exception 'SKU % não existe no catálogo.', new.sku using errcode = 'P0001';
    end if;
    if not v_vendavel then
      raise exception 'O SKU % não está disponível para venda.', new.sku using errcode = 'P0001';
    end if;
  end if;
  select * into pr from public.parametros_comerciais where id = 1;
  v_pct := (private.taxa_pagamento(null) ->> 'pct')::numeric;
  if new.preco_unitario * new.quantidade * (1 - pr.imposto_pct / 100 - v_pct / 100) < v_cost * new.quantidade then
    raise exception 'Preço abaixo do piso duro: o item daria prejuízo. Ajuste o preço.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- Custo: catálogo quando há SKU; custo gravado no item quando é manual.
create or replace function private.orcamento_financeiro(p_orcamento uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  o public.orcamentos%rowtype;
  pr public.parametros_comerciais%rowtype;
  v_n integer; v_sub numeric; v_custo numeric; v_sem_produto integer;
  v_extra numeric; v_receita numeric; v_itens_liq numeric;
  v_entrega_nossa text;
begin
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return null; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  select count(*), coalesce(sum(i.quantidade * i.preco_unitario), 0),
         coalesce(sum(coalesce(case when i.sku is null then i.custo_unitario end, p.cost) * i.quantidade), 0),
         count(*) filter (where i.sku is not null and p.code is null)
    into v_n, v_sub, v_custo, v_sem_produto
  from public.orcamento_itens i left join public.products p on p.code = i.sku
  where i.orcamento_id = p_orcamento;
  v_entrega_nossa := case when o.frete_valor = 0 and o.entrega in ('bike', 'uber') then o.entrega else null end;
  v_extra := private.custos_operacionais(v_entrega_nossa);
  v_itens_liq := v_sub - o.desconto_valor;
  v_receita := v_itens_liq + o.arte_valor + o.frete_valor;
  return jsonb_build_object(
    'itens', v_n, 'itens_sem_produto', v_sem_produto, 'subtotal', v_sub, 'custo', v_custo, 'extra', v_extra,
    'receita_itens_liquida', v_itens_liq, 'receita', v_receita,
    'lucro', private.lucro(v_receita, v_custo, v_extra, o.metodo_previsto),
    'receita_piso_duro', private.receita_para_lucro(v_custo, v_extra, 0, o.metodo_previsto),
    'receita_piso', private.receita_para_lucro(v_custo, v_extra, pr.lucro_liquido_minimo, o.metodo_previsto));
end;
$$;

-- PDF: itens sem SKU não entram no cálculo de prazo (só os itens do catálogo têm prazo do fornecedor).
create or replace function public.orcamento_documento(p_orcamento uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.orcamentos%rowtype; pr public.parametros_comerciais%rowtype;
  v_cli text; v_emp jsonb; v_itens jsonb; v_cond record; v_cond_json jsonb := null;
  v_pronto date; v_frase text; pz jsonb; s text; v_versao integer; v_doc jsonb; v_opc jsonb := null;
  v_skus text[]; v_vencido boolean; v_inicio date; v_exib numeric;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return null; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  select coalesce(nullif(btrim(c.name), ''), 'Cliente') into v_cli from public.contacts c where c.id = o.contact_id;
  select value into v_emp from public.app_settings where key = 'company';

  select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'especificacao', i.especificacao, 'quantidade', i.quantidade,
                                               'valor_unitario', i.preco_unitario, 'valor_total', round(i.quantidade * i.preco_unitario, 2)) order by i.criado_em, i.id), '[]'::jsonb),
         array_agg(i.sku) filter (where i.sku is not null)
    into v_itens, v_skus from public.orcamento_itens i where i.orcamento_id = p_orcamento;

  if o.itens_exibicao is not null then
    select coalesce(sum((e ->> 'valor_total')::numeric), 0) into v_exib from jsonb_array_elements(o.itens_exibicao) e;
    if round(v_exib, 2) = round(coalesce(o.subtotal, 0), 2) then v_itens := o.itens_exibicao; end if;
  end if;

  foreach s in array coalesce(v_skus, '{}') loop
    pz := public.calcular_prazo(s, now(), false);
    if coalesce((pz ->> 'ok')::boolean, false) and (v_pronto is null or (pz ->> 'data_pronto')::date > v_pronto) then
      v_pronto := (pz ->> 'data_pronto')::date; v_frase := pz ->> 'frase'; v_inicio := (pz ->> 'inicio_contagem')::date;
    end if;
  end loop;

  select c.valida_ate, c.tipo, c.texto_curto into v_cond from public.condicoes_especiais c
   where c.orcamento_novo_id = p_orcamento and c.resultado in ('oferecida', 'aceita') order by c.criado_em desc limit 1;
  if found then
    v_cond_json := jsonb_build_object('valida_ate', v_cond.valida_ate, 'tipo', v_cond.tipo, 'total', o.total,
                                      'texto', case v_cond.tipo when 'arte_gratis' then 'Arte grátis neste pedido'
                                                                when 'frete_gratis' then 'Frete grátis neste pedido'
                                                                else 'Desconto especial já aplicado ao total' end);
  end if;

  if o.arte_modo = 'nenhuma' then
    v_opc := jsonb_build_array(
      jsonb_build_object('texto', 'Só a arte', 'valor', pr.arte_valor),
      jsonb_build_object('texto', 'Arte com frete grátis na região central', 'valor', pr.arte_frete_valor));
  end if;

  with recursive cadeia as (select id, origem_id from public.orcamentos where id = p_orcamento
                            union all select p.id, p.origem_id from public.orcamentos p join cadeia c on p.id = c.origem_id)
  select count(*) into v_versao from cadeia;
  v_vencido := o.validade_ate is not null and o.validade_ate < now();

  v_doc := jsonb_build_object(
    'numero', private.orcamento_numero(o.numero), 'versao', v_versao,
    'data', (o.criado_em at time zone 'America/Sao_Paulo')::date,
    'validade_ate', o.validade_ate,
    'cliente', jsonb_build_object('nome', v_cli),
    'itens', v_itens, 'subtotal', o.subtotal,
    'arte', jsonb_build_object('modo', o.arte_modo, 'valor', o.arte_valor, 'opcoes', v_opc),
    'frete', jsonb_build_object('modo', o.frete_modo, 'valor', o.frete_valor),
    'desconto', o.desconto_valor, 'total', o.total,
    'condicao_especial', v_cond_json,
    'data_prevista', v_pronto, 'prazo_frase', v_frase, 'prazo_inicio', v_inicio,
    'hoje', (now() at time zone 'America/Sao_Paulo')::date, 'corte_hora', pr.corte_producao_hora,
    'upsell', case when o.upsell_texto is not null then jsonb_build_object('tipo', o.upsell_tipo, 'texto', o.upsell_texto) end,
    'alternativas', o.alternativas,
    'empresa', jsonb_build_object(
      'nome', coalesce(v_emp ->> 'name', 'Sua Gráfica BH'), 'cnpj', coalesce(v_emp ->> 'cnpj', '58.481.181/0001-03'),
      'telefone', nullif(v_emp ->> 'phone', ''), 'email', nullif(v_emp ->> 'email', ''),
      'instagram', nullif(v_emp ->> 'instagram', ''), 'site', nullif(v_emp ->> 'site', '')));
  return v_doc || jsonb_build_object('hash', md5(v_doc::text), 'vencido', v_vencido, 'status', o.status);
end;
$$;

-- Sincroniza itens do pedido com o orçamento ativo. Sem orçamento ativo, cria um rascunho (pedido com itens e não pago).
-- Tudo ou nada: se um item for recusado (piso duro, SKU inválido), nada muda.
create or replace function public.pedido_sincronizar_orcamento(p_order uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  o public.orcamentos%rowtype;
  v_ped public.orders%rowtype;
  v_itens integer;
  v_bruto numeric;
  v_desc_pct numeric;
  v_criado boolean := false;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;

  select * into v_ped from public.orders where id = p_order;
  if not found then raise exception 'Pedido não encontrado.' using errcode = 'P0001'; end if;

  select count(*) into v_itens from public.order_items where order_id = p_order;

  select * into o from public.orcamentos
   where order_id = p_order and status in ('rascunho', 'enviado', 'aceito')
   order by criado_em desc limit 1;
  if not found then
    if v_itens = 0 or v_ped.paid_at is not null or v_ped.payment_confirmed_at is not null
       or v_ped.cancelado_em is not null or v_ped.excluido_em is not null then
      return jsonb_build_object('ok', true, 'sincronizado', false, 'motivo', 'sem_orcamento_ativo');
    end if;
    insert into public.orcamentos (contact_id, order_id, conversation_id, status, teste)
    values (v_ped.contact_id, p_order, v_ped.conversation_id, 'rascunho', v_ped.teste)
    returning * into o;
    v_criado := true;
  end if;

  delete from public.orcamento_itens where orcamento_id = o.id;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, custo_unitario)
  select o.id, nullif(btrim(oi.code), ''), oi.description, oi.qty, oi.unit_price, oi.unit_cost
    from public.order_items oi
   where oi.order_id = p_order;

  select coalesce(sum(oi.qty * oi.unit_price), 0), coalesce(max(o2.discount_pct), 0)
    into v_bruto, v_desc_pct
    from public.order_items oi join public.orders o2 on o2.id = oi.order_id
   where oi.order_id = p_order;

  -- Desconto do pedido vira desconto do orçamento; a exibição agrupada antiga sai (o PDF volta a listar os itens reais)
  update public.orcamentos
     set desconto_valor = round(v_bruto * v_desc_pct / 100, 2), itens_exibicao = null
   where id = o.id;

  return jsonb_build_object('ok', true, 'sincronizado', true, 'criado', v_criado, 'orcamento_id', o.id, 'itens', v_itens);
end;
$$;

revoke execute on function public.pedido_sincronizar_orcamento(uuid) from public, anon;
grant execute on function public.pedido_sincronizar_orcamento(uuid) to authenticated, service_role;
