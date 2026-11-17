-- Marcador "faltam dados da NF" no pedido pago e endereço completo pelo CEP.
-- contato_nf_faltantes lista o que ainda falta para o Bling emitir a nota (chaves: nome, documento, email, cep, numero, endereco).
-- 'endereco' = rua, bairro, cidade, UF ou código IBGE vazios com CEP já informado (a função contato-cep-completar preenche).
-- nf_faltantes(pedido) é coluna calculada do PostgREST: só devolve algo para pedido pago, não cancelado nem excluído.
-- Aditiva e idempotente.
alter table public.cep_bairros add column if not exists codigo_ibge text;

create or replace function public.contato_nf_faltantes(c public.contacts)
returns text[] language sql stable set search_path = '' as $$
  select array_remove(array[
    case when array_length(regexp_split_to_array(btrim(coalesce(nullif(btrim(c.company), ''), c.name, '')), '\s+'), 1) < 2
              or btrim(coalesce(nullif(btrim(c.company), ''), c.name, '')) = '' then 'nome' end,
    case when length(regexp_replace(coalesce(c.document, ''), '\D', '', 'g')) not in (11, 14) then 'documento' end,
    case when coalesce(c.email, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then 'email' end,
    case when length(regexp_replace(coalesce(c.cep, ''), '\D', '', 'g')) <> 8 then 'cep' end,
    case when nullif(btrim(coalesce(c.numero, '')), '') is null then 'numero' end,
    case when length(regexp_replace(coalesce(c.cep, ''), '\D', '', 'g')) = 8
              and (nullif(btrim(coalesce(c.logradouro, '')), '') is null or nullif(btrim(coalesce(c.bairro, '')), '') is null
                   or nullif(btrim(coalesce(c.municipio, '')), '') is null or nullif(btrim(coalesce(c.uf, '')), '') is null
                   or nullif(btrim(coalesce(c.codigo_ibge, '')), '') is null) then 'endereco' end
  ], null);
$$;

create or replace function public.nf_faltantes(o public.orders)
returns text[] language sql stable set search_path = '' as $$
  select case when (o.payment_status = 'aprovado' or o.payment_manual) and o.cancelado_em is null and o.excluido_em is null and coalesce(o.teste, false) = false
              then coalesce((select public.contato_nf_faltantes(c) from public.contacts c where c.id = o.contact_id), '{}'::text[])
              else '{}'::text[] end;
$$;

revoke all on function public.contato_nf_faltantes(public.contacts) from public, anon;
revoke all on function public.nf_faltantes(public.orders) from public, anon;
grant execute on function public.contato_nf_faltantes(public.contacts) to authenticated, service_role;
grant execute on function public.nf_faltantes(public.orders) to authenticated, service_role;
