-- Prazo de entrega: conta a partir do pagamento confirmado, em dias úteis (sem sábado, domingo e feriados),
-- mais os dias extras de margem (padrão 1). Calculado no banco para sair igual no CRM e no agente de IA.

create table if not exists public.holidays (
  day date primary key,
  name text not null,
  scope text not null default 'nacional' check (scope in ('nacional', 'belo_horizonte', 'gráfica'))
);
alter table public.holidays enable row level security;
drop policy if exists holidays_select on public.holidays;
create policy holidays_select on public.holidays for select to authenticated using (private.is_staff());
drop policy if exists holidays_insert on public.holidays;
create policy holidays_insert on public.holidays for insert to authenticated with check (private.is_admin());
drop policy if exists holidays_update on public.holidays;
create policy holidays_update on public.holidays for update to authenticated using (private.is_admin()) with check (private.is_admin());
drop policy if exists holidays_delete on public.holidays;
create policy holidays_delete on public.holidays for delete to authenticated using (private.is_admin());

insert into public.holidays (day, name, scope) values
  ('2026-01-01', 'Confraternização Universal', 'nacional'),
  ('2026-02-16', 'Carnaval (segunda)', 'nacional'),
  ('2026-02-17', 'Carnaval (terça)', 'nacional'),
  ('2026-04-03', 'Sexta-feira Santa', 'nacional'),
  ('2026-04-21', 'Tiradentes', 'nacional'),
  ('2026-05-01', 'Dia do Trabalho', 'nacional'),
  ('2026-06-04', 'Corpus Christi', 'nacional'),
  ('2026-08-15', 'Assunção de Nossa Senhora (sábado)', 'belo_horizonte'),
  ('2026-09-07', 'Independência do Brasil', 'nacional'),
  ('2026-10-12', 'Nossa Senhora Aparecida', 'nacional'),
  ('2026-11-02', 'Finados', 'nacional'),
  ('2026-11-15', 'Proclamação da República', 'nacional'),
  ('2026-11-20', 'Consciência Negra', 'nacional'),
  ('2026-12-08', 'Imaculada Conceição', 'belo_horizonte'),
  ('2026-12-25', 'Natal', 'nacional'),
  ('2027-01-01', 'Confraternização Universal', 'nacional'),
  ('2027-02-08', 'Carnaval (segunda)', 'nacional'),
  ('2027-02-09', 'Carnaval (terça)', 'nacional'),
  ('2027-03-26', 'Sexta-feira Santa', 'nacional'),
  ('2027-04-21', 'Tiradentes', 'nacional'),
  ('2027-05-01', 'Dia do Trabalho', 'nacional'),
  ('2027-05-27', 'Corpus Christi', 'nacional'),
  ('2027-08-15', 'Assunção de Nossa Senhora (domingo)', 'belo_horizonte'),
  ('2027-09-07', 'Independência do Brasil', 'nacional'),
  ('2027-10-12', 'Nossa Senhora Aparecida', 'nacional'),
  ('2027-11-02', 'Finados', 'nacional'),
  ('2027-11-15', 'Proclamação da República', 'nacional'),
  ('2027-11-20', 'Consciência Negra (sábado)', 'nacional'),
  ('2027-12-08', 'Imaculada Conceição', 'belo_horizonte'),
  ('2027-12-25', 'Natal (sábado)', 'nacional')
on conflict (day) do nothing;

insert into public.app_settings (key, value) values ('deadline', '{"extra_days":1}') on conflict (key) do nothing;

-- Dia útil: não é sábado, domingo nem feriado cadastrado
create or replace function public.is_business_day(p_day date) returns boolean
language sql stable
set search_path = ''
as $$
  select extract(isodow from p_day) < 6 and not exists (select 1 from public.holidays h where h.day = p_day);
$$;

-- Conta p_days dias úteis depois de p_start (o próprio dia do pagamento não entra na conta)
create or replace function public.add_business_days(p_start date, p_days integer) returns date
language plpgsql stable
set search_path = ''
as $$
declare
  d date := p_start;
  n integer := greatest(coalesce(p_days, 0), 0);
begin
  while n > 0 loop
    d := d + 1;
    if public.is_business_day(d) then
      n := n - 1;
    end if;
  end loop;
  return d;
end;
$$;

-- Prazo no pedido: calculado ao confirmar o pagamento e recalculado se o prazo dos itens mudar, exceto se a data foi ajustada à mão
alter table public.orders add column if not exists due_date_manual boolean not null default false;

create or replace function private.orders_set_due_date() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_paid timestamptz := coalesce(new.payment_confirmed_at, case when new.payment_status = 'aprovado' then now() end);
  v_extra integer := coalesce((select (value ->> 'extra_days')::integer from public.app_settings where key = 'deadline'), 1);
begin
  if v_paid is not null and new.lead_days is not null and not new.due_date_manual then
    new.due_date := public.add_business_days((v_paid at time zone 'America/Sao_Paulo')::date, new.lead_days + v_extra);
  end if;
  return new;
end;
$$;

drop trigger if exists orders_set_due_date on public.orders;
create trigger orders_set_due_date before update on public.orders
  for each row execute function private.orders_set_due_date();

revoke execute on function public.is_business_day(date), public.add_business_days(date, integer) from public, anon;
grant execute on function public.is_business_day(date), public.add_business_days(date, integer) to authenticated, service_role;
