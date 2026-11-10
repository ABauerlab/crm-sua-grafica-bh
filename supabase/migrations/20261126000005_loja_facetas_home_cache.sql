-- Facetas da loja inteira pré-calculadas (a home usa; o cron atualiza a cada 15 min, 5 minutos depois dos atributos)
create table if not exists private.loja_facetas_cache (id boolean primary key default true check (id), json jsonb not null, atualizado_em timestamptz not null default now());
alter table private.loja_facetas_cache enable row level security;

create or replace function private.loja_facetas_cache_atualizar() returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into private.loja_facetas_cache (id, json, atualizado_em) values (true, public.loja_facetas(null, null, '{}'::jsonb), now())
    on conflict (id) do update set json = excluded.json, atualizado_em = excluded.atualizado_em;
end $$;
revoke all on function private.loja_facetas_cache_atualizar() from public, anon, authenticated;

create or replace function public.loja_facetas_home() returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select c.json from private.loja_facetas_cache c where c.id), '{"total":0,"facetas":{}}'::jsonb);
$$;
revoke all on function public.loja_facetas_home() from public;
grant execute on function public.loja_facetas_home() to anon, authenticated, service_role;

select private.loja_facetas_cache_atualizar();
select cron.schedule('loja-facetas-home', '5,20,35,50 * * * *', $c$select private.loja_facetas_cache_atualizar()$c$);
