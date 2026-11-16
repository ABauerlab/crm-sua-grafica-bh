-- 16/11/2026: cliente de fora de BH escolhe PAC ou SEDEX (cotação do SuperFrete) e o frete entra no valor final do orçamento,
-- do PDF, do pedido e do link de pagamento. O valor vem de public.frete_cotacoes (gravada pela ferramenta verificar_frete), nunca do modelo.
-- O custo do frete é repasse: entra como custo igual ao valor cobrado. Aditiva e idempotente.
create table if not exists public.frete_cotacoes (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid,
  cep text not null,
  servico text not null,
  nome text,
  valor numeric not null check (valor >= 0),
  prazo_dias integer,
  criado_em timestamptz not null default now()
);
create index if not exists frete_cotacoes_conversa_cep on public.frete_cotacoes (conversation_id, cep, criado_em desc);
alter table public.frete_cotacoes enable row level security;
revoke all on public.frete_cotacoes from anon, authenticated;

alter table public.orcamentos drop constraint if exists orcamentos_frete_modo_check;
alter table public.orcamentos add constraint orcamentos_frete_modo_check check (frete_modo = any (array['retirada','bike_gratis','uber_cliente','correios']));

do $mig$
declare d text;
begin
  -- montar_orcamento
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'montar_orcamento';
  if position('v_frete_nac' in d) = 0 then
    if position($q$v_acab_dia integer := 0;$q$ in d) = 0
       or position($q$v_validade := now() + make_interval(hours => pr.validade_orcamento_horas);$q$ in d) = 0
       or position($q$ v_arte_valor, 0,$q$ in d) = 0
       or position($q$'valor', 0, 'texto', v_frete_txt$q$ in d) = 0
       or position($q$when 'uber_cliente' then 'Entrega por Uber Entrega, por conta do cliente. A retirada é grátis.'$q$ in d) = 0 then
      raise exception 'âncoras de montar_orcamento não encontradas';
    end if;
    d := replace(d, $q$v_acab_dia integer := 0;$q$, $q$v_acab_dia integer := 0; v_frete_nac numeric := 0;$q$);
    d := replace(d, $q$v_validade := now() + make_interval(hours => pr.validade_orcamento_horas);$q$, $q$v_validade := now() + make_interval(hours => pr.validade_orcamento_horas);
  if v_cep is not null then /* frete_correios */
    if nullif(v_opc ->> 'frete_servico', '') is not null then
      select c.valor into v_frete_nac from public.frete_cotacoes c where c.conversation_id = v_conv and c.cep = v_cep and c.servico = lower(v_opc ->> 'frete_servico') and c.criado_em > now() - interval '3 days' order by c.criado_em desc limit 1;
      if v_frete_nac is null then
        return jsonb_build_object('status', 'bloqueado', 'motivo', 'frete_sem_cotacao', 'alternativa', 'Consulte verificar_frete com o CEP do cliente e confirme PAC ou SEDEX antes de orçar.');
      end if;
      v_frete_modo := 'correios'; v_entrega := 'uber';
    elsif v_frete_modo <> 'bike_gratis' and exists (select 1 from public.frete_cotacoes c where c.conversation_id = v_conv and c.cep = v_cep and c.criado_em > now() - interval '3 days') then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'escolher_frete', 'alternativa', 'O cliente é de fora de BH: pergunte se prefere PAC ou SEDEX (valores de verificar_frete) e envie frete_servico em opcoes.');
    end if;
  end if;$q$);
    d := replace(d, $q$ v_arte_valor, 0,$q$, $q$ v_arte_valor, v_frete_nac,$q$);
    d := replace(d, $q$'valor', 0, 'texto', v_frete_txt$q$, $q$'valor', v_frete_nac, 'texto', v_frete_txt$q$);
    d := replace(d, $q$when 'uber_cliente' then 'Entrega por Uber Entrega, por conta do cliente. A retirada é grátis.'$q$,
      $q$when 'uber_cliente' then 'Entrega por Uber Entrega, por conta do cliente. A retirada é grátis.' when 'correios' then 'Envio pelos Correios (' || upper(coalesce(v_opc ->> 'frete_servico', '')) || '), por conta do cliente, somado ao total.'$q$);
    execute d;
  end if;

  -- custo do frete (repasse)
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'private' and p.proname = 'orcamento_financeiro';
  if position('frete_correios' in d) = 0 then
    if position($q$v_extra := private.custos_operacionais(v_entrega_nossa);$q$ in d) = 0 then raise exception 'âncora de orcamento_financeiro não encontrada'; end if;
    execute replace(d, $q$v_extra := private.custos_operacionais(v_entrega_nossa);$q$, $q$v_extra := private.custos_operacionais(v_entrega_nossa) + case when o.frete_modo = 'correios' then o.frete_valor else 0 end; /* frete_correios */$q$);
  end if;

  -- pedido: método de entrega e linha de frete (antes do desconto, para o total do pedido bater com o orçamento)
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'private' and p.proname = 'orcamento_para_pedido';
  if position('frete_correios' in d) = 0 then
    if position($q$case when o.frete_modo = 'uber_cliente' then 'uber' else 'retirada' end$q$ in d) = 0 or position('if o.desconto_valor > 0 then' in d) = 0 then raise exception 'âncoras de orcamento_para_pedido não encontradas'; end if;
    d := replace(d, $q$case when o.frete_modo = 'uber_cliente' then 'uber' else 'retirada' end$q$, $q$case when o.frete_modo = 'correios' then 'correios' when o.frete_modo = 'uber_cliente' then 'uber' else 'retirada' end$q$);
    d := replace(d, 'if o.desconto_valor > 0 then', $q$if o.frete_modo = 'correios' and o.frete_valor > 0 then /* frete_correios */
    insert into public.order_items (order_id, code, fora_catalogo, description, qty, unit_cost, unit_price)
    values (v_order, null, true, 'Frete Correios', 1, o.frete_valor, o.frete_valor);
  end if;
  if o.desconto_valor > 0 then$q$);
    execute d;
  end if;
end
$mig$;

-- Linha de frete no pedido: a trava do "piso duro" barraria um item vendido ao custo (imposto e taxa de pagamento não cobertos).
-- Como é repasse, libera só essa linha com a mesma permissão de preço aprovado e a desliga logo depois.
do $mig$
declare d text; a text := $q$if o.frete_modo = 'correios' and o.frete_valor > 0 then /* frete_correios */$q$; b text := $q$    values (v_order, null, true, 'Frete Correios', 1, o.frete_valor, o.frete_valor);$q$;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'private' and p.proname = 'orcamento_para_pedido';
  if position('frete_repasse_on' in d) = 0 then
    if position(a in d) = 0 or position(b in d) = 0 then raise exception 'âncoras do frete não encontradas'; end if;
    d := replace(d, a, a || E'\n    perform set_config(''gbh.preco_aprovado'', ''on'', true); /* frete_repasse_on */');
    d := replace(d, b, b || E'\n  perform set_config(''gbh.preco_aprovado'', ''off'', true); /* frete_repasse */');
    execute d;
  end if;
end
$mig$;

-- Bling: o frete vai no campo de transporte (total do pedido menos as mercadorias), então a linha "Frete Correios" não entra na lista de itens.
do $mig$
declare d text; a text := 'where i.order_id = p_order;';
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'bling_pedido_payload';
  if position('frete_fora_dos_itens' in d) = 0 then
    if position(a in d) = 0 then raise exception 'âncora do payload não encontrada'; end if;
    execute replace(d, a, $q$where i.order_id = p_order and i.description not ilike 'Frete Correios%'; /* frete_fora_dos_itens */$q$);
  end if;
end
$mig$;
