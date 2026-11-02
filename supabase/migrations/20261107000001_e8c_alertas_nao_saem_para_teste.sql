-- Etapa 8C: alertas de contatos de teste (is_teste) nunca saem para o dono.
-- Antes, uma conversa simulada que chamasse o dono criava alerta 'pendente' e o alertas-enviar
-- mandava popup e WhatsApp de verdade. Agora o alerta fica gravado (para auditoria do teste)
-- com os dois canais 'desligado'. Mudança aditiva: só acrescenta a checagem; o resto é igual.
create or replace function public.alerta_criar(p_tipo text, p_gravidade text, p_contact uuid, p_conversation uuid, p_order uuid, p_motivo text, p_dados jsonb default '{}'::jsonb, p_chave text default null::text, p_canais text[] default null::text[])
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_grav text := case when lower(coalesce(p_gravidade, '')) in ('alta', 'alto', 'high', 'urgente') then 'alta' else 'baixa' end;
  v_motivo text := left(trim(coalesce(p_motivo, 'sem motivo informado')), 300);
  v_cfg jsonb := private.notif_cfg();
  v_pref jsonb := coalesce(v_cfg -> 'tipos' -> private.alerta_categoria(p_tipo), '{"push":true,"whatsapp":true}'::jsonb);
  v_base text := coalesce(v_cfg ->> 'url_base', 'https://crm.suagraficabh.com.br');
  v_wa text; v_push text; v_id uuid; v_dados jsonb := coalesce(p_dados, '{}'::jsonb);
  v_teste boolean := false;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_chave is not null then
    select id into v_id from public.alertas where chave = p_chave;
    if found then return jsonb_build_object('ok', true, 'ja_alertado', true, 'alerta_id', v_id); end if;
  else
    if exists (
      select 1 from public.alertas
      where tipo = p_tipo and criado_em > now() - interval '30 minutes' and left(motivo, 60) = left(v_motivo, 60)
        and conversation_id is not distinct from p_conversation and order_id is not distinct from p_order and contact_id is not distinct from p_contact
    ) then return jsonb_build_object('ok', true, 'ja_alertado', true); end if;
  end if;

  -- contato de teste: grava, mas não entrega ao dono
  select coalesce(bool_or(c.is_teste), false) into v_teste from public.contacts c
   where c.id = coalesce(p_contact, (select cv.contact_id from public.conversations cv where cv.id = p_conversation));

  v_wa := case when v_teste or not coalesce((v_pref ->> 'whatsapp')::boolean, true) or (p_canais is not null and not 'whatsapp' = any(p_canais)) then 'desligado'
               when v_grav = 'baixa' then 'agrupado' else 'pendente' end;
  v_push := case when v_teste or not coalesce((v_pref ->> 'push')::boolean, true) or (p_canais is not null and not 'push' = any(p_canais)) then 'desligado'
                 when v_grav = 'baixa' then 'agrupado' else 'pendente' end;
  if not (v_dados ? 'url') then
    if p_order is not null then v_dados := v_dados || jsonb_build_object('url', v_base || '/kanban?pedido=' || p_order::text);
    elsif p_conversation is not null then v_dados := v_dados || jsonb_build_object('url', v_base || '/inbox/' || p_conversation::text);
    else v_dados := v_dados || jsonb_build_object('url', v_base || '/painel'); end if;
  end if;
  if p_contact is not null and not (v_dados ? 'cliente') then
    v_dados := v_dados || jsonb_build_object('cliente', coalesce((select nullif(trim(name), '') from public.contacts where id = p_contact), 'Cliente sem nome'));
  end if;

  insert into public.alertas (tipo, gravidade, contact_id, conversation_id, order_id, motivo, canais, status_whatsapp, status_push, dados, chave)
  values (p_tipo, v_grav, p_contact, p_conversation, p_order, v_motivo,
          array_remove(array[case when v_wa <> 'desligado' then 'whatsapp' end, case when v_push <> 'desligado' then 'push' end], null),
          v_wa, v_push, v_dados, p_chave)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'alerta_id', v_id, 'gravidade', v_grav, 'status_whatsapp', v_wa, 'status_push', v_push, 'teste', v_teste);
end;
$function$;
