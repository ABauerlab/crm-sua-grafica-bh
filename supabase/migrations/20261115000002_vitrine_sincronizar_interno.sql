-- A vitrine é sincronizada por aplicar_planilha_precos (já autorizada por token ou dono): a parte interna
-- não confere permissão; a função pública continua exigindo dono ou service role.
create or replace function private.ecommerce_sincronizar_interno()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_up integer; v_off integer;
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
  on conflict (sku) do update set
    produto_slug = excluded.produto_slug, categoria = excluded.categoria, categoria_slug = excluded.categoria_slug, titulo = excluded.titulo,
    descricao = excluded.descricao, especificacao = excluded.especificacao, cores_rotulo = excluded.cores_rotulo, formato_rotulo = excluded.formato_rotulo,
    quantidade = excluded.quantidade, preco = excluded.preco, parcela_2x = excluded.parcela_2x, prazo_dias_uteis = excluded.prazo_dias_uteis,
    peso_kg = excluded.peso_kg, embalagem_cm = excluded.embalagem_cm, tipo_embalagem = excluded.tipo_embalagem, ativo = true, atualizado_em = now();
  get diagnostics v_up = row_count;
  update public.ecommerce_products e set ativo = false, atualizado_em = now()
   where e.ativo and not exists (select 1 from public.catalogo c where c.sku = e.sku and c.active and c.vendavel and c.preco_venda is not null);
  get diagnostics v_off = row_count;
  return jsonb_build_object('ok', true, 'na_vitrine', v_up, 'retirados', v_off);
end $$;
revoke all on function private.ecommerce_sincronizar_interno() from public, anon, authenticated;

create or replace function public.ecommerce_sincronizar()
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return private.ecommerce_sincronizar_interno();
end $$;
revoke all on function public.ecommerce_sincronizar() from public, anon;
grant execute on function public.ecommerce_sincronizar() to authenticated, service_role;

create or replace function public.aplicar_planilha_precos(p_token text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_atualizados integer; v_custos integer; v_travas integer; v_sem_catalogo integer; v_sem_preco integer; v_vitrine jsonb;
  v_exemplos_trava jsonb; v_exemplos_sem jsonb;
begin
  if not private.pode_importar_precos(p_token) then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;

  -- linhas que furariam a trava (custo x 1,5 ou lucro bruto mínimo) não entram: o SKU fica com a fórmula antiga e vai ao relatório
  select count(*), coalesce(jsonb_agg(s.sku) filter (where s.rn <= 20), '[]'::jsonb) into v_travas, v_exemplos_trava
    from (select p.sku, row_number() over (order by p.sku) rn from public.planilha_precos_import p
           where p.preco_venda < p.custo * pr.multiplicador_piso - 0.005 or p.preco_venda - p.custo < pr.lucro_bruto_minimo - 0.005) s;

  select count(*), coalesce(jsonb_agg(s.sku) filter (where s.rn <= 20), '[]'::jsonb) into v_sem_catalogo, v_exemplos_sem
    from (select p.sku, row_number() over (order by p.sku) rn from public.planilha_precos_import p
           where not exists (select 1 from public.catalogo c where c.sku = p.sku)) s;

  select count(*) into v_custos from public.catalogo c join public.planilha_precos_import p on p.sku = c.sku
   where abs(coalesce(c.custo, 0) - p.custo) > 0.005;

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
  where p.sku = c.sku
    and p.preco_venda >= p.custo * pr.multiplicador_piso - 0.005
    and p.preco_venda - p.custo >= pr.lucro_bruto_minimo - 0.005;
  get diagnostics v_atualizados = row_count;

  select count(*) into v_sem_preco from public.catalogo c where c.active and c.preco_venda is null;
  v_vitrine := private.ecommerce_sincronizar_interno();

  return jsonb_build_object('ok', true, 'atualizados', v_atualizados, 'custos_alterados', v_custos,
    'barrados_pela_trava', v_travas, 'exemplos_barrados', v_exemplos_trava,
    'planilha_sem_catalogo', v_sem_catalogo, 'exemplos_sem_catalogo', v_exemplos_sem,
    'catalogo_sem_preco_de_planilha', v_sem_preco, 'vitrine', v_vitrine);
end $$;
revoke all on function public.aplicar_planilha_precos(text) from public;
grant execute on function public.aplicar_planilha_precos(text) to authenticated, service_role, anon;
