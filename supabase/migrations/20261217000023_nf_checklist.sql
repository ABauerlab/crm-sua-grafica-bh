-- Checklist de nota fiscal por pedido pago: marcar que a NF foi emitida e guardar o identificador da nota no Bling.
-- Aditiva e idempotente.
alter table public.orders add column if not exists nf_emitida boolean not null default false;
alter table public.orders add column if not exists nf_identificador text;
alter table public.orders add column if not exists nf_emitida_em timestamptz;

create or replace function public.nf_marcar(p_order uuid, p_emitida boolean, p_identificador text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.orders
     set nf_emitida = coalesce(p_emitida, false),
         nf_identificador = nullif(btrim(coalesce(p_identificador, '')), ''),
         nf_emitida_em = case when coalesce(p_emitida, false) then coalesce(nf_emitida_em, now()) else null end
   where id = p_order and payment_status = 'aprovado';
end $$;
revoke all on function public.nf_marcar(uuid, boolean, text) from public, anon;
grant execute on function public.nf_marcar(uuid, boolean, text) to authenticated, service_role;
