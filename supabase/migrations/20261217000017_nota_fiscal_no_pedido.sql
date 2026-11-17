-- Dados da nota fiscal ficam no contato e no pedido: orders.dados_fiscais (jsonb) e gatilho
-- private.fiscal_copiar_para_pedido (copia nome/razão, documento, e-mail, CEP e endereço do contato com quer_nota_fiscal
-- para o pedido mais recente). Aplicada pelo conector. Aditiva e idempotente.
alter table public.orders add column if not exists dados_fiscais jsonb;
create or replace function private.fiscal_copiar_para_pedido() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_dados jsonb;
begin
  if coalesce(new.quer_nota_fiscal, false) = false then return new; end if;
  v_dados := jsonb_strip_nulls(jsonb_build_object(
    'nome', coalesce(nullif(btrim(new.company), ''), new.name), 'documento', nullif(btrim(new.document), ''), 'email', nullif(btrim(new.email), ''),
    'cep', nullif(btrim(new.cep), ''), 'endereco', nullif(btrim(new.address), ''), 'atualizado_em', now()));
  update public.orders o set dados_fiscais = v_dados
   where o.id = (select o2.id from public.orders o2 where o2.contact_id = new.id and o2.excluido_em is null order by o2.created_at desc limit 1);
  return new;
end $$;
revoke all on function private.fiscal_copiar_para_pedido() from public, anon, authenticated;
drop trigger if exists trg_fiscal_copiar_para_pedido on public.contacts;
create trigger trg_fiscal_copiar_para_pedido after update of quer_nota_fiscal, document, email, cep, address, company, name on public.contacts
  for each row execute function private.fiscal_copiar_para_pedido();
