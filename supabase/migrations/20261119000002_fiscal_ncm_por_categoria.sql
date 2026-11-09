-- O NCM sugerido é decidido por categoria (146 categorias), não por linha: a regra por linha estourava o tempo.
create or replace function public.fiscal_aplicar_ncm(p_sobrescrever boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  with cats as materialized (
    select k.categoria, (select r from public.fiscal_ncm_regras r
                          where lower(translate(k.categoria, 'ÁÀÂÃÉÊÍÓÔÕÚÇáàâãéêíóôõúç', 'AAAAEEIOOOUCaaaaeeiooouc')) ~ r.padrao
                          order by r.prioridade limit 1) r
      from (select distinct categoria from public.catalogo where categoria is not null) k)
  update public.catalogo c set ncm = (k.r).ncm, ncm_revisar = not (k.r).confirmado
    from cats k
   where c.categoria = k.categoria and k.r is not null and (p_sobrescrever or c.ncm is null)
     and c.ncm is distinct from (k.r).ncm;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'atualizados', v_n,
    'a_revisar', (select count(*) from public.catalogo where ncm_revisar),
    'por_ncm', (select jsonb_object_agg(coalesce(ncm, 'sem'), n) from (select ncm, count(*) n from public.catalogo group by ncm) x));
end $$;
