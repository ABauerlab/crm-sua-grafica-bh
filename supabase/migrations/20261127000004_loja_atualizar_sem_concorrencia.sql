-- A atualização dos atributos não roda duas vezes ao mesmo tempo (a segunda espera a próxima rodada).
create or replace function private.loja_atributos_atualizar(p_forcar boolean default false)
returns text language plpgsql security definer set search_path = '' as $$
declare v_ass text; v_old text;
begin
  if not pg_try_advisory_xact_lock(770112) then return 'ocupado'; end if;
  select count(*)::text || '|' || coalesce(max(atualizado_em)::text, '') || '|' || (select count(*) from public.loja_subcategorias)::text into v_ass from public.ecommerce_products;
  select assinatura into v_old from private.loja_atributos_meta where id;
  if not p_forcar and v_old = v_ass then return 'sem mudanca'; end if;
  delete from private.loja_atributos;
  insert into private.loja_atributos select * from private.loja_atributos_v;
  delete from private.loja_familias;
  insert into private.loja_familias select * from private.loja_familias_v;
  insert into private.loja_atributos_meta (id, assinatura, atualizado_em) values (true, v_ass, now())
    on conflict (id) do update set assinatura = excluded.assinatura, atualizado_em = excluded.atualizado_em;
  return 'atualizado';
end $$;
