-- Pedido perdido: novo estágio 'perdido' no pedido, com motivo obrigatório (mesmo enum do orçamento) e observação.
-- Só pedido ainda não pago pode ser perdido. O motivo fica guardado para um disparo futuro (só para quem consentiu).
-- Aditiva e idempotente.

alter table public.orders drop constraint if exists orders_stage_check;
alter table public.orders add constraint orders_stage_check
  check (stage = any (array['novo', 'cotando', 'aguardando_pagamento', 'pago', 'arte', 'prova', 'producao', 'entregue', 'recompra', 'perdido']));

alter table public.orders add column if not exists motivo_perda text;
alter table public.orders add column if not exists motivo_perda_obs text;
alter table public.orders add column if not exists motivo_perda_em timestamptz;

alter table public.orders drop constraint if exists orders_motivo_perda_check;
alter table public.orders add constraint orders_motivo_perda_check
  check (motivo_perda is null or motivo_perda in ('preco', 'prazo', 'sumiu', 'decidiu_depois', 'abandonou_checkout', 'outro'));

alter table public.orders drop constraint if exists orders_motivo_perda_obs_tamanho;
alter table public.orders add constraint orders_motivo_perda_obs_tamanho
  check (motivo_perda_obs is null or char_length(motivo_perda_obs) <= 500);

-- Trava no banco: entrar em Perdido exige motivo válido e pedido sem pagamento.
create or replace function private.orders_exigir_motivo_perda()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.stage = 'perdido' and old.stage is distinct from 'perdido' then
    if new.payment_status = 'aprovado' or new.payment_manual then
      raise exception 'Pedido pago não pode ser marcado como perdido.' using errcode = 'P0001';
    end if;
    if new.motivo_perda is null then
      raise exception 'Informe o motivo da perda antes de marcar o pedido como perdido.' using errcode = 'P0001';
    end if;
    if new.motivo_perda = 'outro' and nullif(btrim(new.motivo_perda_obs), '') is null then
      raise exception 'Quando o motivo é Outro, escreva a observação.' using errcode = 'P0001';
    end if;
    new.motivo_perda_em := coalesce(new.motivo_perda_em, now());
  end if;
  return new;
end;
$$;

drop trigger if exists orders_exigir_motivo_perda on public.orders;
create trigger orders_exigir_motivo_perda
  before update of stage on public.orders
  for each row execute function private.orders_exigir_motivo_perda();

-- Registra a perda pela tela (Kanban ou ficha do pedido). Quem escolhe o motivo é o atendente.
create or replace function public.pedido_registrar_perda(p_order uuid, p_motivo text, p_obs text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ped public.orders%rowtype;
  v_obs text := nullif(btrim(p_obs), '');
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_motivo is null or p_motivo not in ('preco', 'prazo', 'sumiu', 'decidiu_depois', 'abandonou_checkout', 'outro') then
    return jsonb_build_object('ok', false, 'motivo', 'motivo_invalido');
  end if;
  if p_motivo = 'outro' and v_obs is null then
    return jsonb_build_object('ok', false, 'motivo', 'obs_obrigatoria');
  end if;

  select * into v_ped from public.orders where id = p_order for update;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'nao_encontrado');
  end if;
  if v_ped.payment_status = 'aprovado' or v_ped.payment_manual then
    return jsonb_build_object('ok', false, 'motivo', 'pedido_pago');
  end if;

  update public.orders
     set stage = 'perdido', motivo_perda = p_motivo, motivo_perda_obs = v_obs, motivo_perda_em = now()
   where id = p_order;

  return jsonb_build_object('ok', true, 'estagio_anterior', v_ped.stage);
end;
$$;

revoke execute on function public.pedido_registrar_perda(uuid, text, text) from public, anon;
grant execute on function public.pedido_registrar_perda(uuid, text, text) to authenticated, service_role;
