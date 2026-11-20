-- Item 7 (20/11/2026): mensagem pós-pagamento (cliente-pago-avisar / WF5) fica limpa e direta.
-- O checkout próprio (/pagar/<token>, via checkout-dados) já coleta os dados de Nota Fiscal
-- (CPF/CNPJ, nome/razão social, endereço com CEP, e-mail), então a confirmação de pagamento
-- não pede mais esses dados nem cita o endereço fixo de retirada na Praça Sete.
-- Também corrige o fallback de nome: pagamento_pos_reservar_msg ainda devolvia 'cliente'
-- quando o contato não tinha nome válido (a mesma saudação-vocativo já proibida em outras
-- mensagens pelas correções de 22/12 e 20/11 anteriores). Agora devolve null e quem monta
-- o texto usa a saudação neutra "Oi!" (padrão private.fu_nome / followup_montar_base).
-- Aditiva e idempotente (CREATE OR REPLACE).

create or replace function public.pagamento_pos_reservar_msg(p_order uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  pos public.pagamento_pos%rowtype; o public.orders%rowtype; c public.contacts%rowtype; cv public.conversations%rowtype; v_ref text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.pagamento_pos set msg_status = 'enviando', msg_inicio_em = now(), msg_tentativas = msg_tentativas + 1
   where order_id = p_order and banco_ok and msg_tentativas < 3
     and (msg_status in ('pendente', 'falhou_temp') or (msg_status = 'enviando' and msg_inicio_em < now() - interval '5 minutes'))
  returning * into pos;
  if not found then
    select * into pos from public.pagamento_pos where order_id = p_order;
    return jsonb_build_object('ok', true, 'enviar', false, 'msg_status', pos.msg_status);
  end if;
  select * into o from public.orders where id = p_order;
  select * into c from public.contacts where id = o.contact_id;
  select * into cv from public.conversations where id = o.conversation_id;
  v_ref := 'SG-' || lpad(o.number::text, 4, '0');
  return jsonb_build_object('ok', true, 'enviar', true, 'tentativa', pos.msg_tentativas,
    'wa_id', c.wa_id, 'conversation_id', cv.id, 'nome', private.fu_nome(c.name),
    'pedido', v_ref, 'previsao', coalesce(to_char(o.due_date, 'DD/MM'), 'a confirmar'),
    'arte_status', o.art_status, 'entrega', o.delivery_method,
    'janela_ate', greatest(cv.last_inbound_at + interval '24 hours', coalesce(cv.ad_window_until, 'epoch'::timestamptz)));
end;
$$;
revoke execute on function public.pagamento_pos_reservar_msg(uuid) from public, anon, authenticated;
grant execute on function public.pagamento_pos_reservar_msg(uuid) to service_role;
