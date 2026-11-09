-- A tela do CRM aplica a planilha em lotes (o usuário logado tem limite de 8 s por chamada;
-- aplicar as 20 mil linhas de uma vez leva cerca de 15 s). Aditiva: a função completa continua existindo.

-- Sincronização da vitrine só de alguns SKUs (null = todos).
create or replace function private.ecommerce_sincronizar_skus(p_skus text[])
returns integer language plpgsql security definer set search_path = '' as $$
declare v_up integer;
begin
  insert into public.ecommerce_products as e (sku, produto_slug, categoria, categoria_slug, titulo, descricao, especificacao, cores_rotulo,
                                              formato_rotulo, quantidade, preco, parcela_2x, prazo_dias_uteis, peso_kg, embalagem_cm, tipo_embalagem, ativo, atualizado_em)
  select c.sku,
         private.slugify(concat_ws(' ', private.titulo_vitrine(c.categoria, c.descricao), c.categoria, private.cores_rotulo(c.cores), c.tamanho_mm)),
         initcap(lower(c.categoria)), private.slugify(c.categoria),
         private.titulo_vitrine(c.categoria, c.descricao),
         initcap(lower(c.descricao)),
         private.traduzir_especificacao(c.cores, c.gramatura_g, c.tamanho_mm, c.descricao),
         private.cores_rotulo(c.cores), private.formato_rotulo(c.tamanho_mm), c.quantidade,
         c.preco_venda, round(c.preco_venda / 2, 2),
         coalesce(c.prazo_cliente_dias, c.prazo_dias_uteis + 1),
         coalesce(c.peso_frete_kg, round(c.peso_g / 1000.0, 3)), c.embalagem_cm, c.tipo_embalagem, true, now()
    from public.catalogo c
   where c.active and c.vendavel and c.preco_venda is not null and c.sku is not null
     and (p_skus is null or c.sku = any (p_skus))
  on conflict (sku) do update set
    produto_slug = excluded.produto_slug, categoria = excluded.categoria, categoria_slug = excluded.categoria_slug, titulo = excluded.titulo,
    descricao = excluded.descricao, especificacao = excluded.especificacao, cores_rotulo = excluded.cores_rotulo, formato_rotulo = excluded.formato_rotulo,
    quantidade = excluded.quantidade, preco = excluded.preco, parcela_2x = excluded.parcela_2x, prazo_dias_uteis = excluded.prazo_dias_uteis,
    peso_kg = excluded.peso_kg, embalagem_cm = excluded.embalagem_cm, tipo_embalagem = excluded.tipo_embalagem, ativo = true, atualizado_em = now();
  get diagnostics v_up = row_count;
  return v_up;
end $$;
revoke all on function private.ecommerce_sincronizar_skus(text[]) from public, anon, authenticated;

-- Aplica um lote da staging (ordem de SKU, depois de p_depois). Repetir até "fim" = true.
create or replace function public.aplicar_planilha_precos_lote(p_depois text default null, p_limite integer default 2000, p_token text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_skus text[]; v_ultimo text; v_n integer; v_vitrine integer; v_fim boolean;
begin
  if not private.pode_importar_precos(p_token) then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  select array_agg(s.sku order by s.sku), max(s.sku) into v_skus, v_ultimo
    from (select p.sku from public.planilha_precos_import p
           where p_depois is null or p.sku > p_depois
           order by p.sku limit least(greatest(coalesce(p_limite, 2000), 1), 3000)) s;
  if v_skus is null then return jsonb_build_object('ok', true, 'processados', 0, 'atualizados', 0, 'ultimo', p_depois, 'fim', true); end if;

  update public.catalogo c set
    custo = p.custo,
    preco_venda = p.preco_venda,
    preco_mercado_ref = p.preco_mercado,
    prazo_cliente_dias = p.prazo_cliente_dias,
    peso_frete_kg = round(p.peso_g / 1000.0, 3),
    embalagem_cm = p.embalagem_cm,
    tipo_embalagem = p.tipo_embalagem,
    estrategia_preco = p.estrategia,
    preco_planilha_em = now()
  from public.planilha_precos_import p
  where p.sku = any (v_skus) and private.sku_planilha(p.sku) = c.sku
    and p.preco_venda >= p.custo * pr.multiplicador_piso - 0.005
    and p.preco_venda - p.custo >= pr.lucro_bruto_minimo - 0.005;
  get diagnostics v_n = row_count;

  v_vitrine := private.ecommerce_sincronizar_skus(array(select private.sku_planilha(x) from unnest(v_skus) x));
  v_fim := not exists (select 1 from public.planilha_precos_import p where p.sku > v_ultimo);
  return jsonb_build_object('ok', true, 'processados', cardinality(v_skus), 'atualizados', v_n, 'na_vitrine', v_vitrine, 'ultimo', v_ultimo, 'fim', v_fim);
end $$;
revoke all on function public.aplicar_planilha_precos_lote(text, integer, text) from public;
grant execute on function public.aplicar_planilha_precos_lote(text, integer, text) to authenticated, service_role, anon;

-- Relatório da staging contra o catálogo (rápido; não altera nada).
create or replace function public.planilha_precos_relatorio()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare pr public.parametros_comerciais%rowtype;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  return jsonb_build_object(
    'na_staging', (select count(*) from public.planilha_precos_import),
    'barrados_pela_trava', (select count(*) from public.planilha_precos_import p
                             where p.preco_venda < p.custo * pr.multiplicador_piso - 0.005 or p.preco_venda - p.custo < pr.lucro_bruto_minimo - 0.005),
    'planilha_sem_catalogo', (select count(*) from public.planilha_precos_import p
                               where not exists (select 1 from public.catalogo c where c.sku = private.sku_planilha(p.sku))),
    'catalogo_sem_preco_de_planilha', (select count(*) from public.catalogo c where c.active and c.preco_venda is null),
    'na_vitrine', (select count(*) from public.ecommerce_products where ativo),
    'ultima_carga', (select max(importado_em) from public.planilha_precos_import));
end $$;
revoke all on function public.planilha_precos_relatorio() from public, anon;
grant execute on function public.planilha_precos_relatorio() to authenticated, service_role;
