-- Etapa 8 (auditoria), achado C.2: INSERT em order_items com unit_cost = 0 burlava a trava do piso duro,
-- porque a função confiava no custo informado por quem insere.
-- Correção: no caminho do CRM (papel authenticated, sem confirmação do dono), o custo do item nunca pode ser
-- menor que o do catálogo para o mesmo SKU; a trava de prejuízo passa a usar o custo real.
-- O caminho do n8n/Edge (service role) e do pagamento NÃO muda.
-- Reverter: recriar private.order_items_validar sem o bloco "custo real" (corpo anterior em docs/rollback-etapa8.sql).
create or replace function private.order_items_validar()
returns trigger language plpgsql set search_path to ''
as $function$
declare
  pr public.parametros_comerciais%rowtype;
  v_pct numeric;
  v_custo_cat numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  if pr.exigir_sku_pedidos and not new.fora_catalogo and tg_op = 'INSERT' and (new.code is null or btrim(new.code) = '') then
    raise exception 'Item sem SKU não pode entrar no pedido. Marque "item fora do catálogo" se for um item manual.' using errcode = 'P0001';
  end if;
  -- custo real do catálogo (somente caminho do CRM)
  if coalesce(auth.role(), '') = 'authenticated' and new.code is not null and not new.fora_catalogo then
    select c.custo into v_custo_cat from public.catalogo c where c.sku = new.code and c.active;
    if v_custo_cat is not null and coalesce(new.unit_cost, 0) < v_custo_cat then
      new.unit_cost := v_custo_cat;
    end if;
  end if;
  if tg_op = 'INSERT' or new.unit_price is distinct from old.unit_price or new.unit_cost is distinct from old.unit_cost or new.qty is distinct from old.qty then
    v_pct := (private.taxa_pagamento(null) ->> 'pct')::numeric;
    if new.unit_cost > 0 and new.unit_price * (1 - pr.imposto_pct / 100 - v_pct / 100) < new.unit_cost then
      raise exception 'Preço abaixo do piso duro (%): o item daria prejuízo.', private.brl(round(new.unit_cost / (1 - pr.imposto_pct / 100 - v_pct / 100), 2))
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$function$;

-- Achado extra: desde a 7B (Bloco A) private.taxa_pagamento perdeu o EXECUTE do papel authenticated, e as travas
-- rodavam como o usuário logado ("permission denied for function taxa_pagamento" ao inserir item no CRM).
-- As funções ficam no schema private (fora da API); como definer voltam a funcionar sem abrir permissão.
alter function private.order_items_validar() security definer;
alter function private.order_items_piso_manual() security definer;

-- Mesmo problema nos gatilhos de pedido e orçamento que chamam taxa_pagamento/calcular_preco:
-- alterar o método de pagamento de um pedido pelo CRM falhava com "permission denied".
alter function private.orders_taxa_do_metodo() security definer;
alter function private.orders_validar_desconto() security definer;
alter function private.orders_subestatus_ajusta() security definer;
alter function private.orcamentos_metodo_pior_caso() security definer;
alter function private.orcamentos_validar() security definer;
alter function private.orcamento_itens_validar() security definer;
alter function private.orcamento_itens_recalcular() security definer;
