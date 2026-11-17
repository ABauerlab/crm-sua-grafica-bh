-- Terceiro estado da nota: "não será emitida" (dono decide não emitir). Sai de pendente, guarda o motivo (nf_motivo)
-- e deixa de ser conferida no Bling. Marcar emitida (manual ou pelo Bling) desfaz. Aditiva e idempotente.
alter table public.orders add column if not exists nf_dispensada boolean not null default false;

create or replace function public.nf_dispensar(p_order uuid, p_dispensada boolean, p_motivo text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.orders
     set nf_dispensada = coalesce(p_dispensada, false),
         nf_motivo = case when coalesce(p_dispensada, false) then nullif(btrim(coalesce(p_motivo, nf_motivo, '')), '') else nf_motivo end,
         nf_emitida = case when coalesce(p_dispensada, false) then false else nf_emitida end,
         nf_emitida_em = case when coalesce(p_dispensada, false) then null else nf_emitida_em end
   where id = p_order and payment_status = 'aprovado';
end $$;
revoke all on function public.nf_dispensar(uuid, boolean, text) from public, anon;
grant execute on function public.nf_dispensar(uuid, boolean, text) to authenticated;

create or replace function public.nf_marcar(p_order uuid, p_emitida boolean, p_identificador text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.orders
     set nf_emitida = coalesce(p_emitida, false),
         nf_dispensada = case when coalesce(p_emitida, false) then false else nf_dispensada end,
         nf_identificador = nullif(btrim(coalesce(p_identificador, '')), ''),
         nf_emitida_em = case when coalesce(p_emitida, false) then coalesce(nf_emitida_em, now()) else null end
   where id = p_order and payment_status = 'aprovado';
end $$;

create or replace function public.nf_pendentes_bling(p_limite integer default 12, p_order uuid default null)
returns table (order_id uuid, bling_pedido_id text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return query
    select o.id, o.bling_pedido_id::text
      from public.orders o
     where o.payment_status = 'aprovado' and o.bling_pedido_id is not null and o.excluido_em is null and coalesce(o.teste, false) = false
       and (p_order is null or o.id = p_order)
       and (p_order is not null or (not o.nf_dispensada and (not o.nf_emitida or o.nf_situacao in ('Rejeitada', 'Denegada', 'Cancelada'))))
     order by o.nf_conferido_em nulls first, o.paid_at
     limit p_limite;
end $$;

create or replace function public.nf_registrar_bling(p_order uuid, p_numero text, p_tipo text, p_situacao integer, p_rotulo text, p_emitida boolean, p_chave text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_numero is null then
    update public.orders set nf_conferido_em = now() where id = p_order;
    return;
  end if;
  update public.orders
     set nf_identificador = p_numero, nf_tipo = p_tipo, nf_situacao = p_rotulo, nf_chave = p_chave, nf_conferido_em = now(),
         nf_emitida = coalesce(p_emitida, false),
         nf_dispensada = case when coalesce(p_emitida, false) then false else nf_dispensada end,
         nf_emitida_em = case when coalesce(p_emitida, false) then coalesce(nf_emitida_em, now()) else null end
   where id = p_order;
end $$;

create or replace function public.nf_faltantes(o public.orders)
returns text[] language sql stable set search_path = '' as $$
  select case when (o.payment_status = 'aprovado' or o.payment_manual) and not o.nf_emitida and not o.nf_dispensada and o.cancelado_em is null and o.excluido_em is null and coalesce(o.teste, false) = false
              then coalesce((select public.contato_nf_faltantes(c) from public.contacts c where c.id = o.contact_id), '{}'::text[])
              else '{}'::text[] end;
$$;
