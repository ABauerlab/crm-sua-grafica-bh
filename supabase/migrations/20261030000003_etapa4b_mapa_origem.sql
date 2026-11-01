-- Etapa 4B (ajuste): mapa código -> imagem da origem, candidatas por SKU/termo e relatório de cobertura.
-- O código do item na origem é igual ao nosso SKU. O mapa é INTERNO (só o dono lê) e não guarda preço nem custo.
-- Aditiva e idempotente.

create table if not exists public.produto_fotos_mapa (
  sku text primary key,
  topo text not null,                 -- categoria do menu da origem
  caminho text not null,              -- caminho do item (categoria/subcategoria/.../código), usado só para combinar com o termo
  imagem text not null,                
  grupo_produto text,                 -- grupo do NOSSO catálogo (pelo SKU)
  atualizado_em timestamptz not null default now()
);
create index if not exists produto_fotos_mapa_grupo_idx on public.produto_fotos_mapa (grupo_produto);
create index if not exists produto_fotos_mapa_guid_idx on public.produto_fotos_mapa (imagem);
alter table public.produto_fotos_mapa enable row level security;
revoke all on public.produto_fotos_mapa from anon, authenticated;
grant select on public.produto_fotos_mapa to authenticated;
drop policy if exists produto_fotos_mapa_dono on public.produto_fotos_mapa;
create policy produto_fotos_mapa_dono on public.produto_fotos_mapa for select to authenticated using (private.is_staff());

-- Grava um lote do mapa (a Edge Function chama a cada página varrida). Código repetido em categoria promocional não troca o regular.
create or replace function public.foto_mapa_gravar(p_itens jsonb)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_n integer;
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  insert into public.produto_fotos_mapa (sku, topo, caminho, imagem, grupo_produto)
  select distinct on (upper(btrim(i ->> 'codigo'))) upper(btrim(i ->> 'codigo')), i ->> 'topo', i ->> 'caminho', i ->> 'imagem',
         (select c.grupo_produto from public.catalogo c where upper(c.sku) = upper(btrim(i ->> 'codigo')) and c.grupo_produto is not null limit 1)
    from jsonb_array_elements(p_itens) i
   where coalesce(btrim(i ->> 'codigo'), '') <> '' and coalesce(i ->> 'imagem', '') <> ''
   order by upper(btrim(i ->> 'codigo')), (i ->> 'topo' in ('black-friday', 'promocoes-', 'lancamentos', 'combos-de-produtos'))
  on conflict (sku) do update
     set topo = excluded.topo, caminho = excluded.caminho, imagem = excluded.imagem, grupo_produto = coalesce(excluded.grupo_produto, public.produto_fotos_mapa.grupo_produto), atualizado_em = now()
   where public.produto_fotos_mapa.topo in ('black-friday', 'promocoes-', 'lancamentos', 'combos-de-produtos') and excluded.topo not in ('black-friday', 'promocoes-', 'lancamentos', 'combos-de-produtos')
      or public.produto_fotos_mapa.imagem = excluded.imagem;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.foto_mapa_gravar(jsonb) from public, anon;
grant execute on function public.foto_mapa_gravar(jsonb) to authenticated, service_role;

-- Candidatas para um pedido: o SKU exato primeiro, depois itens do grupo que combinam com o termo, depois variedade do grupo.
create or replace function public.foto_candidatas(p_grupo text, p_sku text default null, p_termo text default null, p_limite integer default 8)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_tokens text[]; v_res jsonb;
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  select coalesce(array_agg(t), '{}') into v_tokens from unnest(string_to_array(private.norm_busca(coalesce(p_termo, '')), ' ')) t where length(t) >= 4;
  select coalesce(jsonb_agg(jsonb_build_object('imagem', imagem, 'caminho', caminho, 'exato', exato, 'score', score) order by exato desc, score desc, ordem), '[]'::jsonb) into v_res
  from (
    select distinct on (m.imagem) m.imagem, m.caminho,
           (p_sku is not null and m.sku = upper(btrim(p_sku))) as exato,
           (select count(*) from unnest(v_tokens) t where private.norm_busca(m.caminho) like '%' || t || '%') as score,
           hashtext(m.imagem) as ordem
      from public.produto_fotos_mapa m
     where m.grupo_produto = p_grupo or (p_sku is not null and m.sku = upper(btrim(p_sku)))
     order by m.imagem, (p_sku is not null and m.sku = upper(btrim(p_sku))) desc
  ) x
  limit greatest(1, least(coalesce(p_limite, 8), 20));
  return v_res;
end;
$$;
revoke execute on function public.foto_candidatas(text, text, text, integer) from public, anon;
grant execute on function public.foto_candidatas(text, text, text, integer) to authenticated, service_role;

-- Cobertura por grupo do catálogo: SKUs, SKUs com imagem na origem, fotos aprovadas guardadas, baixa qualidade
create or replace function public.fotos_cobertura()
returns table (grupo_produto text, skus bigint, skus_com_imagem bigint, pct_com_imagem numeric, fotos_aprovadas bigint, baixa_qualidade bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_staff() and coalesce(auth.role(), '') <> 'service_role' then raise exception 'Só o dono.' using errcode = '42501'; end if;
  return query
  select c.grupo_produto, count(distinct upper(c.sku)), count(distinct upper(c.sku)) filter (where m.sku is not null),
         round(100.0 * count(distinct upper(c.sku)) filter (where m.sku is not null) / nullif(count(distinct upper(c.sku)), 0), 1),
         (select count(*) from public.produto_fotos f where f.grupo_produto = c.grupo_produto and f.status = 'aprovada'),
         (select count(*) from public.produto_fotos f where f.grupo_produto = c.grupo_produto and f.baixa_qualidade)
    from public.catalogo c left join public.produto_fotos_mapa m on m.sku = upper(c.sku)
   where c.grupo_produto is not null and c.sku is not null
   group by c.grupo_produto
   order by 4 asc nulls first, 2 desc;
end;
$$;
revoke execute on function public.fotos_cobertura() from public, anon;
grant execute on function public.fotos_cobertura() to authenticated, service_role;

-- SKUs do catálogo que a varredura não encontrou (para completar pelo catálogo em PDF ou à mão)
create or replace function public.fotos_skus_sem_imagem(p_grupo text default null)
returns table (sku text, grupo_produto text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.is_staff() and coalesce(auth.role(), '') <> 'service_role' then raise exception 'Só o dono.' using errcode = '42501'; end if;
  return query
  select distinct upper(c.sku), c.grupo_produto from public.catalogo c
   where c.sku is not null and c.grupo_produto is not null and (p_grupo is null or c.grupo_produto = p_grupo)
     and not exists (select 1 from public.produto_fotos_mapa m where m.sku = upper(c.sku))
   order by 2, 1;
end;
$$;
revoke execute on function public.fotos_skus_sem_imagem(text) from public, anon;
grant execute on function public.fotos_skus_sem_imagem(text) to authenticated, service_role;

-- Qualidade e origem da imagem guardada
alter table public.produto_fotos add column if not exists baixa_qualidade boolean not null default false;
alter table public.produto_fotos add column if not exists fonte text not null default 'site';   -- site | catalogo_pdf | manual
alter table public.produto_fotos add column if not exists sku text;                              -- SKU exato quando a foto é do item
create index if not exists produto_fotos_sku_idx on public.produto_fotos (sku) where sku is not null;

-- foto_registrar ganha qualidade, fonte e SKU (a versão antiga continua funcionando)
create or replace function public.foto_registrar(p_grupo text, p_url_origem text, p_arquivo text, p_largura integer, p_altura integer, p_bytes integer, p_hash text, p_aproximada boolean, p_ordem integer, p_baixa_qualidade boolean, p_fonte text, p_sku text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  insert into public.produto_fotos (grupo_produto, url_origem, arquivo_storage, largura, altura, bytes, hash, status, aproximada, ordem, baixa_qualidade, fonte, sku)
    values (p_grupo, p_url_origem, p_arquivo, p_largura, p_altura, p_bytes, p_hash, 'pendente', coalesce(p_aproximada, true), coalesce(p_ordem, 0), coalesce(p_baixa_qualidade, false), coalesce(p_fonte, 'site'), upper(nullif(btrim(p_sku), '')))
    on conflict (grupo_produto, hash) where hash is not null do update set atualizado_em = now(), sku = coalesce(public.produto_fotos.sku, excluded.sku)
    returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.foto_registrar(text, text, text, integer, integer, integer, text, boolean, integer, boolean, text, text) from public, anon;
grant execute on function public.foto_registrar(text, text, text, integer, integer, integer, text, boolean, integer, boolean, text, text) to authenticated, service_role;

-- foto_aprovadas: prefere a foto do SKU exato, depois a de melhor qualidade (substitui a versão de 2 argumentos para não haver chamada ambígua)
drop function if exists public.foto_aprovadas(text, integer);
create or replace function public.foto_aprovadas(p_grupo text, p_quantidade integer, p_sku text default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Só o dono ou o servidor.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'arquivo', arquivo_storage, 'bytes', bytes, 'aproximada', (aproximada or (p_sku is not null and coalesce(sku, '') <> upper(btrim(p_sku)))), 'baixa_qualidade', baixa_qualidade))
    from (select * from public.produto_fotos where grupo_produto = p_grupo and status = 'aprovada' and arquivo_storage is not null
          order by coalesce(p_sku is not null and sku = upper(btrim(p_sku)), false) desc, baixa_qualidade, aproximada, ordem, criado_em limit greatest(1, least(coalesce(p_quantidade, 1), 3))) x), '[]'::jsonb);
end;
$$;
revoke execute on function public.foto_aprovadas(text, integer, text) from public, anon;
grant execute on function public.foto_aprovadas(text, integer, text) to authenticated, service_role;
