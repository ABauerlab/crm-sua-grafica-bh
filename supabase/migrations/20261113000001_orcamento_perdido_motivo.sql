-- Orçamento perdido: status 'perdido' com motivo obrigatório (enum) e observação (obrigatória quando o motivo é 'outro').
-- O motivo fica pronto para segmentar um disparo futuro (só para quem consentiu, ver marketing_consent).
-- Aditiva e idempotente.

alter table public.orcamentos add column if not exists motivo_perda_obs text;

alter table public.orcamentos drop constraint if exists orcamentos_motivo_perda_obs_tamanho;
alter table public.orcamentos add constraint orcamentos_motivo_perda_obs_tamanho
  check (motivo_perda_obs is null or char_length(motivo_perda_obs) <= 500);

-- Troca a assinatura (2 argumentos) pela de 3, com observação opcional. Chamadas antigas de 2 argumentos continuam valendo.
drop function if exists public.orcamento_registrar_perda(uuid, text);

create or replace function public.orcamento_registrar_perda(p_orcamento uuid, p_motivo text, p_obs text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
  v_obs text := nullif(btrim(p_obs), '');
begin
  if not (private.is_staff() or private.dono_ou_servidor()) then
    raise exception 'Sem permissão.' using errcode = '42501';
  end if;
  if p_motivo is null or p_motivo not in ('preco', 'prazo', 'sumiu', 'decidiu_depois', 'abandonou_checkout', 'outro') then
    return jsonb_build_object('ok', false, 'motivo', 'motivo_invalido');
  end if;
  if p_motivo = 'outro' and v_obs is null then
    return jsonb_build_object('ok', false, 'motivo', 'obs_obrigatoria');
  end if;

  select status into v_status from public.orcamentos where id = p_orcamento for update;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'nao_encontrado');
  end if;
  if v_status = 'pago' then
    return jsonb_build_object('ok', false, 'motivo', 'orcamento_pago');
  end if;

  update public.orcamentos
     set status = 'perdido', motivo_perda = p_motivo, motivo_perda_em = now(), motivo_perda_obs = v_obs
   where id = p_orcamento;

  return jsonb_build_object('ok', true, 'status_anterior', v_status);
end;
$$;

revoke execute on function public.orcamento_registrar_perda(uuid, text, text) from public, anon;
grant execute on function public.orcamento_registrar_perda(uuid, text, text) to authenticated, service_role;

-- Pedido cujo orçamento foi perdido não ganha rascunho novo sozinho ao editar itens (o vendedor cria uma nova versão de propósito).
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
       or v_ped.cancelado_em is not null or v_ped.excluido_em is not null
       or exists (select 1 from public.orcamentos x where x.order_id = p_order and x.status in ('perdido', 'cancelado')) then
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

  update public.orcamentos
     set desconto_valor = round(v_bruto * v_desc_pct / 100, 2), itens_exibicao = null
   where id = o.id;

  return jsonb_build_object('ok', true, 'sincronizado', true, 'criado', v_criado, 'orcamento_id', o.id, 'itens', v_itens);
end;
$$;

revoke execute on function public.pedido_sincronizar_orcamento(uuid) from public, anon;
grant execute on function public.pedido_sincronizar_orcamento(uuid) to authenticated, service_role;
