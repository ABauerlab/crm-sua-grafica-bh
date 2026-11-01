-- Etapa 8: o orçamento enviado pelo agente não aparecia no Kanban (o card só nascia no link de pagamento).
-- Ao marcar o orçamento como enviado, o pedido é criado na etapa "cotando". Falha na criação do card não impede o envio.
-- O link de pagamento (orcamento_registrar_link) já move o card para "aguardando_pagamento".
create or replace function public.orcamento_marcar_enviado(p_orcamento uuid)
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare v_n bigint := 0; v_order uuid;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.orcamentos set status = 'enviado' where id = p_orcamento and status = 'rascunho';
  get diagnostics v_n = row_count;
  if v_n > 0 then
    begin
      v_order := private.orcamento_para_pedido(p_orcamento);
      update public.orders set stage = 'cotando', stage_entered_at = now()
       where id = v_order and stage = 'aguardando_pagamento' and payment_status = 'pendente' and payment_link is null;
    exception when others then
      raise warning 'card do orçamento não criado: %', sqlerrm;
    end;
  end if;
  return jsonb_build_object('ok', true, 'status', (select status from public.orcamentos where id = p_orcamento), 'pedido_id', v_order);
exception when sqlstate 'P0001' or sqlstate '23514' then
  return jsonb_build_object('ok', false, 'erro', sqlerrm);
end;
$function$;
