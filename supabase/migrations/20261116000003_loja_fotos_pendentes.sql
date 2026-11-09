-- E-commerce Fase 2 (ajuste): a função estourava o limite de CPU decodificando 20 fotos por vez.
-- Agora a foto leve só tem os metadados limpos (sem decodificar) e a pesada é recomprimida no máximo 2 por execução;
-- as que sobram ficam com foto_path nulo e voltam por loja_fotos_pegar.
alter table public.loja_fichas add column if not exists foto_tentativas integer not null default 0;

create or replace function public.loja_fotos_pegar(p_n integer default 2)
returns table (chave text, imagem_origem text)
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return query
  update public.loja_fichas f set foto_tentativas = f.foto_tentativas + 1
   where f.chave in (
     select x.chave from public.loja_fichas x
      where x.status = 'ok' and x.foto_path is null and x.imagem_origem is not null and x.foto_tentativas < 2
      order by x.foto_tentativas, x.atualizado_em
      limit least(greatest(coalesce(p_n, 2), 1), 5)
      for update skip locked)
  returning f.chave, f.imagem_origem;
end $$;
revoke all on function public.loja_fotos_pegar(integer) from public, anon, authenticated;
grant execute on function public.loja_fotos_pegar(integer) to service_role;

create or replace function public.loja_foto_gravar(p_chave text, p_foto text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n integer := 0;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if p_foto is null then return jsonb_build_object('ok', true, 'skus', 0); end if;
  update public.loja_fichas set foto_path = p_foto where chave = p_chave;
  update public.ecommerce_products e set fotos = jsonb_build_array('loja-produtos/' || p_foto), atualizado_em = now()
    from public.produto_fotos_mapa m
   where m.sku = e.sku and private.loja_chave(m.caminho) = p_chave;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'skus', v_n);
end $$;
revoke all on function public.loja_foto_gravar(text, text) from public, anon, authenticated;
grant execute on function public.loja_foto_gravar(text, text) to service_role;

-- as execuções derrubadas pelo limite gastaram tentativas sem culpa do produto: volta tudo que não terminou para a fila
update public.loja_fichas set status = 'pendente', tentativas = 0 where status in ('processando', 'erro');
update public.app_settings set value = value || jsonb_build_object('por_execucao', 15) where key = 'loja_fichas';
