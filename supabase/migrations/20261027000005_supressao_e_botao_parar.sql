-- Lista de supressão: quem pediu para parar continua respeitado mesmo se o contato for excluído e voltar a falar conosco.
create table public.marketing_suppressions (
  wa_id text primary key check (wa_id ~ '^[0-9]+$'),
  created_at timestamptz not null default now()
);

alter table public.marketing_suppressions enable row level security;
create policy marketing_suppressions_select on public.marketing_suppressions
  for select to authenticated using (private.is_staff());

-- Ao excluir um contato que pediu para parar, guarda só o telefone na lista de supressão.
-- Se ele tinha voltado a autorizar, a entrada antiga é removida.
create function private.keep_opt_out_on_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.marketing_consent = 'opted_out' then
    insert into public.marketing_suppressions (wa_id) values (old.wa_id) on conflict do nothing;
  else
    delete from public.marketing_suppressions where wa_id = old.wa_id;
  end if;
  return old;
end;
$$;

-- Contato recriado (ex.: cliente volta a escrever) nasce já como "pediu para parar".
create function private.apply_suppression_on_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.marketing_suppressions where wa_id = new.wa_id) then
    new.marketing_consent := 'opted_out';
    new.marketing_consent_at := now();
    new.marketing_consent_source := 'whatsapp';
  end if;
  return new;
end;
$$;

revoke execute on function private.keep_opt_out_on_delete() from public, anon, authenticated;
revoke execute on function private.apply_suppression_on_insert() from public, anon, authenticated;

create trigger contacts_keep_opt_out before delete on public.contacts
  for each row execute function private.keep_opt_out_on_delete();
create trigger contacts_apply_suppression before insert on public.contacts
  for each row execute function private.apply_suppression_on_insert();

-- Templates de marketing devem ter um botão de resposta rápida para parar as promoções.
alter table public.templates_cache
  add column has_opt_out_button boolean not null default false;
