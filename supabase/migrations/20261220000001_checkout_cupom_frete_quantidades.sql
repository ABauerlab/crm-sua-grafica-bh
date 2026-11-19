-- 19/11/2026: checkout próprio (/pagar/<token>): cupom, frete pelo CEP, tiragens que não somem e unidades por item.
-- Aditiva e idempotente. Tudo só pela service role (Edge Function checkout-dados). Nada de custo, piso ou fornecedor na resposta.

-- 1) Tiragens: mostra SEMPRE todas as opções do mesmo produto e versão (antes a janela andava junto com a opção escolhida
--    e as outras sumiam ao clicar). Ordem fixa por quantidade, a escolhida marcada.
create or replace function private.checkout_quantidades(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare it record; cur record; v_out jsonb := '[]'::jsonb; v_ops jsonb;
begin
  for it in select oi.id, oi.code, oi.qty, oi.description from public.order_items oi
             where oi.order_id = p_order and oi.code is not null and oi.qty = 1 and oi.description !~* '^frete' order by oi.created_at limit 3 loop
    select e.produto_slug, e.variante, e.quantidade into cur from public.ecommerce_products e where e.sku = it.code;
    if not found or cur.quantidade is null then continue; end if;
    select coalesce(jsonb_agg(jsonb_build_object('ref', x.ref, 'quantidade', x.quantidade, 'preco', x.preco, 'unitario', round(x.preco / nullif(x.quantidade, 0), 3),
                    'atual', x.sku = it.code) order by x.quantidade), '[]'::jsonb) into v_ops
      from (select e.ref, e.sku, e.quantidade, e.preco from public.ecommerce_products e
             where e.produto_slug = cur.produto_slug and e.variante is not distinct from cur.variante and e.ativo and e.preco > 0 and e.quantidade is not null
             order by e.quantidade limit 24) x;
    if jsonb_array_length(v_ops) >= 2 then
      v_out := v_out || jsonb_build_array(jsonb_build_object('item_id', it.id, 'descricao', it.description, 'opcoes', v_ops));
    end if;
  end loop;
  return v_out;
end;
$$;
revoke all on function private.checkout_quantidades(uuid) from public, anon, authenticated;

-- 2) Cupons do checkout (ex.: cupom do panfleto de pós-venda). Cadastro pelo dono; o banco confere validade, uso e lucro.
create table if not exists public.cupons_checkout (
  codigo text primary key check (codigo = upper(codigo) and codigo ~ '^[A-Z0-9_-]{3,30}$'),
  percentual numeric(5, 2) not null check (percentual > 0 and percentual <= 30),
  ativo boolean not null default true,
  validade_ate timestamptz,
  usos_max integer check (usos_max is null or usos_max > 0),
  usos integer not null default 0,
  um_por_contato boolean not null default true,
  descricao text,
  criado_em timestamptz not null default now()
);
create table if not exists public.cupons_checkout_uso (
  id uuid primary key default gen_random_uuid(),
  codigo text not null references public.cupons_checkout (codigo),
  order_id uuid not null references public.orders (id) on delete cascade,
  contact_id uuid,
  criado_em timestamptz not null default now(),
  unique (order_id)
);
alter table public.cupons_checkout enable row level security;
alter table public.cupons_checkout_uso enable row level security;
revoke all on public.cupons_checkout, public.cupons_checkout_uso from anon;
drop policy if exists cupons_checkout_dono on public.cupons_checkout;
create policy cupons_checkout_dono on public.cupons_checkout for all to authenticated using (private.is_admin()) with check (private.is_admin());
drop policy if exists cupons_checkout_uso_dono on public.cupons_checkout_uso;
create policy cupons_checkout_uso_dono on public.cupons_checkout_uso for select to authenticated using (private.is_staff());
insert into public.cupons_checkout (codigo, percentual, descricao) values ('VOLTEI5', 5, 'Cupom de quem voltou a comprar (5%)') on conflict (codigo) do nothing;
alter table public.orders add column if not exists cupom_codigo text;

-- Um item de frete é repasse (custo = valor): nunca entra na conta de lucro do cupom nem nas tiragens.
create or replace function public.checkout_aplicar_cupom(p_token text, p_codigo text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orders%rowtype; cp public.cupons_checkout%rowtype; pr public.parametros_comerciais%rowtype;
  v_cod text := upper(btrim(coalesce(p_codigo, ''))); v_base numeric; v_custo numeric; v_liq numeric; v_link timestamptz;
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  if o.payment_status = 'aprovado' then return jsonb_build_object('ok', false, 'erro', 'pedido_ja_pago'); end if;
  select expira_em into v_link from public.pagamentos where order_id = o.id and eh_link and link_ativo order by criado_em desc limit 1;
  if v_link is null or v_link <= now() then return jsonb_build_object('ok', false, 'erro', 'link_expirado'); end if;
  if (select count(*) from public.checkout_eventos where order_id = o.id and tipo = 'cupom_tentativa' and criado_em > now() - interval '10 minutes') >= 8 then
    return jsonb_build_object('ok', false, 'erro', 'muitas_tentativas', 'mensagem', 'Muitas tentativas. Aguarde alguns minutos.');
  end if;
  perform private.checkout_evento(o.id, 'cupom_tentativa', '{}'::jsonb);
  if v_cod = '' then return jsonb_build_object('ok', false, 'erro', 'cupom_invalido', 'mensagem', 'Digite o código do cupom.'); end if;
  select * into cp from public.cupons_checkout where codigo = v_cod and ativo and (validade_ate is null or validade_ate > now());
  if not found or (cp.usos_max is not null and cp.usos >= cp.usos_max) then
    return jsonb_build_object('ok', false, 'erro', 'cupom_invalido', 'mensagem', 'Cupom inválido ou vencido. Confira o código.');
  end if;
  if o.cupom_codigo = v_cod then return jsonb_build_object('ok', true, 'sem_mudanca', true); end if;
  if o.cupom_codigo is null and coalesce(o.discount_pct, 0) > 0 then
    return jsonb_build_object('ok', false, 'erro', 'ja_tem_desconto', 'mensagem', 'Este pedido já tem uma condição especial. Os descontos não se somam.');
  end if;
  if cp.um_por_contato and exists (select 1 from public.cupons_checkout_uso u where u.codigo = v_cod and u.contact_id = o.contact_id and u.order_id <> o.id) then
    return jsonb_build_object('ok', false, 'erro', 'cupom_ja_usado', 'mensagem', 'Este cupom já foi usado neste cadastro.');
  end if;
  -- trava de lucro: sobre produtos e arte (frete é repasse), nunca abaixo do piso nem do lucro bruto mínimo
  select * into pr from public.parametros_comerciais where id = 1;
  select coalesce(sum(qty * unit_price), 0), coalesce(sum(qty * unit_cost), 0) into v_base, v_custo from public.order_items where order_id = o.id and description !~* '^frete';
  v_liq := round(v_base * (1 - cp.percentual / 100), 2);
  if v_liq < round(v_custo * pr.multiplicador_piso, 2) or (v_liq - v_custo) < pr.lucro_bruto_minimo then
    return jsonb_build_object('ok', false, 'erro', 'cupom_nao_cabe', 'mensagem', 'Este cupom não se aplica a este pedido. Fale com a gente no WhatsApp e vemos uma condição.');
  end if;
  update public.orders set discount_pct = cp.percentual, cupom_codigo = v_cod where id = o.id;
  insert into public.cupons_checkout_uso (codigo, order_id, contact_id) values (v_cod, o.id, o.contact_id) on conflict (order_id) do update set codigo = excluded.codigo;
  update public.cupons_checkout set usos = (select count(*) from public.cupons_checkout_uso where codigo = v_cod) where codigo = v_cod;
  perform private.checkout_sincronizar_orcamento(o.id);
  insert into public.order_events (order_id, kind, message) values (o.id, 'price', 'Cliente aplicou o cupom ' || v_cod || ' (' || cp.percentual || '%) no checkout.');
  perform private.checkout_evento(o.id, 'cupom_aplicado', jsonb_build_object('codigo', v_cod));
  return jsonb_build_object('ok', true, 'total', (select total from public.order_financials where order_id = o.id));
end;
$$;

create or replace function public.checkout_remover_cupom(p_token text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype;
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  if o.payment_status = 'aprovado' then return jsonb_build_object('ok', false, 'erro', 'pedido_ja_pago'); end if;
  if o.cupom_codigo is null then return jsonb_build_object('ok', true, 'sem_mudanca', true); end if;
  update public.orders set discount_pct = 0, cupom_codigo = null where id = o.id;
  delete from public.cupons_checkout_uso where order_id = o.id;
  update public.cupons_checkout c set usos = (select count(*) from public.cupons_checkout_uso u where u.codigo = c.codigo);
  perform private.checkout_sincronizar_orcamento(o.id);
  perform private.checkout_evento(o.id, 'cupom_removido', '{}'::jsonb);
  return jsonb_build_object('ok', true, 'total', (select total from public.order_financials where order_id = o.id));
end;
$$;

-- 3) Frete pelo CEP. O valor é cotado no servidor (loja-frete / SuperFrete) e gravado como item de repasse (custo = valor).
create or replace function public.checkout_itens_frete(p_token text) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare o public.orders%rowtype; v jsonb;
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('ref', e.ref, 'quantidade', 1)), '[]'::jsonb) into v
    from public.order_items oi join public.ecommerce_products e on e.sku = oi.code where oi.order_id = o.id and oi.description !~* '^frete';
  return jsonb_build_object('ok', true, 'itens', v, 'pago', o.payment_status = 'aprovado');
end;
$$;

create or replace function public.checkout_definir_frete(
  p_token text, p_valor numeric, p_nome text, p_prazo_dias integer, p_cep text, p_endereco jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_link timestamptz; v_cep text := regexp_replace(coalesce(p_cep, ''), '\D', '', 'g'); v_desc text;
begin
  o := private.checkout_pedido(p_token);
  if o.id is null then return jsonb_build_object('ok', false, 'erro', 'link_invalido'); end if;
  if o.payment_status = 'aprovado' then return jsonb_build_object('ok', false, 'erro', 'pedido_ja_pago'); end if;
  select expira_em into v_link from public.pagamentos where order_id = o.id and eh_link and link_ativo order by criado_em desc limit 1;
  if v_link is null or v_link <= now() then return jsonb_build_object('ok', false, 'erro', 'link_expirado'); end if;
  if v_cep !~ '^[0-9]{8}$' then return jsonb_build_object('ok', false, 'erro', 'cep_invalido'); end if;
  if p_valor is null or p_valor < 0 or p_valor > 1500 then return jsonb_build_object('ok', false, 'erro', 'frete_invalido'); end if;
  delete from public.order_items where order_id = o.id and description ~* '^frete';
  if p_valor > 0 then
    v_desc := 'Frete ' || left(coalesce(nullif(btrim(p_nome), ''), 'envio'), 40) || coalesce(' · prazo de ' || p_prazo_dias || ' dias úteis', '');
    insert into public.order_items (order_id, code, fora_catalogo, description, qty, unit_cost, unit_price, checkout_extra)
    values (o.id, null, true, v_desc, 1, p_valor, p_valor, true);
  end if;
  -- endereço para a nota (só preenche o que está vazio)
  update public.contacts set cep = coalesce(nullif(cep, ''), v_cep),
         logradouro = coalesce(nullif(logradouro, ''), nullif(left(p_endereco ->> 'logradouro', 120), '')),
         bairro = coalesce(nullif(bairro, ''), nullif(left(p_endereco ->> 'bairro', 80), '')),
         municipio = coalesce(nullif(municipio, ''), nullif(left(p_endereco ->> 'cidade', 80), '')),
         uf = coalesce(nullif(uf, ''), nullif(left(upper(p_endereco ->> 'uf'), 2), ''))
   where id = o.contact_id;
  perform private.checkout_sincronizar_orcamento(o.id);
  insert into public.order_events (order_id, kind, message) values (o.id, 'price', case when p_valor > 0 then 'Cliente escolheu frete no checkout: R$ ' || to_char(p_valor, 'FM999990D00') || '.' else 'Frete removido no checkout (retirada ou entrega grátis).' end);
  perform private.checkout_evento(o.id, 'frete_definido', jsonb_build_object('valor', p_valor));
  return jsonb_build_object('ok', true, 'total', (select total from public.order_financials where order_id = o.id));
end;
$$;

-- 4) checkout_carregar: acrescenta cupom, frete e tipo "frete" nos itens sem reescrever a função inteira
do $m$
begin
  if to_regprocedure('private.checkout_carregar_base(text)') is null then
    alter function public.checkout_carregar(text) set schema private;
    alter function private.checkout_carregar(text) rename to checkout_carregar_base;
  end if;
end $m$;
revoke all on function private.checkout_carregar_base(text) from public, anon, authenticated;

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
    'frete', jsonb_build_object('valor', coalesce(v_frete.unit_price, 0), 'descricao', v_frete.description, 'cep_final', right(regexp_replace(coalesce((select cep from public.contacts where id = o.contact_id), ''), '\D', '', 'g'), 3)));
  if v_frete.id is not null then
    r := jsonb_set(r, '{entrega}', jsonb_build_object('texto', 'Envio pelos Correios', 'frete_gratis', false));
    -- subtotal e desconto mostrados sem o frete (repasse, sem desconto de cupom na tela)
    r := r || jsonb_build_object('subtotal', round((r ->> 'subtotal')::numeric - v_frete.unit_price, 2));
  end if;
  return r;
end;
$$;

-- 5) Bling: o frete vira transporte.frete (não é mercadoria) e o pedido segue presencial (indicador 1)
do $m$
begin
  if to_regprocedure('public.bling_pedido_payload_base(uuid)') is null then
    alter function public.bling_pedido_payload(uuid) rename to bling_pedido_payload_base;
  end if;
end $m$;
revoke all on function public.bling_pedido_payload_base(uuid) from public, anon;

create or replace function public.bling_pedido_payload(p_order uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  r := public.bling_pedido_payload_base(p_order);
  if r is null then return r; end if;
  return jsonb_set(r, '{servicos}', coalesce((select jsonb_agg(s) from jsonb_array_elements(coalesce(r -> 'servicos', '[]'::jsonb)) s where s ->> 'descricao' !~* '^frete'), '[]'::jsonb))
         || jsonb_build_object('indicador_presenca', 1);
end $$;
revoke all on function public.bling_pedido_payload(uuid) from public, anon;
grant execute on function public.bling_pedido_payload(uuid) to authenticated, service_role;

do $g$
declare f text;
begin
  foreach f in array array[
    'public.checkout_carregar(text)', 'public.checkout_aplicar_cupom(text, text)', 'public.checkout_remover_cupom(text)',
    'public.checkout_itens_frete(text)', 'public.checkout_definir_frete(text, numeric, text, integer, text, jsonb)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $g$;
