-- E-commerce Fase 2: ficha técnica, acabamento padrão, texto e foto de cada produto, lidos da origem interna do catálogo.
-- Uma página por "produto" (o caminho sem o último segmento, que é o SKU), não por SKU: ~3.800 páginas.
-- A origem fica só em app_settings.fotos.origem_base; nada aqui a identifica. Processamento pela Edge Function loja-fichas
-- (agendada a cada minuto, 20 páginas por vez, uma a cada 2 s). A ficha vai para ecommerce_products já em linguagem de balcão.

create or replace function private.loja_chave(p_caminho text)
returns text language sql immutable set search_path = '' as $$
  select regexp_replace(coalesce(p_caminho, ''), '/[^/]+/?$', '');
$$;

create table if not exists public.loja_fichas (
  chave text primary key,
  sku_amostra text not null,
  caminho text not null,
  imagem_origem text,
  status text not null default 'pendente' check (status in ('pendente', 'processando', 'ok', 'erro')),
  tentativas integer not null default 0,
  erro text,
  ficha jsonb,
  ficha_balcao jsonb,
  foto_path text,
  marca_ok boolean,
  atualizado_em timestamptz not null default now()
);
create index if not exists loja_fichas_status_idx on public.loja_fichas (status, atualizado_em);
alter table public.loja_fichas enable row level security;
revoke all on public.loja_fichas from anon, authenticated;
grant select on public.loja_fichas to authenticated;
drop policy if exists loja_fichas_dono on public.loja_fichas;
create policy loja_fichas_dono on public.loja_fichas for select to authenticated using (private.is_staff());

-- uma linha por produto (menor SKU do grupo como amostra)
insert into public.loja_fichas (chave, sku_amostra, caminho, imagem_origem)
select distinct on (private.loja_chave(m.caminho)) private.loja_chave(m.caminho), m.sku, m.caminho, m.imagem
  from public.produto_fotos_mapa m
 where m.caminho is not null and private.loja_chave(m.caminho) <> ''
 order by private.loja_chave(m.caminho), m.sku
on conflict (chave) do nothing;

-- bucket PÚBLICO das fotos da loja (nomes neutros por hash; o bucket produto-fotos do WhatsApp continua privado)
insert into storage.buckets (id, name, public)
values ('loja-produtos', 'loja-produtos', true)
on conflict (id) do update set public = true;

insert into public.app_settings (key, value)
values ('loja_fichas', jsonb_build_object('ligado', true, 'por_execucao', 20, 'intervalo_ms', 2000, 'verificar_marca', true))
on conflict (key) do nothing;

-- O título da ficha (linguagem de balcão) vale mais que o título montado da descrição do catálogo, mesmo depois de nova sincronização.
create or replace function private.ecommerce_titulo_da_ficha()
returns trigger language plpgsql set search_path = '' as $$
begin
  if coalesce(new.ficha ->> 'titulo', '') <> '' then new.titulo := new.ficha ->> 'titulo'; end if;
  return new;
end $$;
drop trigger if exists ecommerce_titulo_da_ficha on public.ecommerce_products;
create trigger ecommerce_titulo_da_ficha before insert or update on public.ecommerce_products
  for each row execute function private.ecommerce_titulo_da_ficha();

-- Pega o próximo lote (só service role). Reprocessa erro até 3 vezes e destrava "processando" parado há 15 min.
create or replace function public.loja_fichas_pegar(p_n integer default 20)
returns table (chave text, caminho text, imagem_origem text)
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return query
  update public.loja_fichas f set status = 'processando', tentativas = f.tentativas + 1, atualizado_em = now()
   where f.chave in (
     select x.chave from public.loja_fichas x
      where x.status = 'pendente'
         or (x.status = 'erro' and x.tentativas < 3)
         or (x.status = 'processando' and x.atualizado_em < now() - interval '15 minutes' and x.tentativas < 3)
      order by x.status = 'pendente' desc, x.atualizado_em
      limit least(greatest(coalesce(p_n, 20), 1), 50)
      for update skip locked)
  returning f.chave, f.caminho, f.imagem_origem;
end $$;
revoke all on function public.loja_fichas_pegar(integer) from public, anon, authenticated;
grant execute on function public.loja_fichas_pegar(integer) to service_role;

-- Grava o resultado de um produto e aplica a todos os SKUs dele na vitrine (só service role).
create or replace function public.loja_ficha_gravar(p_chave text, p_ficha jsonb, p_balcao jsonb, p_foto text, p_marca_ok boolean, p_erro text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n integer := 0; v_url text;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.loja_fichas set
    status = case when p_erro is null then 'ok' else 'erro' end,
    erro = left(p_erro, 300), ficha = coalesce(p_ficha, ficha), ficha_balcao = coalesce(p_balcao, ficha_balcao),
    foto_path = coalesce(p_foto, foto_path), marca_ok = coalesce(p_marca_ok, marca_ok), atualizado_em = now()
  where chave = p_chave;
  if p_erro is null and p_balcao is not null then
    v_url := case when p_foto is not null then 'loja-produtos/' || p_foto end;
    update public.ecommerce_products e set
      ficha = p_balcao,
      acabamentos = case when coalesce(p_balcao ->> 'acabamento', '') <> '' then jsonb_build_array(p_balcao ->> 'acabamento') else e.acabamentos end,
      fotos = case when v_url is not null then jsonb_build_array(v_url) else e.fotos end,
      atualizado_em = now()
    from public.produto_fotos_mapa m
    where m.sku = e.sku and private.loja_chave(m.caminho) = p_chave;
    get diagnostics v_n = row_count;
  end if;
  return jsonb_build_object('ok', true, 'skus', v_n);
end $$;
revoke all on function public.loja_ficha_gravar(text, jsonb, jsonb, text, boolean, text) from public, anon, authenticated;
grant execute on function public.loja_ficha_gravar(text, jsonb, jsonb, text, boolean, text) to service_role;

create or replace function public.loja_fichas_resumo()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'total', count(*),
    'ok', count(*) filter (where status = 'ok'),
    'pendente', count(*) filter (where status = 'pendente'),
    'processando', count(*) filter (where status = 'processando'),
    'erro', count(*) filter (where status = 'erro'),
    'com_foto', count(*) filter (where foto_path is not null),
    'foto_com_marca', count(*) filter (where marca_ok = false))
  from public.loja_fichas
  where private.dono_ou_servidor();
$$;
revoke all on function public.loja_fichas_resumo() from public, anon;
grant execute on function public.loja_fichas_resumo() to authenticated, service_role;
