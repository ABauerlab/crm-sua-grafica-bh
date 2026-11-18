-- 18/11/2026: tirar "Criação de arte" do pedido não atualizava o PDF (a arte do orçamento é arte_modo/arte_valor,
-- não uma linha de itens, e a sincronização só copiava os itens). Agora a arte do orçamento acompanha o pedido.
create or replace function public.pedido_sincronizar_orcamento(p_order uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $f$
declare
  o public.orcamentos%rowtype;
  v_ped public.orders%rowtype;
  v_itens integer;
  v_bruto numeric;
  v_desc_pct numeric;
  v_arte numeric;
  v_criado boolean := false;
begin
  if not private.is_staff() then raise exception 'Sem permissão.' using errcode = '42501'; end if;

  select * into v_ped from public.orders where id = p_order;
  if not found then raise exception 'Pedido não encontrado.' using errcode = 'P0001'; end if;

  select count(*) into v_itens from public.order_items where order_id = p_order;

  select * into o from public.orcamentos
   where order_id = p_order and status in ('rascunho', 'enviado', 'aceito')
   order by criado_em desc limit 1;
  if not found then
    if v_itens = 0 or v_ped.paid_at is not null or v_ped.payment_confirmed_at is not null
       or v_ped.cancelado_em is not null or v_ped.excluido_em is not null
       or exists (select 1 from public.orcamentos x where x.order_id = p_order and x.status in ('perdido', 'cancelado')) then
      return jsonb_build_object('ok', true, 'sincronizado', false, 'motivo', 'sem_orcamento_ativo');
    end if;
    insert into public.orcamentos (contact_id, order_id, conversation_id, status, teste)
    values (v_ped.contact_id, p_order, v_ped.conversation_id, 'rascunho', v_ped.teste)
    returning * into o;
    v_criado := true;
  end if;

  delete from public.orcamento_itens where orcamento_id = o.id;
  insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, custo_unitario)
  select o.id, nullif(btrim(oi.code), ''), oi.description, oi.qty, oi.unit_price, oi.unit_cost
    from public.order_items oi
   where oi.order_id = p_order and oi.description !~* '^cria[cç][aã]o de arte';

  -- a arte cobrada vem da linha "Criação de arte" do pedido; sem a linha, o orçamento deixa de cobrar arte
  select coalesce(sum(oi.qty * oi.unit_price), 0) into v_arte
    from public.order_items oi where oi.order_id = p_order and oi.description ~* '^cria[cç][aã]o de arte';

  select coalesce(sum(oi.qty * oi.unit_price), 0), coalesce(max(o2.discount_pct), 0)
    into v_bruto, v_desc_pct
    from public.order_items oi join public.orders o2 on o2.id = oi.order_id
   where oi.order_id = p_order and oi.description !~* '^cria[cç][aã]o de arte';

  update public.orcamentos
     set desconto_valor = round(v_bruto * v_desc_pct / 100, 2),
         itens_exibicao = null,
         arte_valor = round(v_arte, 2),
         arte_modo = case when v_arte > 0 then 'paga' when arte_modo = 'paga' then 'nenhuma' else arte_modo end
   where id = o.id;

  return jsonb_build_object('ok', true, 'sincronizado', true, 'criado', v_criado, 'orcamento_id', o.id, 'itens', v_itens);
end;
$f$;

-- corrige o orçamento do pedido em que a arte foi retirada (Vander): sem linha de arte no pedido, o orçamento não cobra arte
update public.orcamentos q set arte_valor = 0, arte_modo = 'nenhuma'
 where q.id = 'f1ca3566-c993-46e8-aae9-cee3246d5025' and q.arte_modo = 'paga'
   and not exists (select 1 from public.order_items oi where oi.order_id = q.order_id and oi.description ~* '^cria[cç][aã]o de arte');
