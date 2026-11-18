-- Checkout próprio, melhorias: arte, troca de quantidade, item extra, valor do link, orçamento e lembrete PAG_CHK.
-- Usa um pedido real com orçamento ativo e desfaz tudo no fim (exception). Esperado: "OK: ...".
do $$
declare oid uuid; tok text; r jsonb; q jsonb; ref2 text; item uuid; orc record; v_link numeric; n int; fid uuid; m jsonb; t_fim numeric;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute 'set local role service_role';
  select o.id, o.checkout_token into oid, tok from public.orders o
    join public.orcamentos oc on oc.order_id = o.id and oc.status in ('rascunho','enviado','aceito')
    join public.order_items i on i.order_id = o.id and i.code is not null and i.qty = 1
   where o.payment_status <> 'aprovado' and o.cancelado_em is null and o.conversation_id is not null order by o.created_at desc limit 1;
  if oid is null then raise exception 'FALHA: sem pedido para testar'; end if;
  update public.pagamentos set link_ativo = false where order_id = oid and eh_link and link_ativo;
  insert into public.pagamentos (order_id, eh_link, link_ativo, link, valor, status, modo, expira_em) values (oid, true, true, 'x', 1, 'pendente', 'producao', now() + interval '1 day');
  r := public.checkout_carregar(tok);
  q := r -> 'quantidades';
  if (r #>> '{pagamento,max_parcelas}')::int <> 12 or (r #>> '{pagamento,parcelas_sem_juros}')::int <> 2 then raise exception 'FALHA: parcelas %', r -> 'pagamento'; end if;
  select count(*) into n from public.followup_fila where order_id = oid and regra_codigo = 'PAG_CHK' and status = 'pendente';
  if n <> 1 then raise exception 'FALHA: lembrete PAG_CHK não agendado (%)', n; end if;
  select id into fid from public.followup_fila where order_id = oid and regra_codigo = 'PAG_CHK';
  m := public.followup_montar(fid, now());
  if m ->> 'acao' <> 'enviar' or m ->> 'texto' not like '%abriu o link do pedido%' then raise exception 'FALHA: texto do lembrete %', m; end if;
  if jsonb_array_length(q) > 0 then
    item := (q -> 0 ->> 'item_id')::uuid;
    select x ->> 'ref' into ref2 from jsonb_array_elements(q -> 0 -> 'opcoes') x where (x ->> 'atual')::boolean = false order by (x ->> 'quantidade')::int desc limit 1;
    r := public.checkout_trocar_quantidade(tok, item, ref2);
    if not coalesce((r ->> 'ok')::boolean, false) then raise exception 'FALHA: trocar %', r; end if;
  end if;
  r := public.checkout_carregar(tok);
  if jsonb_array_length(r -> 'sugestoes') > 0 then r := public.checkout_adicionar_produto(tok, r #>> '{sugestoes,0,ref}'); end if;
  select total into t_fim from public.order_financials where order_id = oid;
  select oc.total, (select coalesce(sum(i.quantidade * i.preco_unitario), 0) from public.orcamento_itens i where i.orcamento_id = oc.id) as itens into orc
    from public.orcamentos oc where oc.order_id = oid and oc.status in ('rascunho','enviado','aceito') order by oc.criado_em desc limit 1;
  select valor into v_link from public.pagamentos where order_id = oid and eh_link and link_ativo;
  if orc.total <> t_fim or orc.itens <> t_fim or v_link <> t_fim then raise exception 'FALHA: pedido=% orcamento=% itens=% link=%', t_fim, orc.total, orc.itens, v_link; end if;
  raise exception 'OK: pedido, orcamento, itens e valor do link acompanham as mudancas; lembrete PAG_CHK agendado e montado';
end $$;
