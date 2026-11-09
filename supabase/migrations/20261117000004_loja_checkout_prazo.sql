-- Checkout do site: o prazo devolvido é o mesmo da cotação (com o dia útil extra da criação de arte).
create or replace function public.loja_checkout_preparar(p_cliente jsonb, p_itens jsonb, p_opcoes jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_wa text := regexp_replace(coalesce(p_cliente ->> 'whatsapp', ''), '\D', '', 'g');
  v_doc text := nullif(regexp_replace(coalesce(p_cliente ->> 'documento', ''), '\D', '', 'g'), '');
  v_cep text := nullif(regexp_replace(coalesce(p_opcoes ->> 'cep', ''), '\D', '', 'g'), '');
  v_entrega text := coalesce(nullif(p_opcoes ->> 'entrega', ''), 'retirada');
  a jsonb := private.loja_arte(p_opcoes ->> 'arte');
  v_teste boolean := coalesce((p_opcoes ->> 'teste')::boolean, false);
  v_contact uuid; v_itens jsonb := '[]'::jsonb; v_calc jsonb; it jsonb; v_sku text; r jsonb; v jsonb; v_orc uuid; v_order uuid; v_num bigint; v_total numeric;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  if length(v_wa) in (10, 11) then v_wa := '55' || v_wa; end if;
  if v_wa !~ '^55[1-9][0-9]9?[0-9]{8}$' then return jsonb_build_object('ok', false, 'erro', 'whatsapp_invalido'); end if;
  if length(coalesce(btrim(p_cliente ->> 'nome'), '')) < 3 then return jsonb_build_object('ok', false, 'erro', 'nome_obrigatorio'); end if;
  if a is null then return jsonb_build_object('ok', false, 'erro', 'arte_invalida'); end if;
  if v_entrega not in ('retirada', 'entrega') then return jsonb_build_object('ok', false, 'erro', 'entrega_invalida'); end if;
  if v_entrega = 'entrega' and (v_cep is null or v_cep !~ '^[0-9]{8}$') then return jsonb_build_object('ok', false, 'erro', 'cep_obrigatorio_para_entrega'); end if;

  -- limites: 3 checkouts por WhatsApp em 10 minutos e 30 por hora no site inteiro
  if (select count(*) from public.orders o join public.contacts c on c.id = o.contact_id
       where c.wa_id = v_wa and o.origin_label = 'site' and o.created_at > now() - interval '10 minutes') >= 3
     or (select count(*) from public.orders o where o.origin_label = 'site' and o.created_at > now() - interval '1 hour') >= 30 then
    return jsonb_build_object('ok', false, 'erro', 'muitas_tentativas');
  end if;

  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) not between 1 and 10 then return jsonb_build_object('ok', false, 'erro', 'itens_invalidos'); end if;
  for it in select * from jsonb_array_elements(p_itens) loop
    v_sku := private.loja_sku(it ->> 'ref');
    if v_sku is null then return jsonb_build_object('ok', false, 'erro', 'produto_nao_encontrado', 'ref', it ->> 'ref'); end if;
    v_itens := v_itens || jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', least(greatest(coalesce(nullif(it ->> 'quantidade', '')::integer, 1), 1), 100)));
  end loop;

  -- contato: cria pelo WhatsApp ou completa só o que falta (nunca sobrescreve o cadastro)
  insert into public.contacts as c (wa_id, name, email, document, cep, is_teste)
  values (v_wa, left(btrim(p_cliente ->> 'nome'), 120), nullif(lower(btrim(coalesce(p_cliente ->> 'email', ''))), ''), v_doc, v_cep, v_teste)
  on conflict (wa_id) do update set
    name = coalesce(c.name, excluded.name), email = coalesce(c.email, excluded.email),
    document = coalesce(c.document, excluded.document), cep = coalesce(c.cep, excluded.cep)
  returning id into v_contact;

  r := public.montar_orcamento(v_contact, v_itens, jsonb_build_object('arte', a ->> 'modo_orcamento', 'teste', v_teste,
         'cep', case when v_entrega = 'entrega' then v_cep end));
  if r ->> 'status' <> 'ok' then return jsonb_build_object('ok', false, 'erro', 'orcamento_bloqueado', 'motivo', r ->> 'motivo'); end if;
  v_orc := (r ->> 'orcamento_id')::uuid;
  if a ->> 'arte' = 'conferencia' then
    update public.orcamentos set arte_valor = (a ->> 'valor')::numeric where id = v_orc;
  end if;
  v := public.validar_margem(v_orc);
  if v ->> 'status' <> 'ok' then return jsonb_build_object('ok', false, 'erro', 'orcamento_bloqueado', 'motivo', v ->> 'motivo'); end if;

  v_order := private.orcamento_para_pedido(v_orc);
  update public.orders set origin_label = 'site', title = 'Site ' || private.orcamento_numero((select numero from public.orcamentos where id = v_orc)),
         notes = concat_ws(E'\n', notes, 'Pedido feito no site. Arte: ' || (a ->> 'texto') || '. Entrega: ' || case when v_entrega = 'entrega' then 'entrega no CEP ' || v_cep else 'retirada no balcão' end || '.')
   where id = v_order returning number into v_num;
  if a ->> 'arte' = 'conferencia' then
    update public.order_items set description = 'Conferência e ajuste técnico do arquivo'
     where order_id = v_order and fora_catalogo and description = 'Criação de arte';
  end if;
  select total into v_total from public.order_financials where order_id = v_order;
  -- prazo igual ao da cotação do site (inclui o dia útil extra da criação de arte)
  v_calc := public.loja_calcular(p_itens, a ->> 'arte', case when v_entrega = 'entrega' then v_cep end);
  return jsonb_build_object('ok', true, 'pedido_id', v_order, 'numero', v_num, 'orcamento', r ->> 'numero', 'total', v_total,
    'prazo', coalesce(v_calc #>> '{prazo,frase}', r ->> 'prazo'), 'data_prevista', coalesce(v_calc #>> '{prazo,data_pronto}', r ->> 'data_prevista'));
end $$;
revoke all on function public.loja_checkout_preparar(jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.loja_checkout_preparar(jsonb, jsonb, jsonb) to service_role;
