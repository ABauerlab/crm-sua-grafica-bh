-- Materializa os atributos (a view levava 6 s) e atualiza sozinho quando a vitrine muda.
-- STATUS: aplicação no banco ficou pendente de confirmação do dono (ver docs/agente/progresso.md, Em andamento).
drop function if exists private.loja_passa(private.loja_atributos, jsonb, text);
do $$ begin
  if exists (select 1 from pg_views where schemaname = 'private' and viewname = 'loja_atributos') then
    alter view private.loja_atributos rename to loja_atributos_v;
  end if;
end $$;
create table if not exists private.loja_atributos as select * from private.loja_atributos_v with no data;
create unique index if not exists loja_atributos_sku_idx on private.loja_atributos (sku);
create index if not exists loja_atributos_cat_idx on private.loja_atributos (categoria_slug);
create index if not exists loja_atributos_modelo_idx on private.loja_atributos (modelo);
create table if not exists private.loja_atributos_meta (id boolean primary key default true check (id), assinatura text, atualizado_em timestamptz);
alter table private.loja_atributos enable row level security;
alter table private.loja_atributos_meta enable row level security;

create or replace function private.loja_atributos_atualizar(p_forcar boolean default false)
returns text language plpgsql security definer set search_path = '' as $$
declare v_ass text; v_old text;
begin
  select count(*)::text || '|' || coalesce(max(atualizado_em)::text, '') || '|' || (select count(*) from public.loja_subcategorias)::text into v_ass from public.ecommerce_products;
  select assinatura into v_old from private.loja_atributos_meta where id;
  if not p_forcar and v_old = v_ass then return 'sem mudanca'; end if;
  delete from private.loja_atributos;
  insert into private.loja_atributos select * from private.loja_atributos_v;
  insert into private.loja_atributos_meta (id, assinatura, atualizado_em) values (true, v_ass, now())
    on conflict (id) do update set assinatura = excluded.assinatura, atualizado_em = excluded.atualizado_em;
  return 'atualizado';
end $$;
revoke all on function private.loja_atributos_atualizar(boolean) from public, anon, authenticated;

create or replace function private.loja_passa(a private.loja_atributos, f jsonb, skip text default null)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(f, '{}'::jsonb) = '{}'::jsonb or (
    (skip = 'sub' or f ->> 'sub' is null or a.sub = f ->> 'sub')
    and (skip = 'tipo' or f -> 'tipo' is null or f -> 'tipo' ? a.tipo)
    and (skip = 'material' or f -> 'material' is null or f -> 'material' ? a.material)
    and (skip = 'gram' or f -> 'gram' is null or f -> 'gram' ? a.gram)
    and (skip = 'formato' or f -> 'formato' is null or f -> 'formato' ? a.formato)
    and (skip = 'prazo' or f -> 'prazo' is null or f -> 'prazo' ? a.prazo)
    and (skip = 'preco' or f -> 'preco' is null or f -> 'preco' ? a.preco_faixa)
    and (skip = 'acab' or f -> 'acab' is null or exists (select 1 from jsonb_array_elements_text(f -> 'acab') z where z = any (a.acab))));
$$;

select private.loja_atributos_atualizar(true);
select cron.schedule('loja-atributos', '*/15 * * * *', $c$select private.loja_atributos_atualizar()$c$);
