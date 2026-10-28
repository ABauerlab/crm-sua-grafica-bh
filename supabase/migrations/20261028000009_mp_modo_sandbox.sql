-- Mercado Pago: o live_mode da API não decide o modo em teste (sandbox devolve valores inconsistentes). Em produção continua exigido.
-- Ao confirmar um pagamento que antes estava com divergência, limpa a divergência e resolve os alertas dela.

-- Aviso do Mercado Pago já consultado na API: registra a tentativa e, se tudo confere, confirma o pedido.
create or replace function public.mp_registrar_pagamento(
  p_mp_payment_id text, p_mp_status text, p_status_detail text, p_referencia text,
  p_valor numeric, p_moeda text, p_metodo text, p_live boolean, p_modo text,
  p_aprovado_em timestamptz, p_preference_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_num bigint;
  v_o public.orders%rowtype;
  v_total numeric;
  v_row public.pagamentos%rowtype;
  v_link public.pagamentos%rowtype;
  v_status text;
  v_rank_new int;
  v_rank_old int;
  v_div text;
  v_payload jsonb;
  v_ref text;
  v_ranks jsonb := '{"pendente":0,"em_analise":1,"recusado":2,"cancelado":2,"expirado":2,"invalidado":2,"aprovado":3,"estornado":4,"contestado":5}';
begin
  if p_modo not in ('teste', 'producao') then raise exception 'modo inválido'; end if;
  v_status := case p_mp_status
    when 'approved' then 'aprovado' when 'pending' then 'pendente'
    when 'authorized' then 'em_analise' when 'in_process' then 'em_analise' when 'in_mediation' then 'em_analise'
    when 'rejected' then 'recusado' when 'refunded' then 'estornado' when 'charged_back' then 'contestado'
    when 'cancelled' then case when p_status_detail = 'expired' then 'expirado' else 'cancelado' end
    else 'pendente' end;

  if p_referencia ~ '^SG-[0-9]{1,12}$' then v_num := substring(p_referencia from 4)::bigint; end if;
  select * into v_o from public.orders where number = v_num for update;
  if not found then
    perform private.mp_alerta('referencia_desconhecida', null, p_mp_payment_id, 'ref_desconhecida:' || p_mp_payment_id || ':' || v_status,
      'Pagamento recebido com referência que não existe no CRM.', jsonb_build_object('referencia', p_referencia, 'valor', p_valor, 'status', v_status));
    return jsonb_build_object('acao', 'alerta', 'motivo', 'referencia_desconhecida');
  end if;
  select total into v_total from public.order_financials where order_id = v_o.id;
  v_ref := 'SG-' || lpad(v_o.number::text, 4, '0');

  -- 1) a tentativa já conhecida; 2) o link ainda sem pagamento; 3) nova tentativa copiando o link
  select * into v_row from public.pagamentos where mp_payment_id = p_mp_payment_id;
  if not found then
    select * into v_link from public.pagamentos
      where order_id = v_o.id and eh_link and modo = p_modo and (p_preference_id is null or mp_preference_id = p_preference_id)
      order by criado_em desc limit 1 for update;
    if found and v_link.mp_payment_id is null then
      update public.pagamentos set mp_payment_id = p_mp_payment_id where id = v_link.id returning * into v_row;
    else
      insert into public.pagamentos (order_id, eh_link, link_ativo, mp_preference_id, mp_payment_id, link, valor, status, modo, expira_em)
      values (v_o.id, false, false, coalesce(v_link.mp_preference_id, p_preference_id), p_mp_payment_id, v_link.link, greatest(coalesce(p_valor, 0), 0.01), 'pendente', p_modo, v_link.expira_em)
      returning * into v_row;
    end if;
  end if;

  v_rank_new := (v_ranks ->> v_status)::int;
  v_rank_old := (v_ranks ->> v_row.status)::int;
  -- aviso repetido: mesmo status já tratado (o evento do status existe, ou o pedido já foi confirmado por este pagamento)
  if v_row.status = v_status and v_row.divergencia is null and (
       (v_status = 'aprovado' and v_o.payment_status = 'aprovado')
       or (v_status <> 'aprovado' and exists (select 1 from public.eventos_pagamento where chave = 'pagamento_' || v_status || ':' || p_mp_payment_id))
     ) then
    return jsonb_build_object('acao', 'duplicado', 'status', v_status);
  end if;
  if v_rank_new < v_rank_old then
    return jsonb_build_object('acao', 'ignorado', 'motivo', 'aviso_antigo', 'status', v_status);
  end if;

  update public.pagamentos set
    status = v_status, status_detalhe = p_status_detail, metodo = coalesce(p_metodo, metodo),
    valor = greatest(coalesce(p_valor, 0), 0.01), moeda = coalesce(p_moeda, 'BRL'),
    aprovado_em = case when v_status = 'aprovado' then coalesce(p_aprovado_em, now()) else aprovado_em end,
    atualizado_em = now()
  where id = v_row.id returning * into v_row;

  v_payload := jsonb_build_object('pedido_id', v_o.id, 'pedido_numero', v_o.number, 'referencia', v_ref, 'valor', p_valor,
    'metodo', p_metodo, 'mp_payment_id', p_mp_payment_id, 'modo', p_modo, 'status_detalhe', p_status_detail, 'teste', v_o.teste);

  if v_status = 'aprovado' then
    if coalesce(p_moeda, '') <> 'BRL' then v_div := 'moeda_divergente';
    elsif p_valor is null or round(p_valor * 100) <> round(v_total * 100) then v_div := 'valor_divergente';
    -- O modo vem de qual segredo assinou o aviso e de qual token consultou o pagamento. O live_mode da API não é confiável no
    -- sandbox (usuários de teste), então só se exige live_mode verdadeiro em produção.
    elsif p_modo = 'producao' and p_live is not true then v_div := 'modo_divergente';
    elsif p_modo = 'teste' and not v_o.teste then v_div := 'teste_em_pedido_real';
    elsif p_modo = 'producao' and v_o.teste then v_div := 'producao_em_pedido_teste';
    elsif v_o.payment_status = 'aprovado' and v_o.payment_external_id is distinct from p_mp_payment_id then v_div := 'pagamento_duplicado';
    end if;

    if v_div is not null then
      update public.pagamentos set divergencia = v_div where id = v_row.id;
      perform private.mp_alerta(v_div, v_o.id, p_mp_payment_id, v_div || ':' || p_mp_payment_id,
        case v_div
          when 'valor_divergente' then 'Valor pago (R$ ' || replace(to_char(p_valor, 'FM9999990.00'), '.', ',') || ') diferente do pedido ' || v_ref || ' (R$ ' || replace(to_char(v_total, 'FM9999990.00'), '.', ',') || '). O pedido não foi alterado.'
          when 'moeda_divergente' then 'Moeda do pagamento diferente de BRL no pedido ' || v_ref || '. O pedido não foi alterado.'
          when 'teste_em_pedido_real' then 'Pagamento de TESTE recebido para o pedido real ' || v_ref || '. O pedido não foi alterado.'
          when 'producao_em_pedido_teste' then 'Pagamento real recebido para o pedido de teste ' || v_ref || '. Confira com o dono.'
          when 'pagamento_duplicado' then 'Segundo pagamento aprovado para o pedido ' || v_ref || ' que já estava pago. Avalie o estorno.'
          else 'Modo do aviso (teste/produção) não confere com a configuração. O pedido não foi alterado.' end,
        v_payload || jsonb_build_object('valor_pedido', v_total));
      return jsonb_build_object('acao', 'alerta', 'motivo', v_div);
    end if;

    update public.pagamentos set link_ativo = false where order_id = v_o.id and eh_link;
    update public.pagamentos set divergencia = null where id = v_row.id;
    update public.pagamentos_alertas set resolvido_em = now() where mp_payment_id = p_mp_payment_id and resolvido_em is null and tipo in ('modo_divergente', 'valor_divergente', 'moeda_divergente');
    perform private.confirmar_pagamento(v_o.id, 'mercadopago', p_metodo, p_mp_payment_id, p_aprovado_em, v_row.id);
    return jsonb_build_object('acao', 'confirmado');
  end if;

  perform private.mp_evento('pagamento_' || v_status, v_o.id, v_row.id, 'pagamento_' || v_status || ':' || p_mp_payment_id, v_payload);
  if v_status = 'recusado' then
    perform private.mp_alerta('pagamento_recusado', v_o.id, p_mp_payment_id, 'recusado:' || p_mp_payment_id,
      'Pagamento recusado no pedido ' || v_ref || ' (' || coalesce(p_status_detail, 'sem detalhe') || '). O cliente pode tentar de novo pelo mesmo link.', v_payload);
  elsif v_status = 'estornado' then
    perform private.mp_alerta('estorno', v_o.id, p_mp_payment_id, 'estorno:' || p_mp_payment_id,
      'Pagamento do pedido ' || v_ref || ' foi estornado. O pedido não foi alterado: decida o que fazer.', v_payload);
  elsif v_status = 'contestado' then
    perform private.mp_alerta('contestacao', v_o.id, p_mp_payment_id, 'contestacao:' || p_mp_payment_id,
      'Pagamento do pedido ' || v_ref || ' foi contestado (chargeback). O pedido não foi alterado: responda no painel do Mercado Pago.', v_payload);
  end if;
  return jsonb_build_object('acao', 'registrado', 'status', v_status);
end;
$$;

revoke execute on function public.mp_registrar_pagamento(text, text, text, text, numeric, text, text, boolean, text, timestamptz, text) from public, anon, authenticated;
grant execute on function public.mp_registrar_pagamento(text, text, text, text, numeric, text, text, boolean, text, timestamptz, text) to service_role;
