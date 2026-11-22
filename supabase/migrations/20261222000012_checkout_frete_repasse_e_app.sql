-- 22/11/2026: checkout, escolha de entrega falhava com "Não conseguimos carregar agora".
-- Causa raiz: o frete entra no pedido como repasse (custo = valor) e o gatilho order_items_validar barrava a linha como
-- "abaixo do piso duro" (valor x (1 - imposto - taxa) < custo), então QUALQUER frete pago dava erro P0001.
-- Correção: a trava de piso não se aplica à linha de frete do checkout (checkout_extra + descrição "Frete"); ela segue valendo para produtos e arte.
-- Entrega por aplicativo: o valor é calculado na hora da entrega, então entra no pedido a R$ 0,00 e o total não muda.

create or replace function private.order_items_validar()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare
  pr public.parametros_comerciais%rowtype;
  v_pct numeric;
  v_custo_cat numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  if pr.exigir_sku_pedidos and not new.fora_catalogo and tg_op = 'INSERT' and (new.code is null or btrim(new.code) = '') then
    raise exception 'Item sem SKU não pode entrar no pedido. Marque "item fora do catálogo" se for um item manual.' using errcode = 'P0001';
  end if;

  if new.code is not null and not new.fora_catalogo and coalesce(new.unit_cost, 0) <= 0 then
    select c.custo into v_custo_cat from public.catalogo c where c.sku = new.code and c.active;
    if v_custo_cat is not null then
      new.unit_cost := v_custo_cat;
    end if;
  end if;

  -- Frete do checkout é repasse (custo = valor): não é mercadoria, não passa pela trava de piso.
  if coalesce(new.checkout_extra, false) and new.description ~* '^frete' then
    return new;
  end if;

  if new.unit_price > 0 and (tg_op = 'INSERT' or new.unit_price is distinct from old.unit_price or new.unit_cost is distinct from old.unit_cost or new.qty is distinct from old.qty) then
    v_pct := (private.taxa_pagamento(null) ->> 'pct')::numeric;
    if coalesce(current_setting('gbh.preco_aprovado', true), '') <> 'on' and not private.is_staff() then
      if new.unit_cost > 0 and new.unit_price * (1 - pr.imposto_pct / 100 - v_pct / 100) < new.unit_cost then
        raise exception 'Preço abaixo do piso duro (%): o item daria prejuízo.', private.brl(round(new.unit_cost / (1 - pr.imposto_pct / 100 - v_pct / 100), 2))
          using errcode = 'P0001';
      end if;
    end if;
  end if;
  return new;
end;
$function$;

-- Frete: valor 0 com nome "aplicativo" grava a escolha sem cobrar agora.
create or replace function public.checkout_definir_frete(
  p_token text, p_valor numeric, p_nome text, p_prazo_dias integer, p_cep text, p_endereco jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_link timestamptz; v_cep text := regexp_replace(coalesce(p_cep, ''), '\D', '', 'g'); v_desc text; v_app boolean := coalesce(p_nome, '') ~* 'aplicativo';
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  if o.payment_status = 'aprovado' then return jsonb_build_object('ok', false, 'erro', 'pedido_ja_pago'); end if;
  select expira_em into v_link from public.pagamentos where order_id = o.id and eh_link and link_ativo order by criado_em desc limit 1;
  if v_link is null or v_link <= now() then return jsonb_build_object('ok', false, 'erro', 'link_expirado'); end if;
  if v_cep !~ '^[0-9]{8}$' then return jsonb_build_object('ok', false, 'erro', 'cep_invalido'); end if;
  if p_valor is null or p_valor < 0 or p_valor > 1500 then return jsonb_build_object('ok', false, 'erro', 'frete_invalido'); end if;
  delete from public.order_items where order_id = o.id and description ~* '^frete';
  if v_app then
    insert into public.order_items (order_id, code, fora_catalogo, description, qty, unit_cost, unit_price, checkout_extra)
    values (o.id, null, true, 'Frete entrega por aplicativo · valor calculado na hora da entrega', 1, 0, 0, true);
  elsif p_valor > 0 then
    v_desc := 'Frete Correios ' || left(coalesce(nullif(btrim(regexp_replace(coalesce(p_nome, ''), '\s*\(Correios\)', '', 'gi')), ''), 'envio'), 40) || coalesce(' · prazo de ' || p_prazo_dias || ' dias úteis', '');
    insert into public.order_items (order_id, code, fora_catalogo, description, qty, unit_cost, unit_price, checkout_extra)
    values (o.id, null, true, v_desc, 1, p_valor, p_valor, true);
  end if;
  update public.contacts set cep = coalesce(nullif(cep, ''), v_cep),
         logradouro = coalesce(nullif(logradouro, ''), nullif(left(p_endereco ->> 'logradouro', 120), '')),
         bairro = coalesce(nullif(bairro, ''), nullif(left(p_endereco ->> 'bairro', 80), '')),
         municipio = coalesce(nullif(municipio, ''), nullif(left(p_endereco ->> 'cidade', 80), '')),
         uf = coalesce(nullif(uf, ''), nullif(left(upper(p_endereco ->> 'uf'), 2), ''))
   where id = o.contact_id;
  perform private.checkout_sincronizar_orcamento(o.id);
  insert into public.order_events (order_id, kind, message) values (o.id, 'price', case
    when v_app then 'Cliente escolheu entrega por aplicativo no checkout: o valor é calculado na hora da entrega (não entrou no pagamento).'
    when p_valor > 0 then 'Cliente escolheu frete no checkout: R$ ' || to_char(p_valor, 'FM999990D00') || '.'
    else 'Frete removido no checkout (retirada ou entrega grátis).' end);
  perform private.checkout_evento(o.id, 'frete_definido', jsonb_build_object('valor', p_valor, 'aplicativo', v_app));
  return jsonb_build_object('ok', true, 'total', (select total from public.order_financials where order_id = o.id));
end;
$$;

-- checkout_carregar: texto da entrega conforme a escolha (Correios x aplicativo)
create or replace function public.checkout_carregar(p_token text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r jsonb; o public.orders%rowtype; v_frete record; v_pct numeric;
begin
  r := private.checkout_carregar_base(p_token);
  if not coalesce((r ->> 'ok')::boolean, false) then return r; end if;
  o := private.checkout_pedido(p_token);
  select id, unit_price, description into v_frete from public.order_items where order_id = o.id and description ~* '^frete' limit 1;
  r := jsonb_set(r, '{itens}', coalesce((select jsonb_agg(case when e ->> 'descricao' ~* '^frete' then e || jsonb_build_object('tipo', 'frete') else e end) from jsonb_array_elements(r -> 'itens') e), '[]'::jsonb));
  v_pct := coalesce(o.discount_pct, 0);
  r := r || jsonb_build_object(
    'cupom', case when o.cupom_codigo is not null then jsonb_build_object('codigo', o.cupom_codigo, 'percentual', v_pct) end,
    'frete', jsonb_build_object('valor', coalesce(v_frete.unit_price, 0), 'descricao', v_frete.description, 'aplicativo', coalesce(v_frete.description ~* 'aplicativo', false), 'cep_final', right(regexp_replace(coalesce((select cep from public.contacts where id = o.contact_id), ''), '\D', '', 'g'), 3)));
  if v_frete.id is not null then
    r := jsonb_set(r, '{entrega}', jsonb_build_object('texto', case when v_frete.description ~* 'aplicativo' then 'Entrega por aplicativo, valor combinado na hora da entrega' else 'Envio pelos Correios' end, 'frete_gratis', false));
    r := r || jsonb_build_object('subtotal', round((r ->> 'subtotal')::numeric - v_frete.unit_price, 2));
  end if;
  return r;
end;
$$;

-- O orçamento (PDF) já ignora a linha "Frete Correios"; a linha do aplicativo (R$ 0,00) também não pode entrar lá.
do $m$
declare d text := pg_get_functiondef('private.checkout_sincronizar_orcamento(uuid)'::regprocedure);
begin
  if d like '%^frete correios%' and d not like '%entrega por aplicativo%' then
    execute replace(d, '^frete correios', '^frete (correios|entrega por aplicativo)');
  end if;
end $m$;
