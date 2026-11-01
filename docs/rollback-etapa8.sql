-- Reversões das correções da Etapa 8 (rodar só se necessário).
-- 20261102000001
grant execute on function public.rls_auto_enable() to anon, authenticated, public;
alter function public.atualizar_orcamento_atualizado_em() reset search_path;
-- 20261102000002: corpo anterior de private.order_items_validar (sem o bloco do custo real do catálogo)
create or replace function private.order_items_validar()
returns trigger language plpgsql set search_path to ''
as $function$
declare pr public.parametros_comerciais%rowtype; v_pct numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  if pr.exigir_sku_pedidos and not new.fora_catalogo and tg_op = 'INSERT' and (new.code is null or btrim(new.code) = '') then
    raise exception 'Item sem SKU não pode entrar no pedido. Marque "item fora do catálogo" se for um item manual.' using errcode = 'P0001';
  end if;
  if tg_op = 'INSERT' or new.unit_price is distinct from old.unit_price or new.unit_cost is distinct from old.unit_cost or new.qty is distinct from old.qty then
    v_pct := (private.taxa_pagamento(null) ->> 'pct')::numeric;
    if new.unit_cost > 0 and new.unit_price * (1 - pr.imposto_pct / 100 - v_pct / 100) < new.unit_cost then
      raise exception 'Preço abaixo do piso duro (%): o item daria prejuízo.', private.brl(round(new.unit_cost / (1 - pr.imposto_pct / 100 - v_pct / 100), 2)) using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$function$;
alter function private.order_items_validar() security invoker;
alter function private.order_items_piso_manual() security invoker;
alter function private.orders_taxa_do_metodo() security invoker;
alter function private.orders_validar_desconto() security invoker;
alter function private.orders_subestatus_ajusta() security invoker;
alter function private.orcamentos_metodo_pior_caso() security invoker;
alter function private.orcamentos_validar() security invoker;
alter function private.orcamento_itens_validar() security invoker;
alter function private.orcamento_itens_recalcular() security invoker;
-- Primeira conversa real (Rose), correções 20261105000007..13
-- 07: revoke usage on schema private from service_role; revoke execute on all functions in schema private from service_role;
-- 08: insert into sinonimos(grupo,termo) values ('cartao de visita','cartao'); delete dos plurais.
-- 09: recriar public.orcamento_marcar_enviado só com o update de status (sem o bloco do pedido).
-- 12: update parametros_comerciais set tokens_max_conversa=40000, tokens_max_dia=1500000; observabilidade.teto_custo_dia_brl=15; debounce_segundos=10.
-- 13: buscar_produto anterior: ver git (migration 20261028..._agente_funcoes / 7B) e drop function private.categoria_bate(text,text[]).
