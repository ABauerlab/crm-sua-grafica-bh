-- Etapa 8: modo piloto da IA (aditivo; desligado por padrão, nada muda enquanto piloto_ativo = false).
-- Reverter: update public.agente_config set piloto_ativo = false;  (a função antiga está em 20261104000003 / histórico do git)
alter table public.agente_config
  add column if not exists piloto_ativo boolean not null default false,
  add column if not exists piloto_wa_ids text[] not null default '{}',
  add column if not exists piloto_percentual integer not null default 0 check (piloto_percentual between 0 and 100);

create or replace function public.agente_bloqueio(p_conversation uuid)
 returns text language plpgsql stable security definer set search_path to ''
as $function$
declare
  cfg record; v_global boolean; v_conv record; v_hora time; v_dow int; v_dias jsonb;
  v_auto boolean := coalesce((private.persona_cfg() ->> 'pos_pagamento_automatico')::boolean, true);
begin
  select * into cfg from public.agente_config where id = 1;
  select coalesce((value ->> 'enabled')::boolean, false) into v_global from public.app_settings where key = 'agent';
  if not coalesce(cfg.ia_ligada, false) or not coalesce(v_global, false) then return 'ia_pausada'; end if;

  if not coalesce(cfg.atende_24h, true) then
    v_hora := (now() at time zone 'America/Sao_Paulo')::time;
    v_dow := extract(dow from now() at time zone 'America/Sao_Paulo')::int;
    v_dias := coalesce(cfg.horario_ia -> 'dias', '[0,1,2,3,4,5,6]'::jsonb);
    if not (v_dias @> to_jsonb(v_dow)) or v_hora < coalesce((cfg.horario_ia ->> 'inicio')::time, '00:00'::time)
       or v_hora > coalesce((cfg.horario_ia ->> 'fim')::time, '23:59'::time) then
      return 'fora_do_horario';
    end if;
  end if;

  select cv.contact_id, cv.modo_atendimento, cv.ai_handled, cv.setor, ct.optout, ct.wa_id into v_conv
  from public.conversations cv join public.contacts ct on ct.id = cv.contact_id where cv.id = p_conversation;
  if not found then return 'conversa_inexistente'; end if;
  if v_conv.wa_id is not distinct from cfg.whatsapp_dono then return 'numero_do_dono'; end if;
  if coalesce(cfg.piloto_ativo, false)
     and not (v_conv.wa_id = any (cfg.piloto_wa_ids))
     and (abs(hashtext(coalesce(v_conv.wa_id, ''))) % 100) >= coalesce(cfg.piloto_percentual, 0) then
    return 'fora_do_piloto';
  end if;
  if coalesce(v_conv.optout, false) then return 'optout'; end if;
  if coalesce(v_conv.modo_atendimento, 'ia') <> 'ia' or not coalesce(v_conv.ai_handled, true) then return 'modo_humano'; end if;

  if exists (select 1 from public.orders o where o.contact_id = v_conv.contact_id and o.excluido_em is null and o.stage in ('pago', 'arte', 'prova', 'producao')) then
    if not v_auto then return 'pedido_pago'; end if;
    if v_conv.setor in ('arte', 'dono') or exists (
         select 1 from public.orders o where o.contact_id = v_conv.contact_id and o.excluido_em is null and o.stage in ('arte', 'prova')) then
      return 'aguardando_dono';
    end if;
  end if;
  return null;
end;
$function$;
