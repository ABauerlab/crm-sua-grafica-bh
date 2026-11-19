-- 19/11/2026: (1) o orçamento mostra a quantidade que o cliente pediu (6 crachás com cordão = 6 e 6), e o ajuste ao lote do
-- fornecedor vai só para a anotação interna do item e do pedido; (2) um orçamento novo substitui os anteriores do mesmo
-- cliente e do mesmo tipo de produto (rascunhos não enviados somem; enviados e seus pedidos sem pagamento são cancelados).
-- Aditiva e idempotente.

alter table public.orcamento_itens add column if not exists unidades_cliente integer;
alter table public.orcamento_itens add column if not exists nota_interna text;

-- Melhor combinação de lote do fornecedor para cobrir N unidades (mesma família: categoria, descrição, cores e tamanho).
create or replace function private.orcamento_melhor_lote(p_sku text, p_unidades integer)
returns table (sku text, pacotes integer, lote integer, preco_total numeric)
language sql stable security definer set search_path = '' as $$
  select x.sku,
         ceil(p_unidades::numeric / greatest(coalesce(x.quantidade, 1), 1))::integer,
         coalesce(x.quantidade, 1),
         ceil(p_unidades::numeric / greatest(coalesce(x.quantidade, 1), 1)) * x.preco_venda
    from public.catalogo c
    join public.catalogo x on x.categoria = c.categoria and x.descricao = c.descricao
                          and x.cores is not distinct from c.cores and x.tamanho_mm is not distinct from c.tamanho_mm
   where c.sku = upper(btrim(p_sku)) and x.active and x.vendavel and x.preco_venda is not null
   order by 4, ceil(p_unidades::numeric / greatest(coalesce(x.quantidade, 1), 1)) * coalesce(x.quantidade, 1) - p_unidades, x.sku
   limit 1
$$;
revoke all on function private.orcamento_melhor_lote(text, integer) from public, anon, authenticated;

-- Cancela o pedido de um orçamento substituído (só se ainda não foi pago nem andou no Kanban). Não exige usuário logado.
create or replace function private.pedido_substituir(p_order uuid, p_motivo text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype;
begin
  select * into o from public.orders where id = p_order for update;
  if not found then return false; end if;
  if o.excluido_em is not null then return true; end if;
  if o.payment_status = 'aprovado' or coalesce(o.payment_manual, false) or o.paid_at is not null
     or exists (select 1 from public.pagamentos p where p.order_id = o.id and p.status = 'aprovado')
     or o.stage not in ('novo', 'cotando', 'aguardando_pagamento') then
    return false;
  end if;
  insert into public.pedidos_auditoria (order_id, numero, acao, motivo, por, pago, resumo)
  values (o.id, o.number, 'excluido', p_motivo, null, false, jsonb_build_object('titulo', o.title, 'etapa', o.stage));
  update public.orders set excluido_em = now(), excluido_por = null, excluido_motivo = p_motivo where id = o.id;
  update public.orcamentos set status = 'cancelado' where order_id = o.id and status in ('rascunho', 'enviado', 'aceito');
  update public.pagamentos set link_ativo = false where order_id = o.id and status <> 'aprovado';
  update public.pedido_avisos set status = 'pulado' where order_id = o.id and status in ('pendente', 'reservado');
  update public.followup_fila set status = 'cancelado' where order_id = o.id and status in ('pendente', 'reservado');
  update public.tasks set done_at = now() where order_id = o.id and done_at is null;
  return true;
end $$;
revoke all on function private.pedido_substituir(uuid, text) from public, anon, authenticated;

-- Um orçamento novo substitui os anteriores do mesmo cliente que tenham o mesmo tipo de produto (categoria do catálogo).
create or replace function private.orcamento_substituir_anteriores(p_novo uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare n public.orcamentos%rowtype; o record; v_n integer := 0; v_num text;
begin
  select * into n from public.orcamentos where id = p_novo;
  if not found then return 0; end if;
  v_num := private.orcamento_numero(n.numero);
  for o in
    select x.* from public.orcamentos x
     where x.id <> p_novo and x.contact_id = n.contact_id and x.criado_em < n.criado_em
       and x.status in ('rascunho', 'enviado') and coalesce(x.teste, false) = coalesce(n.teste, false)
       and exists (select 1 from public.orcamento_itens a join public.catalogo ca on ca.sku = a.sku
                    join public.orcamento_itens b on b.orcamento_id = n.id join public.catalogo cb on cb.sku = b.sku
                   where a.orcamento_id = x.id and ca.categoria = cb.categoria)
  loop
    if o.order_id is not null then
      if not private.pedido_substituir(o.order_id, 'Substituído pelo orçamento ' || v_num || ' (o mesmo pedido foi refeito)') then continue; end if;
    elsif o.status = 'rascunho' and o.pdf_enviado_em is null and o.link_pagamento is null then
      delete from public.orcamentos where id = o.id;
      v_n := v_n + 1; continue;
    end if;
    update public.orcamentos set status = 'cancelado' where id = o.id and status in ('rascunho', 'enviado');
    update public.followup_fila set status = 'cancelado' where orcamento_id = o.id and status in ('pendente', 'reservado');
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function private.orcamento_substituir_anteriores(uuid) from public, anon, authenticated;

-- montar_orcamento ganha o campo "unidades" por item e a substituição dos orçamentos anteriores
do $$
begin
  if to_regprocedure('public.montar_orcamento_pre_unidades(uuid,jsonb,jsonb)') is null then
    alter function public.montar_orcamento(uuid, jsonb, jsonb) rename to montar_orcamento_pre_unidades;
    revoke all on function public.montar_orcamento_pre_unidades(uuid, jsonb, jsonb) from public, anon, authenticated;
    grant execute on function public.montar_orcamento_pre_unidades(uuid, jsonb, jsonb) to service_role;
  end if;
end $$;

create or replace function public.montar_orcamento(p_contact uuid, p_itens jsonb, p_opcoes jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_itens jsonb := '[]'::jsonb; it jsonb; a jsonb; v_u integer; v_sku text; b record; v_aj jsonb := '[]'::jsonb;
  v_opc jsonb := coalesce(p_opcoes, '{}'::jsonb); v_res jsonb; v_id uuid; v_row uuid; v_it jsonb;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if jsonb_typeof(p_itens) = 'array' then
    for it in select * from jsonb_array_elements(p_itens) loop
      v_u := nullif(regexp_replace(coalesce(it ->> 'unidades', ''), '\D', '', 'g'), '')::integer;
      v_sku := upper(btrim(coalesce(it ->> 'sku', '')));
      if v_u is not null and v_u > 0 and v_sku <> '' then
        select * into b from private.orcamento_melhor_lote(v_sku, v_u);
        if found then
          v_itens := v_itens || jsonb_build_array((it - 'unidades') || jsonb_build_object('sku', b.sku, 'quantidade', b.pacotes));
          v_aj := v_aj || jsonb_build_array(jsonb_build_object('sku', b.sku, 'unidades', v_u, 'pacotes', b.pacotes, 'lote', b.lote));
          continue;
        end if;
      end if;
      v_itens := v_itens || jsonb_build_array(it - 'unidades');
    end loop;
  else
    v_itens := p_itens;
  end if;
  if jsonb_array_length(v_aj) > 0 then v_opc := v_opc || jsonb_build_object('nao_otimizar_lote', 'true'); end if;

  v_res := public.montar_orcamento_pre_unidades(p_contact, v_itens, v_opc);
  if jsonb_typeof(v_res) <> 'object' or v_res ->> 'status' is distinct from 'ok' then return v_res; end if;
  v_id := (v_res ->> 'orcamento_id')::uuid;

  begin
    for a in select * from jsonb_array_elements(v_aj) loop
      select i.id into v_row from public.orcamento_itens i where i.orcamento_id = v_id and i.sku = a ->> 'sku' and i.unidades_cliente is null order by i.id limit 1;
      if v_row is not null then
        update public.orcamento_itens set unidades_cliente = (a ->> 'unidades')::integer,
               nota_interna = case when (a ->> 'pacotes')::integer * (a ->> 'lote')::integer = (a ->> 'unidades')::integer then null
                 else format('Cliente pediu %s un.; o fornecedor vende em lote de %s un. (%s pacote(s), sobram %s). SKU %s.',
                              a ->> 'unidades', a ->> 'lote', a ->> 'pacotes', (a ->> 'pacotes')::integer * (a ->> 'lote')::integer - (a ->> 'unidades')::integer, a ->> 'sku') end,
               especificacao = case when coalesce(especificacao, '') ~ '^\s*[0-9.]+\s*un\.?\s*·'
                                    then regexp_replace(especificacao, '^\s*[0-9.]+\s*un\.?\s*·\s*', (a ->> 'unidades') || ' un. · ')
                                    else (a ->> 'unidades') || ' un. · ' || coalesce(especificacao, '') end
         where id = v_row;
      end if;
    end loop;
    if jsonb_array_length(v_aj) > 0 then
      select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'especificacao', i.especificacao, 'quantidade', i.quantidade,
               'unidades', coalesce(i.unidades_cliente, i.quantidade * coalesce(c.quantidade, 1)), 'acabamento', i.acabamento, 'area_m2', i.area_m2,
               'valor_unitario', i.preco_unitario, 'valor_total', i.quantidade * i.preco_unitario) order by i.criado_em, i.id), '[]'::jsonb)
        into v_it from public.orcamento_itens i left join public.catalogo c on c.sku = i.sku where i.orcamento_id = v_id;
      v_res := v_res || jsonb_build_object('itens', v_it, 'orientacao_quantidade',
                 'Fale ao cliente as unidades que ele pediu (campo unidades) e o total. Nunca cite lote, pacote nem a quantidade do fornecedor.');
      if jsonb_array_length(v_it) > 1 then v_res := v_res || jsonb_build_object('resumo_composto', private.resumo_composto(v_id)); end if;
    end if;
    perform private.orcamento_substituir_anteriores(v_id);
  exception when others then
    raise warning 'montar_orcamento: pós-processamento ignorado: %', sqlerrm;
  end;
  return v_res;
end $$;
revoke all on function public.montar_orcamento(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.montar_orcamento(uuid, jsonb, jsonb) to authenticated, service_role;

-- Anotação interna do pedido: quando o orçamento vira pedido, o ajuste de lote do fornecedor vai para orders.notes
create or replace function private.orcamento_nota_no_pedido() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_nota text;
begin
  select string_agg(i.nota_interna, E'\n' order by i.criado_em, i.id) into v_nota
    from public.orcamento_itens i where i.orcamento_id = new.id and i.nota_interna is not null;
  if v_nota is not null then
    update public.orders set notes = btrim(coalesce(notes, '') || E'\n' || 'Nota interna (lote do fornecedor): ' || v_nota, E'\n') where id = new.order_id;
  end if;
  return null;
end $$;
revoke execute on function private.orcamento_nota_no_pedido() from public, anon, authenticated;
drop trigger if exists orcamentos_nota_no_pedido on public.orcamentos;
create trigger orcamentos_nota_no_pedido after update of order_id on public.orcamentos
  for each row when (old.order_id is null and new.order_id is not null) execute function private.orcamento_nota_no_pedido();
