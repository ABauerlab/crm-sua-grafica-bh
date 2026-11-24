-- Bug de 24/11 (caso Waner Diniz): cliente pediu "frente e verso" (4x4) para cartões e enviar_foto_produto
-- devolveu opções de 4x0 (só frente) e 4x1 (verso preto) misturadas, contradizendo o que a Laura já tinha cotado.
-- foto_candidatas pontuava por token (mínimo 4 letras) e nunca considerava o código de cor (4x4/4x1/4x0 têm 3
-- caracteres), então a ordem final dependia só de hashtext, podendo trazer cor errada. Agora, quando o termo
-- deixa claro a cor pedida, descarta candidatas cujo caminho tem um código de cor identificável diferente;
-- sem cor identificável no termo ou no caminho, nada é filtrado. Aditiva e idempotente (create or replace).

create or replace function public.foto_candidatas(p_grupo text, p_sku text default null, p_termo text default null, p_limite integer default 8)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_tokens text[]; v_res jsonb; v_norm text; v_cor_pref text;
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  v_norm := private.norm_busca(coalesce(p_termo, ''));
  select coalesce(array_agg(t), '{}') into v_tokens from unnest(string_to_array(v_norm, ' ')) t where length(t) >= 4;
  v_cor_pref := case
    when v_norm ~ '(^| )4 ?x ?4( |$)' or v_norm ~ 'frente e verso colorid|colorid[oa]? (na )?frente e (no )?verso|colorid[oa]? dos dois lados' then '4X4'
    when v_norm ~ '(^| )4 ?x ?1( |$)' then '4X1'
    when v_norm ~ '(^| )4 ?x ?0( |$)' or v_norm ~ 'colorid[oa]? so (na )?frente|so frente colorid' then '4X0'
    when v_norm ~ '(^| )1 ?x ?1( |$)' then '1X1'
    when v_norm ~ '(^| )1 ?x ?0( |$)' then '1X0'
  end;
  select coalesce(jsonb_agg(jsonb_build_object('imagem', imagem, 'caminho', caminho, 'exato', exato, 'score', score) order by exato desc, score desc, ordem), '[]'::jsonb) into v_res
  from (
    select distinct on (m.imagem) m.imagem, m.caminho,
           (p_sku is not null and m.sku = upper(btrim(p_sku))) as exato,
           (select count(*) from unnest(v_tokens) t where private.norm_busca(m.caminho) like '%' || t || '%') as score,
           hashtext(m.imagem) as ordem
      from public.produto_fotos_mapa m
     where (m.grupo_produto = p_grupo or (p_sku is not null and m.sku = upper(btrim(p_sku))))
       and (
             v_cor_pref is null
             or (p_sku is not null and m.sku = upper(btrim(p_sku)))
             or coalesce((regexp_match(upper(m.caminho), '4X4|4X1|4X0|1X1|1X0'))[1], v_cor_pref) = v_cor_pref
           )
     order by m.imagem, (p_sku is not null and m.sku = upper(btrim(p_sku))) desc
  ) x
  limit greatest(1, least(coalesce(p_limite, 8), 20));
  return v_res;
end;
$$;
revoke execute on function public.foto_candidatas(text, text, text, integer) from public, anon;
grant execute on function public.foto_candidatas(text, text, text, integer) to authenticated, service_role;
