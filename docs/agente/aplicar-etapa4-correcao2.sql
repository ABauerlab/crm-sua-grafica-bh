-- Etapa 4, correção 2: cole inteiro no SQL Editor do Supabase (idempotente). É a migration 20261029000011.
-- Cria dois invólucros para a Edge Function orcamento-pdf (validar a margem e marcar como enviado), porque a service role não alcança o schema private.

-- Etapa 4 (correção): a Edge Function orcamento-pdf valida a margem antes de enviar o PDF, chamando o banco com a service role.
-- validar_margem é SECURITY INVOKER e usa funções do schema private, onde a service role não tem acesso ("permission denied for schema private").
-- Este invólucro roda com os direitos do dono do banco, confere quem chama (dono ou servidor) e devolve o mesmo resultado. Aditivo e idempotente.
create or replace function public.orcamento_validar_margem(p_orcamento uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  return public.validar_margem(p_orcamento);
end;
$$;
revoke execute on function public.orcamento_validar_margem(uuid) from public, anon;
grant execute on function public.orcamento_validar_margem(uuid) to authenticated, service_role;

-- Marcar como enviado dispara a trava de lucro do banco, que também usa o schema private (a service role não alcança direto).
create or replace function public.orcamento_marcar_enviado(p_orcamento uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.orcamentos set status = 'enviado' where id = p_orcamento and status = 'rascunho';
  return jsonb_build_object('ok', true, 'status', (select status from public.orcamentos where id = p_orcamento));
exception when sqlstate 'P0001' or sqlstate '23514' then
  return jsonb_build_object('ok', false, 'erro', sqlerrm);
end;
$$;
revoke execute on function public.orcamento_marcar_enviado(uuid) from public, anon;
grant execute on function public.orcamento_marcar_enviado(uuid) to authenticated, service_role;
