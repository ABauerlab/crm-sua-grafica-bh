-- Financeiro: saldo manual. O dono lança entradas e despesas até o saldo bater com o do Mercado Pago (conferência dele).
-- financeiro_saldo_manual devolve receitas, despesas e saldo de todos os lançamentos, mais o último saldo informado do Mercado Pago.
-- financeiro_saldo_informar guarda o saldo que o dono leu no Mercado Pago, para mostrar a diferença. Só o dono. Aditiva e idempotente.
create or replace function public.financeiro_saldo_manual()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_rec numeric; v_desp numeric; v_cfg jsonb;
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  select coalesce(sum(valor) filter (where tipo = 'receita'), 0), coalesce(sum(valor) filter (where tipo = 'despesa'), 0)
    into v_rec, v_desp from public.financeiro_lancamentos;
  select value into v_cfg from public.app_settings where key = 'financeiro';
  return jsonb_build_object('receitas', v_rec, 'despesas', v_desp, 'saldo', v_rec - v_desp,
    'saldo_mp', v_cfg -> 'saldo_mp', 'saldo_mp_em', v_cfg -> 'saldo_mp_em');
end $$;

create or replace function public.financeiro_saldo_informar(p_valor numeric)
returns void language plpgsql security definer set search_path = '' as $$
declare v_atual jsonb;
begin
  if not private.is_admin() then raise exception 'sem_permissao'; end if;
  select coalesce(value, '{}'::jsonb) into v_atual from public.app_settings where key = 'financeiro';
  insert into public.app_settings (key, value)
  values ('financeiro', coalesce(v_atual, '{}'::jsonb) || jsonb_build_object('saldo_mp', p_valor, 'saldo_mp_em', now()))
  on conflict (key) do update set value = excluded.value;
end $$;

revoke all on function public.financeiro_saldo_manual() from public, anon;
revoke all on function public.financeiro_saldo_informar(numeric) from public, anon;
grant execute on function public.financeiro_saldo_manual() to authenticated;
grant execute on function public.financeiro_saldo_informar(numeric) to authenticated;
