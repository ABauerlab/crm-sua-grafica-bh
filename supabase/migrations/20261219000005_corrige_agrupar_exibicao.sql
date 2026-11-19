-- 19/11/2026: corrige private.orcamento_agrupar_exibicao (coluna area_m2). Aditiva e idempotente.
create or replace function private.orcamento_agrupar_exibicao(p_orc uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_exib jsonb;
begin
  if not exists (select 1 from public.orcamento_itens i where i.orcamento_id = p_orc
                  group by i.descricao, regexp_replace(coalesce(i.especificacao, ''), '^\s*[0-9.]+\s*un\.?\s*·\s*', '') having count(*) > 1) then
    return;
  end if;
  select jsonb_agg(jsonb_build_object('descricao', g.descricao, 'especificacao', g.espec, 'quantidade', g.unidades, 'acabamento', g.acabamento,
                                      'area_m2', g.area_m2, 'valor_unitario', round(g.total / g.unidades, 4), 'valor_total', round(g.total, 2)) order by g.ordem)
    into v_exib
    from (select i.descricao, regexp_replace(coalesce(i.especificacao, ''), '^\s*[0-9.]+\s*un\.?\s*·\s*', '') as espec, i.acabamento, i.area_m2,
                 sum(coalesce(i.unidades_cliente, i.quantidade * coalesce(c.quantidade, 1))) as unidades,
                 sum(i.quantidade * i.preco_unitario) as total, min(i.criado_em) as ordem
            from public.orcamento_itens i left join public.catalogo c on c.sku = i.sku
           where i.orcamento_id = p_orc group by 1, 2, 3, 4) g;
  if v_exib is not null and jsonb_array_length(v_exib) between 1 and 30 then
    update public.orcamentos set itens_exibicao = v_exib where id = p_orc;
  end if;
end $$;
revoke all on function private.orcamento_agrupar_exibicao(uuid) from public, anon, authenticated;
