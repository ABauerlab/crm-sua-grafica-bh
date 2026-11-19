-- 19/11/2026 (correção da 20261219000003): quando o cliente pede N unidades, o sistema compõe EXATAMENTE N somando lotes do
-- fornecedor pelo menor custo (6 crachás = lote de 1 + lote de 5), nunca oferece um lote maior. Só se for impossível chegar no
-- número exato (não existe lote pequeno o bastante) cobre com o menor excedente e anota a sobra. O cliente vê sempre o que pediu;
-- a composição fica na anotação interna. Também corrige a sincronização do orçamento com o pedido: o frete dos Correios não entra
-- mais como item (somava duas vezes no total), a especificação pública é preservada e itens iguais voltam a aparecer agrupados.
-- Aditiva e idempotente.

create or replace function private.orcamento_composicao_lotes(p_sku text, p_unidades integer)
returns table (sku text, pacotes integer, lote integer)
language plpgsql stable security definer set search_path = '' as $$
declare
  qs integer[]; ps numeric[]; ks text[]; v_m integer; v_n integer; v_dp numeric[]; v_pk integer[]; v_cnt integer[];
  u integer; j integer; v_custo numeric; v_alvo integer; v_best numeric;
begin
  if p_unidades is null or p_unidades < 1 or p_unidades > 50000 then return; end if;
  v_n := p_unidades;
  select array_agg(z.q order by z.q), array_agg(z.p order by z.q), array_agg(z.k order by z.q)
    into qs, ps, ks
    from (select distinct on (x.quantidade) x.quantidade as q, x.preco_venda as p, x.sku as k
            from public.catalogo c
            join public.catalogo x on x.categoria = c.categoria and x.descricao = c.descricao
                                  and x.cores is not distinct from c.cores and x.tamanho_mm is not distinct from c.tamanho_mm
           where c.sku = upper(btrim(p_sku)) and x.active and x.vendavel and x.preco_venda is not null and coalesce(x.quantidade, 0) >= 1
           order by x.quantidade, x.preco_venda, x.sku) z;
  if qs is null then return; end if;
  v_m := qs[array_upper(qs, 1)];
  v_dp := array_fill(null::numeric, array[v_n + v_m + 1]);
  v_pk := array_fill(0, array[v_n + v_m + 1]);
  v_dp[1] := 0;
  for u in 1 .. v_n + v_m loop
    for j in 1 .. array_length(qs, 1) loop
      if u >= qs[j] and v_dp[u - qs[j] + 1] is not null then
        v_custo := v_dp[u - qs[j] + 1] + ps[j];
        if v_dp[u + 1] is null or v_custo < v_dp[u + 1] then v_dp[u + 1] := v_custo; v_pk[u + 1] := j; end if;
      end if;
    end loop;
  end loop;
  if v_dp[v_n + 1] is not null then
    v_alvo := v_n;
  else
    for u in v_n + 1 .. v_n + v_m loop
      if v_dp[u + 1] is not null and (v_best is null or v_dp[u + 1] < v_best) then v_best := v_dp[u + 1]; v_alvo := u; end if;
    end loop;
  end if;
  if v_alvo is null then return; end if;
  v_cnt := array_fill(0, array[array_length(qs, 1)]);
  u := v_alvo;
  while u > 0 loop j := v_pk[u + 1]; v_cnt[j] := v_cnt[j] + 1; u := u - qs[j]; end loop;
  for j in 1 .. array_length(qs, 1) loop
    if v_cnt[j] > 0 then sku := ks[j]; pacotes := v_cnt[j]; lote := qs[j]; return next; end if;
  end loop;
end $$;
revoke all on function private.orcamento_composicao_lotes(text, integer) from public, anon, authenticated;

-- Agrupa linhas iguais (mesma descrição e especificação) para o cliente ver uma linha só, com as unidades somadas
create or replace function private.orcamento_agrupar_exibicao(p_orc uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_exib jsonb;
begin
  if not exists (select 1 from public.orcamento_itens i where i.orcamento_id = p_orc
                  group by i.descricao, regexp_replace(coalesce(i.especificacao, ''), '^\s*[0-9.]+\s*un\.?\s*·\s*', '') having count(*) > 1) then
    return;
  end if;
  select jsonb_agg(jsonb_build_object('descricao', g.descricao, 'especificacao', g.espec, 'quantidade', g.unidades, 'acabamento', g.acabamento,
                                      'area_m2', g.area, 'valor_unitario', round(g.total / g.unidades, 4), 'valor_total', round(g.total, 2)) order by g.ordem)
    into v_exib
    from (select i.descricao, regexp_replace(coalesce(i.especificacao, ''), '^\s*[0-9.]+\s*un\.?\s*·\s*', '') as espec, i.acabamento, i.area_m2,
                 sum(coalesce(i.unidades_cliente, i.quantidade * coalesce(c.quantidade, 1))) as unidades,
                 sum(i.quantidade * i.preco_unitario) as total, min(i.criado_em) as ordem
            from public.orcamento_itens i left join public.catalogo c on c.sku = i.sku
           where i.orcamento_id = p_orc group by 1, 2, 3, 4) g;
  if v_exib is not null and jsonb_array_length(v_exib) between 1 and 30 then
    update public.orcamentos set itens_exibicao = v_exib where id = p_orc;
  end if;
end $$;
revoke all on function private.orcamento_agrupar_exibicao(uuid) from public, anon, authenticated;

-- montar_orcamento: "unidades" por item vira a composição exata de lotes
create or replace function public.montar_orcamento(p_contact uuid, p_itens jsonb, p_opcoes jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_itens jsonb := '[]'::jsonb; it jsonb; a jsonb; v_u integer; v_sku text; r record; v_aj jsonb := '[]'::jsonb;
  v_opc jsonb := coalesce(p_opcoes, '{}'::jsonb); v_res jsonb; v_id uuid; v_row uuid; v_it jsonb; v_exib jsonb;
  v_comp text; v_total integer; v_primeiro boolean; v_achou boolean;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  if jsonb_typeof(p_itens) = 'array' then
    for it in select * from jsonb_array_elements(p_itens) loop
      v_u := nullif(regexp_replace(coalesce(it ->> 'unidades', ''), '\D', '', 'g'), '')::integer;
      v_sku := upper(btrim(coalesce(it ->> 'sku', '')));
      v_achou := false;
      if v_u is not null and v_u > 0 and v_sku <> '' then
        select string_agg(format('%s pacote(s) de %s un.', c.pacotes, c.lote), ' + ' order by c.lote), sum(c.pacotes * c.lote)::integer
          into v_comp, v_total from private.orcamento_composicao_lotes(v_sku, v_u) c;
        if v_comp is not null then
          v_primeiro := true;
          for r in select * from private.orcamento_composicao_lotes(v_sku, v_u) order by lote loop
            v_itens := v_itens || jsonb_build_array((it - 'unidades') || jsonb_build_object('sku', r.sku, 'quantidade', r.pacotes));
            v_aj := v_aj || jsonb_build_array(jsonb_build_object('sku', r.sku, 'pacotes', r.pacotes, 'lote', r.lote, 'unidades', v_u,
                       'primeiro', v_primeiro, 'comp', v_comp, 'total', v_total));
            v_primeiro := false;
          end loop;
          v_achou := true;
        end if;
      end if;
      if not v_achou then v_itens := v_itens || jsonb_build_array(it - 'unidades'); end if;
    end loop;
  else
    v_itens := p_itens;
  end if;
  if jsonb_array_length(v_aj) > 0 then v_opc := v_opc || jsonb_build_object('nao_otimizar_lote', 'true'); end if;
  if jsonb_array_length(v_itens) > 10 then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'alternativa', 'O pedido tem lotes demais. Simplifique a quantidade ou chame o dono.');
  end if;

  v_res := public.montar_orcamento_pre_unidades(p_contact, v_itens, v_opc);
  if jsonb_typeof(v_res) <> 'object' or v_res ->> 'status' is distinct from 'ok' then return v_res; end if;
  v_id := (v_res ->> 'orcamento_id')::uuid;

  begin
    for a in select * from jsonb_array_elements(v_aj) loop
      select i.id into v_row from public.orcamento_itens i where i.orcamento_id = v_id and i.sku = a ->> 'sku' and i.unidades_cliente is null order by i.id limit 1;
      if v_row is not null then
        update public.orcamento_itens set unidades_cliente = (a ->> 'pacotes')::integer * (a ->> 'lote')::integer,
               nota_interna = case when (a ->> 'primeiro')::boolean then
                   format('Cliente pediu %s un. Composição no fornecedor: %s (total %s un.%s).', a ->> 'unidades', a ->> 'comp', a ->> 'total',
                          case when (a ->> 'total')::integer > (a ->> 'unidades')::integer then ', sobram ' || ((a ->> 'total')::integer - (a ->> 'unidades')::integer) else '' end)
                   else null end
         where id = v_row;
      end if;
    end loop;
    perform private.orcamento_agrupar_exibicao(v_id);
    if jsonb_array_length(v_aj) > 0 then
      select itens_exibicao into v_exib from public.orcamentos where id = v_id;
      if v_exib is not null then
        select jsonb_agg(e || jsonb_build_object('unidades', e -> 'quantidade')) into v_it from jsonb_array_elements(v_exib) e;
      else
        select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'especificacao', i.especificacao, 'quantidade', i.quantidade,
                 'unidades', coalesce(i.unidades_cliente, i.quantidade * coalesce(c.quantidade, 1)), 'acabamento', i.acabamento, 'area_m2', i.area_m2,
                 'valor_unitario', i.preco_unitario, 'valor_total', i.quantidade * i.preco_unitario) order by i.criado_em, i.id), '[]'::jsonb)
          into v_it from public.orcamento_itens i left join public.catalogo c on c.sku = i.sku where i.orcamento_id = v_id;
      end if;
      v_res := v_res || jsonb_build_object('itens', v_it, 'orientacao_quantidade',
                 'Fale ao cliente as unidades que ele pediu (campo unidades) e o total. Nunca cite lote, pacote nem a composição do fornecedor.');
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

-- Sincronização do orçamento com o pedido: sem o frete como item, com especificação pública e itens iguais agrupados
create or replace function private.checkout_sincronizar_orcamento(p_order uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.orcamentos%rowtype; v_bruto numeric; v_desc_pct numeric; v_arte numeric; v_total numeric;
begin
  select total into v_total from public.order_financials where order_id = p_order;
  if coalesce(v_total, 0) > 0 then
    update public.pagamentos set valor = v_total, atualizado_em = now()
     where order_id = p_order and eh_link and link_ativo and mp_payment_id is null and valor is distinct from v_total;
  end if;
  select * into o from public.orcamentos where order_id = p_order and status in ('rascunho', 'enviado', 'aceito') order by criado_em desc limit 1;
  if not found then return; end if;
  delete from public.orcamento_itens where orcamento_id = o.id;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, custo_unitario, especificacao)
  select o.id, nullif(btrim(oi.code), ''), oi.description, oi.qty, oi.unit_price, oi.unit_cost,
         case when nullif(btrim(oi.code), '') is not null then private.especificacao_publica(btrim(oi.code)) end
    from public.order_items oi
   where oi.order_id = p_order and oi.description !~* '^cria[cç][aã]o de arte' and oi.description !~* '^frete correios';
  select coalesce(sum(oi.qty * oi.unit_price), 0) into v_arte from public.order_items oi where oi.order_id = p_order and oi.description ~* '^cria[cç][aã]o de arte';
  select coalesce(sum(oi.qty * oi.unit_price), 0), coalesce(max(o2.discount_pct), 0) into v_bruto, v_desc_pct
    from public.order_items oi join public.orders o2 on o2.id = oi.order_id
   where oi.order_id = p_order and oi.description !~* '^cria[cç][aã]o de arte' and oi.description !~* '^frete correios';
  update public.orcamentos set desconto_valor = round(v_bruto * v_desc_pct / 100, 2), itens_exibicao = null, arte_valor = round(v_arte, 2),
         arte_modo = case when v_arte > 0 then 'paga' when arte_modo = 'paga' then 'nenhuma' else arte_modo end
   where id = o.id;
  perform private.orcamento_agrupar_exibicao(o.id);
end $$;
revoke all on function private.checkout_sincronizar_orcamento(uuid) from public, anon, authenticated;

create or replace function public.pedido_sincronizar_orcamento(p_order uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  o public.orcamentos%rowtype; v_ped public.orders%rowtype; v_itens integer; v_bruto numeric; v_desc_pct numeric; v_arte numeric; v_criado boolean := false;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into v_ped from public.orders where id = p_order;
  if not found then raise exception 'Pedido não encontrado.' using errcode = 'P0001'; end if;
  select count(*) into v_itens from public.order_items where order_id = p_order;
  select * into o from public.orcamentos where order_id = p_order and status in ('rascunho', 'enviado', 'aceito') order by criado_em desc limit 1;
  if not found then
    if v_itens = 0 or v_ped.paid_at is not null or v_ped.payment_confirmed_at is not null
       or v_ped.cancelado_em is not null or v_ped.excluido_em is not null
       or exists (select 1 from public.orcamentos x where x.order_id = p_order and x.status in ('perdido', 'cancelado')) then
      return jsonb_build_object('ok', true, 'sincronizado', false, 'motivo', 'sem_orcamento_ativo');
    end if;
    insert into public.orcamentos (contact_id, order_id, conversation_id, status, teste)
    values (v_ped.contact_id, p_order, v_ped.conversation_id, 'rascunho', v_ped.teste) returning * into o;
    v_criado := true;
  end if;
  delete from public.orcamento_itens where orcamento_id = o.id;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, custo_unitario, especificacao)
  select o.id, nullif(btrim(oi.code), ''), oi.description, oi.qty, oi.unit_price, oi.unit_cost,
         case when nullif(btrim(oi.code), '') is not null then private.especificacao_publica(btrim(oi.code)) end
    from public.order_items oi
   where oi.order_id = p_order and oi.description !~* '^cria[cç][aã]o de arte' and oi.description !~* '^frete correios';
  select coalesce(sum(oi.qty * oi.unit_price), 0) into v_arte from public.order_items oi where oi.order_id = p_order and oi.description ~* '^cria[cç][aã]o de arte';
  select coalesce(sum(oi.qty * oi.unit_price), 0), coalesce(max(o2.discount_pct), 0) into v_bruto, v_desc_pct
    from public.order_items oi join public.orders o2 on o2.id = oi.order_id
   where oi.order_id = p_order and oi.description !~* '^cria[cç][aã]o de arte' and oi.description !~* '^frete correios';
  update public.orcamentos set desconto_valor = round(v_bruto * v_desc_pct / 100, 2), itens_exibicao = null, arte_valor = round(v_arte, 2),
         arte_modo = case when v_arte > 0 then 'paga' when arte_modo = 'paga' then 'nenhuma' else arte_modo end
   where id = o.id;
  perform private.orcamento_agrupar_exibicao(o.id);
  return jsonb_build_object('ok', true, 'sincronizado', true, 'criado', v_criado, 'orcamento_id', o.id, 'itens', v_itens);
end $$;
