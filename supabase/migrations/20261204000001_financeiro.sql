-- Financeiro: lançamentos de receita e despesa (só admin) e resumo do período somando o lucro líquido dos pedidos pagos. Aditiva e idempotente (já aplicada).
create table if not exists public.financeiro_lancamentos (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('receita', 'despesa')),
  categoria text not null,
  descricao text,
  valor numeric(12, 2) not null check (valor > 0),
  data date not null default current_date,
  pago boolean not null default true,
  criado_por uuid default auth.uid(),
  criado_em timestamptz not null default now()
);
create index if not exists financeiro_lancamentos_data_idx on public.financeiro_lancamentos (data);
alter table public.financeiro_lancamentos enable row level security;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'financeiro_lancamentos' and policyname = 'financeiro_admin') then
    create policy financeiro_admin on public.financeiro_lancamentos for all to authenticated using (private.is_admin()) with check (private.is_admin());
  end if;
end $p$;

create or replace function public.financeiro_resumo(p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_ped jsonb; v_cat jsonb; v_mes jsonb; v_lucro numeric; v_rec numeric; v_desp numeric;
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  select jsonb_build_object('pedidos', count(*), 'faturamento', coalesce(sum(f.total), 0), 'custo', coalesce(sum(f.cost), 0),
         'impostos', coalesce(sum(f.tax), 0), 'taxas', coalesce(sum(f.fee), 0), 'lucro', coalesce(sum(f.net_profit), 0))
    into v_ped
    from public.orders o join public.order_financials f on f.order_id = o.id
   where o.payment_status = 'aprovado' and coalesce(o.teste, false) = false
     and (coalesce(o.paid_at, o.created_at) at time zone 'America/Sao_Paulo')::date between p_de and p_ate;
  select coalesce(sum(valor) filter (where tipo = 'receita'), 0), coalesce(sum(valor) filter (where tipo = 'despesa'), 0)
    into v_rec, v_desp from public.financeiro_lancamentos where data between p_de and p_ate;
  v_lucro := (v_ped ->> 'lucro')::numeric;
  select coalesce(jsonb_agg(jsonb_build_object('categoria', categoria, 'tipo', tipo, 'total', t) order by t desc), '[]'::jsonb)
    into v_cat from (select categoria, tipo, sum(valor) t from public.financeiro_lancamentos where data between p_de and p_ate group by categoria, tipo) q;
  select coalesce(jsonb_agg(jsonb_build_object('mes', m, 'lucro_pedidos', lp, 'receitas', r, 'despesas', d) order by m), '[]'::jsonb)
    into v_mes from (
      select to_char(x.mes, 'YYYY-MM') m,
             coalesce((select sum(f.net_profit) from public.orders o join public.order_financials f on f.order_id = o.id
                        where o.payment_status = 'aprovado' and coalesce(o.teste, false) = false
                          and date_trunc('month', (coalesce(o.paid_at, o.created_at) at time zone 'America/Sao_Paulo')) = x.mes), 0) lp,
             coalesce((select sum(valor) from public.financeiro_lancamentos l where l.tipo = 'receita' and date_trunc('month', l.data) = x.mes), 0) r,
             coalesce((select sum(valor) from public.financeiro_lancamentos l where l.tipo = 'despesa' and date_trunc('month', l.data) = x.mes), 0) d
        from generate_series(date_trunc('month', p_ate::timestamp) - interval '5 months', date_trunc('month', p_ate::timestamp), interval '1 month') x(mes)) z;
  return jsonb_build_object('pedidos', v_ped, 'manual', jsonb_build_object('receitas', v_rec, 'despesas', v_desp), 'categorias', v_cat, 'meses', v_mes,
                            'resultado', v_lucro + v_rec - v_desp);
end $$;
revoke execute on function public.financeiro_resumo(date, date) from public, anon;
grant execute on function public.financeiro_resumo(date, date) to authenticated;
