-- 19/11/2026: Black Friday da gráfica inteira. Decisão do dono: todo pedido comprado até 30/11/2026 tem a criação de arte GRÁTIS.
-- Aditiva e idempotente. A arte não tem custo de fornecedor, então zerar o valor só tira receita extra: o piso de produto não muda.
-- Mecanismo: parametros_comerciais.arte_valor vai a 0 (todas as funções de preço, orçamento, PDF, loja e checkout já leem esse valor) e o valor
-- original fica guardado em app_settings.black_friday, que um agendamento restaura sozinho depois do dia 30/11 (00h05 de Brasília de 01/12).
-- A conferência técnica do arquivo (arte_conferencia_valor) NÃO entra na promoção: o cliente que já tem arte não paga criação, só a conferência opcional.

insert into public.app_settings (key, value)
select 'black_friday', jsonb_build_object(
  'ativo', true, 'inicio', '2026-11-19', 'ate', '2026-11-30', 'arte_gratis', true,
  'arte_valor_original', (select arte_valor from public.parametros_comerciais where id = 1),
  'titulo', 'Black Friday Sua Gráfica BH',
  'argumento', 'Black Friday: criação de arte GRÁTIS em qualquer pedido fechado e pago até 30/11. Depois dessa data a arte volta a ser cobrada.')
on conflict (key) do nothing;

create or replace function private.black_friday_ativa() returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((value ->> 'ativo')::boolean, false)
     and (now() at time zone 'America/Sao_Paulo')::date between (value ->> 'inicio')::date and (value ->> 'ate')::date
    from public.app_settings where key = 'black_friday';
$$;
revoke all on function private.black_friday_ativa() from public, anon, authenticated;

-- Liga a promoção: guarda o valor original (uma vez) e zera a criação de arte
create or replace function private.black_friday_aplicar() returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not coalesce(private.black_friday_ativa(), false) then return; end if;
  update public.app_settings set value = jsonb_set(value, '{arte_valor_original}', to_jsonb((select arte_valor from public.parametros_comerciais where id = 1)))
   where key = 'black_friday' and coalesce((value ->> 'arte_valor_original')::numeric, 0) <= 0
     and (select arte_valor from public.parametros_comerciais where id = 1) > 0;
  update public.parametros_comerciais set arte_valor = 0 where id = 1 and arte_valor <> 0;
end;
$$;
revoke all on function private.black_friday_aplicar() from public, anon, authenticated;

-- Desliga depois do último dia: devolve o valor original da arte e marca a promoção como encerrada (idempotente)
create or replace function private.black_friday_encerrar() returns void
language plpgsql security definer set search_path = ''
as $$
declare v jsonb;
begin
  select value into v from public.app_settings where key = 'black_friday';
  if v is null or not coalesce((v ->> 'ativo')::boolean, false) then return; end if;
  if (now() at time zone 'America/Sao_Paulo')::date <= (v ->> 'ate')::date then return; end if;
  update public.parametros_comerciais set arte_valor = coalesce(nullif((v ->> 'arte_valor_original')::numeric, 0), 39.90) where id = 1 and arte_valor = 0;
  update public.app_settings set value = jsonb_set(value, '{ativo}', 'false'::jsonb) where key = 'black_friday';
end;
$$;
revoke all on function private.black_friday_encerrar() from public, anon, authenticated;

select private.black_friday_aplicar();

do $c$
begin
  perform cron.schedule('black-friday-encerrar', '5 3 * * *', 'select private.black_friday_encerrar()');
exception when others then
  raise notice 'agendamento da Black Friday não criado: %', sqlerrm;
end $c$;

-- Campanha pública (anon): a loja mostra a faixa e o checkout o aviso. Sem dado interno.
create or replace function public.loja_campanha() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select case when private.black_friday_ativa() then jsonb_build_object(
    'ativa', true, 'titulo', value ->> 'titulo', 'ate', value ->> 'ate',
    'dias_restantes', ((value ->> 'ate')::date - (now() at time zone 'America/Sao_Paulo')::date) + 1,
    'texto', 'Arte grátis em qualquer pedido até 30/11') else jsonb_build_object('ativa', false) end
  from public.app_settings where key = 'black_friday';
$$;
revoke all on function public.loja_campanha() from public;
grant execute on function public.loja_campanha() to anon, authenticated, service_role;

-- Contexto da Laura: campanha vigente e o que falta para qualificar (produto, quantidade, prazo). Quem decide é o banco, não o modelo.
do $m$
begin
  if to_regprocedure('public.agente_contexto_pre_campanha(uuid)') is null then
    alter function public.agente_contexto(uuid) rename to agente_contexto_pre_campanha;
  end if;
end $m$;
revoke all on function public.agente_contexto_pre_campanha(uuid) from public, anon, authenticated;
grant execute on function public.agente_contexto_pre_campanha(uuid) to service_role;

create or replace function public.agente_contexto(p_conversation uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r jsonb; c jsonb; v_falta text[] := '{}'; b jsonb; cd jsonb; v_anuncio text;
begin
  r := public.agente_contexto_pre_campanha(p_conversation);
  if r ? 'erro' then return r; end if;
  c := public.loja_campanha();
  select brain, collected_data into b, cd from public.conversations where id = p_conversation;
  v_anuncio := nullif(cd ->> 'anuncio_titulo', '');
  if coalesce(jsonb_array_length(b -> 'itens'), 0) = 0 and v_anuncio is null then v_falta := array_append(v_falta, 'produto'); end if;
  if coalesce(nullif(b ->> 'quantidade', ''), '') = '' and not exists (select 1 from jsonb_array_elements(coalesce(b -> 'itens', '[]'::jsonb)) i where coalesce((i ->> 'quantidade')::numeric, 0) > 1) then
    v_falta := array_append(v_falta, 'quantidade');
  end if;
  return r || jsonb_build_object(
    'campanha', c || case when (c ->> 'ativa')::boolean then jsonb_build_object(
        'arte_gratis', true,
        'argumento', (select value ->> 'argumento' from public.app_settings where key = 'black_friday')) else '{}'::jsonb end,
    'qualificacao', jsonb_build_object('produto_do_anuncio', v_anuncio, 'falta_do_brain', to_jsonb(v_falta)));
end;
$$;
revoke all on function public.agente_contexto(uuid) from public, anon, authenticated;
grant execute on function public.agente_contexto(uuid) to service_role;

-- Checkout: leva a campanha no resumo público
do $m$
begin
  if to_regprocedure('public.checkout_carregar_pre_campanha(text)') is null then
    alter function public.checkout_carregar(text) rename to checkout_carregar_pre_campanha;
  end if;
end $m$;
revoke all on function public.checkout_carregar_pre_campanha(text) from public, anon, authenticated;
grant execute on function public.checkout_carregar_pre_campanha(text) to service_role;

create or replace function public.checkout_carregar(p_token text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r jsonb;
begin
  r := public.checkout_carregar_pre_campanha(p_token);
  if not coalesce((r ->> 'ok')::boolean, false) then return r; end if;
  return r || jsonb_build_object('campanha', public.loja_campanha());
end;
$$;
revoke all on function public.checkout_carregar(text) from public, anon, authenticated;
grant execute on function public.checkout_carregar(text) to service_role;
