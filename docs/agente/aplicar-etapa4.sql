-- Etapa 4 do agente: migrations 20261029000009 e 20261029000010 juntas (idempotente). Para quem ainda não aplicou nada da Etapa 4.

-- Agente de IA, Etapa 4: orçamento em PDF, montagem determinística, link de pagamento com validação e lucro real do pedido.
-- Aditiva e idempotente. Estende orcamentos/orcamento_itens (Etapa 1) e reaproveita calcular_preco, calcular_prazo, verificar_frete,
-- validar_margem e o Mercado Pago já integrado. Nada aqui devolve custo, piso, margem, fornecedor ou SKU para o agente ou para o PDF.

-- ---------------------------------------------------------------- 1. colunas novas
alter table public.parametros_comerciais add column if not exists validade_orcamento_horas smallint not null default 48 check (validade_orcamento_horas > 0);

alter table public.orcamentos add column if not exists frete_modo text not null default 'retirada' check (frete_modo in ('retirada', 'bike_gratis', 'uber_cliente'));
alter table public.orcamentos add column if not exists upsell_tipo text;
alter table public.orcamentos add column if not exists upsell_texto text;
alter table public.orcamentos add column if not exists data_prevista date;
alter table public.orcamentos add column if not exists custo_total numeric(12, 2);
alter table public.orcamentos add column if not exists avisos text[] not null default '{}';
alter table public.orcamentos add column if not exists pdf_hash text;
alter table public.orcamentos add column if not exists pdf_gerado_em timestamptz;
alter table public.orcamentos add column if not exists pdf_enviado_em timestamptz;
alter table public.orcamentos add column if not exists link_pagamento_expira_em timestamptz;
alter table public.orcamento_itens add column if not exists especificacao text;

alter table public.orders add column if not exists taxa_pagamento_real_pct numeric(5, 2);
alter table public.orders add column if not exists lucro_liquido_real numeric(12, 2);

-- bucket privado dos PDFs (o CRM do dono lê por link assinado)
insert into storage.buckets (id, name, public) values ('orcamentos', 'orcamentos', false) on conflict (id) do nothing;
drop policy if exists orcamentos_pdf_ler on storage.objects;
create policy orcamentos_pdf_ler on storage.objects for select to authenticated using (bucket_id = 'orcamentos' and private.is_staff());

-- ---------------------------------------------------------------- 2. auxiliares
create or replace function private.orcamento_numero(p_numero bigint) returns text
language sql immutable set search_path = ''
as $$ select 'SG-' || lpad(p_numero::text, 4, '0'); $$;

-- Especificação que o cliente pode ver: só quantidade, gramatura, cores e tamanho. Nunca SKU, custo ou fornecedor.
create or replace function private.especificacao_publica(p_sku text) returns text
language sql stable set search_path = ''
as $$
  select nullif(concat_ws(' · ',
    case when c.quantidade is not null then replace(to_char(c.quantidade, 'FM999,999,999'), ',', '.') || ' un.' end,
    case when c.gramatura_g is not null then c.gramatura_g || ' g' end,
    nullif(btrim(c.cores), ''),
    case when c.tamanho_mm is not null and c.tamanho_mm !~ '^\s*0\s*x\s*0\s*$' and btrim(c.tamanho_mm) <> '' then btrim(c.tamanho_mm) || ' mm' end), '')
  from public.catalogo c where c.sku = p_sku;
$$;

-- Um upsell por orçamento, escolhido por regra (nunca pelo modelo): cartão leva adesivo ou panfleto; item avulso leva o kit do segmento;
-- compra sem arte leva o serviço de arte.
create or replace function private.upsell_regra(p_skus text[], p_segmento text, p_arte_modo text) returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  v_txt text;
  v_seg text := lower(coalesce(p_segmento, ''));
begin
  select string_agg(lower(coalesce(c.grupo_produto, '') || ' ' || coalesce(c.categoria, '') || ' ' || coalesce(c.descricao, '')), ' ')
    into v_txt from public.catalogo c where c.sku = any (p_skus);
  if v_txt ~ 'cart(ã|a)o.{0,12}visita|cart(õ|o)es.{0,12}visita' then
    return jsonb_build_object('tipo', 'cartao_adesivo_panfleto', 'texto', 'Que tal incluir adesivos ou panfletos para divulgar o seu negócio junto com os cartões?');
  end if;
  if v_seg ~ 'barbearia|delivery|loja|lan(ç|c)amento' then
    return jsonb_build_object('tipo', 'kit_segmento', 'texto', 'Temos kits prontos para o seu segmento. Pergunte pelo kit e veja o que cabe no seu pedido.');
  end if;
  if p_arte_modo = 'nenhuma' then
    return jsonb_build_object('tipo', 'servico_arte', 'texto', 'Não tem arte pronta? Criamos a sua arte por um valor fixo, é só pedir.');
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------- 3. montar_orcamento
-- p_itens: [{"sku": "...", "quantidade": 1}]. p_opcoes: {conversation_id, bairro | cep, arte: nenhuma|cliente|paga|com_frete, metodo, teste}
-- Devolve JSON mínimo: sem SKU, custo, piso, margem ou fornecedor. Preço, prazo e frete vêm só das funções do banco.
create or replace function public.montar_orcamento(p_contact uuid, p_itens jsonb, p_opcoes jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_opc jsonb := coalesce(p_opcoes, '{}'::jsonb);
  v_local text := nullif(btrim(coalesce(v_opc ->> 'cep', v_opc ->> 'bairro', '')), '');
  v_arte text := coalesce(nullif(v_opc ->> 'arte', ''), 'nenhuma');
  v_metodo text := nullif(v_opc ->> 'metodo', '');
  v_conv uuid := nullif(v_opc ->> 'conversation_id', '')::uuid;
  v_teste boolean := coalesce((v_opc ->> 'teste')::boolean, false);
  v_seg text;
  it jsonb; r jsonb; fr jsonb; pz jsonb;
  v_skus text[] := '{}'; v_qtds integer[] := '{}'; v_calcs jsonb[] := '{}';
  v_sku text; v_qtd integer; v_i integer;
  v_valor_itens numeric := 0; v_itens_frete jsonb := '[]'::jsonb;
  v_frete_modo text := 'retirada'; v_entrega text := 'retirada';
  v_avisos text[] := '{}'; v_arte_valor numeric := 0;
  v_pronto date; v_frase text; v_up jsonb;
  v_id uuid; v_num bigint; v_val jsonb; v_fin jsonb; v_unit numeric;
  v_pior text := 'alta'; v_tem_baixa boolean := false; v_tem_media boolean := false;
  v_itens_out jsonb := '[]'::jsonb; v_cep text; v_validade timestamptz; v_total numeric; v_frete_txt text;
  v_pub_avisos text[];
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  if not exists (select 1 from public.contacts where id = p_contact) then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'contato_nao_encontrado', 'alternativa', 'Confirme o contato antes de orçar.');
  end if;
  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) not between 1 and 10 then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'alternativa', 'Informe de 1 a 10 itens com SKU e quantidade.');
  end if;
  if v_arte not in ('nenhuma', 'cliente', 'paga', 'com_frete') then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'arte_invalida', 'alternativa', 'Escolha: nenhuma, cliente, paga ou com_frete.');
  end if;
  select segment into v_seg from public.contacts where id = p_contact;

  -- 1) preço de cada SKU (primeira passada, sem entrega, só para saber o valor do pedido e o frete)
  for it in select * from jsonb_array_elements(p_itens) loop
    v_sku := btrim(coalesce(it ->> 'sku', ''));
    v_qtd := coalesce((it ->> 'quantidade')::integer, 1);
    if v_sku = '' or v_qtd < 1 or v_qtd > 50 then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'alternativa', 'Cada item precisa de SKU e quantidade de 1 a 50.');
    end if;
    r := public.calcular_preco(v_sku, v_qtd, jsonb_build_object('metodo', v_metodo));
    if not coalesce((r ->> 'ok')::boolean, false) then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'item_indisponivel', 'alternativa', 'Ofereça outro item do catálogo ou confirme com o dono.');
    end if;
    v_skus := v_skus || v_sku; v_qtds := v_qtds || v_qtd;
    v_valor_itens := v_valor_itens + (r ->> 'preco_total')::numeric;
    v_itens_frete := v_itens_frete || jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', v_qtd));
  end loop;

  -- 2) frete e arte
  if v_local is not null then
    fr := public.verificar_frete(v_local, v_itens_frete, v_valor_itens, v_arte = 'com_frete');
    if not coalesce((fr ->> 'ok')::boolean, false) then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'item_indisponivel', 'alternativa', 'Ofereça outro item do catálogo ou confirme com o dono.');
    end if;
    if coalesce((fr ->> 'frete_gratis')::boolean, false) then v_frete_modo := 'bike_gratis'; v_entrega := 'bike'; else v_frete_modo := 'uber_cliente'; end if;
    if (fr ->> 'dimensao_desconhecida')::boolean then v_avisos := array_append(v_avisos, 'frete_a_confirmar'); end if;
  end if;
  if v_arte = 'com_frete' and v_frete_modo <> 'bike_gratis' then
    v_arte := 'paga'; v_avisos := array_append(v_avisos, 'arte_com_frete_indisponivel');
  end if;
  v_arte_valor := case v_arte when 'paga' then pr.arte_valor when 'com_frete' then pr.arte_frete_valor else 0 end;

  -- 3) orçamento (rascunho) e itens, com o preço final calculado já considerando a entrega que é por nossa conta
  v_cep := case when v_local ~ '^\s*\d{5}-?\d{3}\s*$' then regexp_replace(v_local, '\D', '', 'g') end;
  v_validade := now() + make_interval(hours => pr.validade_orcamento_horas);
  for v_i in 1 .. cardinality(v_skus) loop
    r := public.calcular_preco(v_skus[v_i], v_qtds[v_i], jsonb_build_object('metodo', v_metodo, 'entrega', case when v_entrega = 'bike' then 'bike' end));
    v_calcs := v_calcs || r;
    if (r ->> 'confianca') = 'baixa' then v_tem_baixa := true; elsif (r ->> 'confianca') = 'media' then v_tem_media := true; end if;
  end loop;
  v_pior := case when v_tem_baixa then 'baixa' when v_tem_media then 'media' else 'alta' end;

  -- prazo: vale a data mais distante entre os itens
  for v_i in 1 .. cardinality(v_skus) loop
    pz := public.calcular_prazo(v_skus[v_i], now(), false);
    if coalesce((pz ->> 'ok')::boolean, false) and (v_pronto is null or (pz ->> 'data_pronto')::date > v_pronto) then
      v_pronto := (pz ->> 'data_pronto')::date; v_frase := pz ->> 'frase';
    end if;
  end loop;
  if v_pronto is null then v_avisos := array_append(v_avisos, 'prazo_a_confirmar'); end if;

  v_up := private.upsell_regra(v_skus, v_seg, v_arte);

  insert into public.orcamentos (contact_id, conversation_id, status, entrega, bairro, cep, metodo_previsto, arte_modo, arte_valor, frete_valor,
                                 validade_ate, frete_modo, upsell_tipo, upsell_texto, data_prevista, avisos, teste, regra_preco, confianca_preco)
  values (p_contact, v_conv, 'rascunho', v_entrega, case when v_cep is null then v_local end, v_cep, v_metodo, v_arte, v_arte_valor, 0,
          v_validade, v_frete_modo, v_up ->> 'tipo', v_up ->> 'texto', v_pronto, v_avisos, v_teste,
          (v_calcs[1] ->> 'regra'), v_pior)
  returning id, numero into v_id, v_num;

  for v_i in 1 .. cardinality(v_skus) loop
    r := v_calcs[v_i];
    v_unit := ceil((r ->> 'preco_total')::numeric / v_qtds[v_i] * 100) / 100;     -- nunca arredonda para baixo do total calculado
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, regra_preco, confianca_preco, margem_liquida_pct,
                                        consulta_mercado_id, mercado_mediana, fontes_mercado, nao_competitivo, piso, piso_duro, lucro_liquido, especificacao)
    values (v_id, v_skus[v_i], (select descricao from public.catalogo where sku = v_skus[v_i]), v_qtds[v_i], v_unit,
            r ->> 'regra', r ->> 'confianca', (r ->> 'margem_liquida_pct')::numeric,
            nullif(r ->> 'consulta_mercado_id', '')::uuid, (r ->> 'mercado_mediana')::numeric, (r ->> 'fontes_mercado')::integer,
            coalesce((r ->> 'nao_competitivo')::boolean, false), (r ->> 'piso')::numeric, (r ->> 'piso_duro')::numeric, (r ->> 'lucro_liquido')::numeric,
            private.especificacao_publica(v_skus[v_i]));
  end loop;

  -- 4) trava final de lucro (defesa em profundidade)
  v_val := public.validar_margem(v_id);
  if v_val ->> 'status' <> 'ok' then
    delete from public.orcamentos where id = v_id;
    return jsonb_build_object('status', 'bloqueado', 'motivo', v_val ->> 'motivo',
                              'alternativa', 'Sugira uma especificação mais simples ou outra quantidade, ou chame o dono para decidir.');
  end if;
  v_fin := private.orcamento_financeiro(v_id);
  update public.orcamentos set custo_total = (v_fin ->> 'custo')::numeric + (v_fin ->> 'extra')::numeric,
         lucro_liquido = (v_fin ->> 'lucro')::numeric,
         margem_liquida_pct = round((v_fin ->> 'lucro')::numeric / nullif((v_fin ->> 'receita')::numeric, 0) * 100, 1)
   where id = v_id;
  select total into v_total from public.orcamentos where id = v_id;

  select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'especificacao', i.especificacao, 'quantidade', i.quantidade,
                                               'valor_unitario', i.preco_unitario, 'valor_total', i.quantidade * i.preco_unitario) order by i.criado_em, i.id), '[]'::jsonb)
    into v_itens_out from public.orcamento_itens i where i.orcamento_id = v_id;
  v_frete_txt := case v_frete_modo
    when 'bike_gratis' then 'Entrega grátis de bicicleta na região central, em horário comercial.'
    when 'uber_cliente' then 'Entrega por Uber Entrega, por conta do cliente. A retirada é grátis.'
    else 'Retirada grátis no centro de BH.' end;
  v_pub_avisos := array(select a from unnest(v_avisos) a where a in ('arte_com_frete_indisponivel', 'frete_a_confirmar', 'prazo_a_confirmar'));

  return jsonb_build_object(
    'status', 'ok', 'orcamento_id', v_id, 'numero', private.orcamento_numero(v_num),
    'itens', v_itens_out, 'subtotal', (select subtotal from public.orcamentos where id = v_id),
    'arte', jsonb_build_object('modo', v_arte, 'valor', v_arte_valor),
    'opcoes_arte', case when v_arte = 'nenhuma' then jsonb_build_array(
        jsonb_build_object('modo', 'paga', 'valor', pr.arte_valor, 'texto', 'Só a arte'),
        jsonb_build_object('modo', 'com_frete', 'valor', pr.arte_frete_valor, 'texto', 'Arte com frete grátis na região central',
                           'disponivel', v_frete_modo = 'bike_gratis' or v_local is null)) end,
    'frete', jsonb_build_object('modo', v_frete_modo, 'valor', 0, 'texto', v_frete_txt),
    'total', v_total, 'data_prevista', v_pronto, 'prazo', v_frase, 'validade_ate', v_validade,
    'upsell', v_up, 'avisos', to_jsonb(v_pub_avisos));
end;
$$;

-- ---------------------------------------------------------------- 4. documento público do PDF
-- Só o que o cliente pode ver. O hash identifica "mudou ou não" para a geração idempotente.
create or replace function public.orcamento_documento(p_orcamento uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orcamentos%rowtype; pr public.parametros_comerciais%rowtype;
  v_cli text; v_emp jsonb; v_itens jsonb; v_cond record; v_cond_json jsonb := null;
  v_pronto date; v_frase text; pz jsonb; s text; v_versao integer; v_doc jsonb; v_opc jsonb := null;
  v_skus text[]; v_vencido boolean; v_inicio date;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return null; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  select coalesce(nullif(btrim(c.name), ''), 'Cliente') into v_cli from public.contacts c where c.id = o.contact_id;
  select value into v_emp from public.app_settings where key = 'company';

  select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'especificacao', i.especificacao, 'quantidade', i.quantidade,
                                               'valor_unitario', i.preco_unitario, 'valor_total', round(i.quantidade * i.preco_unitario, 2)) order by i.criado_em, i.id), '[]'::jsonb),
         array_agg(i.sku)
    into v_itens, v_skus from public.orcamento_itens i where i.orcamento_id = p_orcamento;

  -- prazo com data de calendário, sempre calculado na hora (a frase muda de dia para dia)
  foreach s in array coalesce(v_skus, '{}') loop
    pz := public.calcular_prazo(s, now(), false);
    if coalesce((pz ->> 'ok')::boolean, false) and (v_pronto is null or (pz ->> 'data_pronto')::date > v_pronto) then
      v_pronto := (pz ->> 'data_pronto')::date; v_frase := pz ->> 'frase'; v_inicio := (pz ->> 'inicio_contagem')::date;
    end if;
  end loop;

  select c.valida_ate, c.tipo, c.texto_curto into v_cond from public.condicoes_especiais c
   where c.orcamento_novo_id = p_orcamento and c.resultado in ('oferecida', 'aceita') order by c.criado_em desc limit 1;
  if found then
    v_cond_json := jsonb_build_object('valida_ate', v_cond.valida_ate, 'tipo', v_cond.tipo, 'total', o.total,
                                      'texto', case v_cond.tipo when 'arte_gratis' then 'Arte grátis neste pedido'
                                                                when 'frete_gratis' then 'Frete grátis neste pedido'
                                                                else 'Desconto especial já aplicado ao total' end);
  end if;

  if o.arte_modo = 'nenhuma' then
    v_opc := jsonb_build_array(
      jsonb_build_object('texto', 'Só a arte', 'valor', pr.arte_valor),
      jsonb_build_object('texto', 'Arte com frete grátis na região central', 'valor', pr.arte_frete_valor));
  end if;

  with recursive cadeia as (select id, origem_id from public.orcamentos where id = p_orcamento
                            union all select p.id, p.origem_id from public.orcamentos p join cadeia c on p.id = c.origem_id)
  select count(*) into v_versao from cadeia;
  v_vencido := o.validade_ate is not null and o.validade_ate < now();

  v_doc := jsonb_build_object(
    'numero', private.orcamento_numero(o.numero), 'versao', v_versao,
    'data', (o.criado_em at time zone 'America/Sao_Paulo')::date,
    'validade_ate', o.validade_ate,
    'cliente', jsonb_build_object('nome', v_cli),
    'itens', v_itens, 'subtotal', o.subtotal,
    'arte', jsonb_build_object('modo', o.arte_modo, 'valor', o.arte_valor, 'opcoes', v_opc),
    'frete', jsonb_build_object('modo', o.frete_modo, 'valor', o.frete_valor),
    'desconto', o.desconto_valor, 'total', o.total,
    'condicao_especial', v_cond_json,
    'data_prevista', v_pronto, 'prazo_frase', v_frase, 'prazo_inicio', v_inicio,
    'hoje', (now() at time zone 'America/Sao_Paulo')::date, 'corte_hora', pr.corte_producao_hora,
    'upsell', case when o.upsell_texto is not null then jsonb_build_object('tipo', o.upsell_tipo, 'texto', o.upsell_texto) end,
    'empresa', jsonb_build_object(
      'nome', coalesce(v_emp ->> 'name', 'Sua Gráfica BH'), 'cnpj', coalesce(v_emp ->> 'cnpj', '58.481.181/0001-03'),
      'telefone', nullif(v_emp ->> 'phone', ''), 'email', nullif(v_emp ->> 'email', ''),
      'instagram', nullif(v_emp ->> 'instagram', ''), 'site', nullif(v_emp ->> 'site', '')));
  return v_doc || jsonb_build_object('hash', md5(v_doc::text), 'vencido', v_vencido, 'status', o.status);
end;
$$;

-- ---------------------------------------------------------------- 5. orçamento vencido: gera um novo com tudo recalculado
create or replace function public.orcamento_renovar(p_orcamento uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orcamentos%rowtype; v_itens jsonb; r jsonb; v_novo uuid;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orcamentos where id = p_orcamento for update;
  if not found then return jsonb_build_object('status', 'bloqueado', 'motivo', 'orcamento_nao_encontrado'); end if;
  if o.status = 'pago' then return jsonb_build_object('status', 'bloqueado', 'motivo', 'orcamento_ja_pago'); end if;
  select jsonb_agg(jsonb_build_object('sku', i.sku, 'quantidade', i.quantidade) order by i.criado_em, i.id) into v_itens from public.orcamento_itens i where i.orcamento_id = o.id;
  r := public.montar_orcamento(o.contact_id, v_itens, jsonb_build_object(
         'conversation_id', o.conversation_id, 'bairro', o.bairro, 'cep', o.cep, 'arte', o.arte_modo, 'metodo', o.metodo_previsto, 'teste', o.teste));
  if r ->> 'status' <> 'ok' then return r; end if;
  v_novo := (r ->> 'orcamento_id')::uuid;
  update public.orcamentos set origem_id = o.id where id = v_novo;
  update public.orcamentos set status = 'expirado' where id = o.id and status in ('rascunho', 'enviado', 'aceito');
  return r || jsonb_build_object('orcamento_anterior_id', o.id, 'renovado', true);
end;
$$;

-- ---------------------------------------------------------------- 6. pedido do orçamento e link de pagamento
-- O pedido é o que o Mercado Pago cobra. O valor do pedido SEMPRE sai do orçamento; se já existir pedido com outro valor, recusa.
create or replace function private.orcamento_para_pedido(p_orcamento uuid) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orcamentos%rowtype; pr public.parametros_comerciais%rowtype;
  v_order uuid; v_pct numeric; v_gross numeric; v_fee numeric;
begin
  select * into o from public.orcamentos where id = p_orcamento for update;
  if o.order_id is not null then return o.order_id; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  v_fee := (private.taxa_pagamento(o.metodo_previsto) ->> 'pct')::numeric;
  insert into public.orders (contact_id, conversation_id, title, stage, tax_pct, payment_fee_pct, art_mode, delivery_method, teste)
  values (o.contact_id, o.conversation_id, 'Orçamento ' || private.orcamento_numero(o.numero), 'aguardando_pagamento', pr.imposto_pct, v_fee,
          case when o.arte_modo in ('paga', 'com_frete') then 'criamos' when o.arte_modo = 'cliente' then 'cliente' end,
          case when o.frete_modo = 'uber_cliente' then 'uber' else 'retirada' end, o.teste)
  returning id into v_order;
  insert into public.order_items (order_id, code, description, qty, unit_cost, unit_price, lead_days)
    select v_order, i.sku, i.descricao, i.quantidade, c.custo, i.preco_unitario, c.prazo_dias_uteis
      from public.orcamento_itens i join public.catalogo c on c.sku = i.sku where i.orcamento_id = o.id;
  if o.arte_valor > 0 then
    insert into public.order_items (order_id, code, fora_catalogo, description, qty, unit_cost, unit_price)
    values (v_order, null, true, 'Criação de arte', 1, 0, o.arte_valor);
  end if;
  if o.desconto_valor > 0 then
    select sum(qty * unit_price) into v_gross from public.order_items where order_id = v_order;
    v_pct := floor(o.desconto_valor / nullif(v_gross, 0) * 10000) / 100;      -- arredonda para baixo: nunca concede mais que o orçamento
    update public.orders set discount_pct = coalesce(v_pct, 0) where id = v_order;
  end if;
  update public.orcamentos set order_id = v_order where id = o.id;
  return v_order;
end;
$$;
revoke execute on function private.orcamento_para_pedido(uuid) from public, anon, authenticated;

-- Defesa final antes de cobrar: vencido, sem SKU, abaixo do piso duro ou prejuízo recusam. Devolve o pedido e a validade do link.
create or replace function public.preparar_link_pagamento(p_orcamento uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orcamentos%rowtype; v_val jsonb; v_order uuid; v_tot numeric; v_horas numeric; v_pago text;
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into o from public.orcamentos where id = p_orcamento for update;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'orcamento_nao_encontrado'); end if;
  if o.status in ('pago', 'cancelado', 'perdido') then return jsonb_build_object('ok', false, 'motivo', 'orcamento_encerrado'); end if;
  if o.status = 'expirado' or o.validade_ate is null or o.validade_ate <= now() then
    return jsonb_build_object('ok', false, 'motivo', 'orcamento_vencido', 'alternativa', 'Gerar um novo orçamento (orcamento_renovar) antes de cobrar.');
  end if;
  v_val := public.validar_margem(p_orcamento);
  if v_val ->> 'status' <> 'ok' then
    return jsonb_build_object('ok', false, 'motivo', v_val ->> 'motivo', 'alternativa', 'Não envie o link. Chame o dono.');
  end if;
  v_order := private.orcamento_para_pedido(p_orcamento);
  select payment_status into v_pago from public.orders where id = v_order;
  if v_pago = 'aprovado' then return jsonb_build_object('ok', false, 'motivo', 'pedido_ja_pago'); end if;
  select total into v_tot from public.order_financials where order_id = v_order;
  if abs(coalesce(v_tot, 0) - o.total) > 0.01 then
    return jsonb_build_object('ok', false, 'motivo', 'valor_do_pedido_diferente_do_orcamento', 'alternativa', 'Chame o dono para conferir o pedido.');
  end if;
  v_horas := greatest(round(extract(epoch from (o.validade_ate - now())) / 3600.0, 2), 0.1);
  return jsonb_build_object('ok', true, 'order_id', v_order, 'expira_horas', v_horas, 'total', o.total,
                            'numero', private.orcamento_numero(o.numero),
                            'texto_curto', 'Pode pagar por Pix (de qualquer banco) ou cartão pelo link. O valor já está certinho.');
end;
$$;

create or replace function public.orcamento_registrar_link(p_orcamento uuid, p_link text, p_expira timestamptz default null) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  update public.orcamentos set link_pagamento = p_link, link_pagamento_expira_em = p_expira where id = p_orcamento;
  update public.orders set stage = 'aguardando_pagamento', payment_link = p_link
   where id = (select order_id from public.orcamentos where id = p_orcamento) and stage in ('novo', 'cotando');
end;
$$;

-- validar_antes_de_cobrar (já usado por mp-criar-link): também olha a trava de margem do orçamento ligado ao pedido
create or replace function public.validar_antes_de_cobrar(p_order uuid) returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_pay text; v_total numeric; v_orc uuid; v_val jsonb;
begin
  select payment_status into v_pay from public.orders where id = p_order;
  if not found then return 'Pedido não encontrado.'; end if;
  if v_pay = 'aprovado' then return 'Este pedido já está pago.'; end if;
  select total into v_total from public.order_financials where order_id = p_order;
  if coalesce(v_total, 0) <= 0 then return 'O pedido precisa ter itens e valor maior que zero para gerar o link.'; end if;
  select o.id into v_orc from public.orcamentos o where o.order_id = p_order and o.status in ('rascunho', 'enviado', 'aceito') order by o.criado_em desc limit 1;
  if v_orc is not null then
    v_val := public.validar_margem(v_orc);
    if v_val ->> 'status' <> 'ok' then return 'Orçamento recusado pela trava de lucro (' || coalesce(v_val ->> 'motivo', 'prejuízo') || ').'; end if;
  end if;
  return null;
end;
$$;
revoke execute on function public.validar_antes_de_cobrar(uuid) from public, anon, authenticated;
grant execute on function public.validar_antes_de_cobrar(uuid) to service_role;

-- ---------------------------------------------------------------- 7. lucro líquido real quando o pagamento chega
-- A taxa passa a ser a do método efetivamente pago (Pix 0,99%, cartão 4,98%...). O lucro é gravado no momento da confirmação.
create or replace function private.confirmar_pagamento(p_order uuid, p_origem text, p_metodo text, p_ext_id text, p_quando timestamptz, p_pagamento uuid) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_o public.orders%rowtype; v_total numeric; v_taxa jsonb; v_lucro numeric;
begin
  select * into v_o from public.orders where id = p_order for update;
  if not found or v_o.payment_status = 'aprovado' then return false; end if;

  v_taxa := private.taxa_pagamento(coalesce(p_metodo, v_o.payment_method));
  update public.orders set
    payment_status = 'aprovado',
    payment_manual = (p_origem = 'manual'),
    payment_method = coalesce(p_metodo, payment_method),
    payment_external_id = coalesce(p_ext_id, payment_external_id),
    payment_confirmed_at = coalesce(payment_confirmed_at, p_quando, now()),
    -- método conhecido: o pedido passa a usar a taxa real; desconhecido mantém a taxa prevista
    payment_fee_pct = case when (v_taxa ->> 'conhecido')::boolean then (v_taxa ->> 'pct')::numeric else payment_fee_pct end,
    -- só avança para Pago quem ainda está antes dessa etapa; quem já passou dela não volta
    stage = case when stage in ('novo', 'cotando', 'aguardando_pagamento') then 'pago' else stage end
  where id = p_order;

  select total, net_profit into v_total, v_lucro from public.order_financials where order_id = p_order;
  update public.orders set taxa_pagamento_real_pct = (select payment_fee_pct from public.orders where id = p_order), lucro_liquido_real = v_lucro where id = p_order;
  -- só orçamentos já enviados: sair de rascunho dispara a trava de lucro, e pagamento confirmado nunca é bloqueado
  update public.orcamentos set status = 'pago' where order_id = p_order and status in ('enviado', 'aceito');

  perform private.mp_evento(
    'pagamento_confirmado', p_order, p_pagamento, 'pagamento_confirmado:' || p_order::text,
    jsonb_build_object('pedido_id', p_order, 'pedido_numero', v_o.number, 'referencia', 'SG-' || lpad(v_o.number::text, 4, '0'),
      'valor', v_total, 'metodo', coalesce(p_metodo, v_o.payment_method), 'origem', p_origem, 'mp_payment_id', p_ext_id, 'teste', v_o.teste));
  return true;
end;
$$;
revoke execute on function private.confirmar_pagamento(uuid, text, text, text, timestamptz, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 8. permissões
revoke execute on function public.montar_orcamento(uuid, jsonb, jsonb) from public, anon;
revoke execute on function public.orcamento_documento(uuid) from public, anon;
revoke execute on function public.orcamento_renovar(uuid) from public, anon;
revoke execute on function public.preparar_link_pagamento(uuid) from public, anon;
revoke execute on function public.orcamento_registrar_link(uuid, text, timestamptz) from public, anon;
grant execute on function public.montar_orcamento(uuid, jsonb, jsonb) to authenticated, service_role;
grant execute on function public.orcamento_documento(uuid) to authenticated, service_role;
grant execute on function public.orcamento_renovar(uuid) to authenticated, service_role;
grant execute on function public.preparar_link_pagamento(uuid) to authenticated, service_role;
grant execute on function public.orcamento_registrar_link(uuid, text, timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------- 9. tempo real: o CRM atualiza o status do orçamento no cartão do kanban
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orcamentos') then
    alter publication supabase_realtime add table public.orcamentos;
  end if;
end $$;


-- Agente de IA, Etapa 4 (correção): compatível com o banco que já tinha colunas de uma tentativa anterior (avisos e especificacao como jsonb).
-- Aditiva e idempotente. Define o formato final: orcamentos.avisos = jsonb (lista de textos) e orcamento_itens.especificacao = text.

-- Views sobras da tentativa anterior (ninguém as usa; o PDF lê só orcamento_documento). Elas dependem de especificacao e expunham campos internos sem RLS.
drop view if exists public.orcamento_itens_cliente;
drop view if exists public.orcamentos_cliente;

do $$
begin
  if (select udt_name from information_schema.columns where table_schema = 'public' and table_name = 'orcamentos' and column_name = 'avisos') = '_text' then
    alter table public.orcamentos alter column avisos drop default;
    alter table public.orcamentos alter column avisos type jsonb using to_jsonb(avisos);
    alter table public.orcamentos alter column avisos set default '[]'::jsonb;
  end if;
  if (select data_type from information_schema.columns where table_schema = 'public' and table_name = 'orcamento_itens' and column_name = 'especificacao') = 'jsonb' then
    alter table public.orcamento_itens alter column especificacao drop default;
    alter table public.orcamento_itens alter column especificacao drop not null;
    alter table public.orcamento_itens alter column especificacao type text
      using case when especificacao is null or especificacao = '{}'::jsonb or especificacao = 'null'::jsonb then null
                 when jsonb_typeof(especificacao) = 'string' then especificacao #>> '{}' else especificacao::text end;
  end if;
end $$;

-- p_itens: [{"sku": "...", "quantidade": 1}]. p_opcoes: {conversation_id, bairro | cep, arte: nenhuma|cliente|paga|com_frete, metodo, teste}
-- Devolve JSON mínimo: sem SKU, custo, piso, margem ou fornecedor. Preço, prazo e frete vêm só das funções do banco.
create or replace function public.montar_orcamento(p_contact uuid, p_itens jsonb, p_opcoes jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_opc jsonb := coalesce(p_opcoes, '{}'::jsonb);
  v_local text := nullif(btrim(coalesce(v_opc ->> 'cep', v_opc ->> 'bairro', '')), '');
  v_arte text := coalesce(nullif(v_opc ->> 'arte', ''), 'nenhuma');
  v_metodo text := nullif(v_opc ->> 'metodo', '');
  v_conv uuid := nullif(v_opc ->> 'conversation_id', '')::uuid;
  v_teste boolean := coalesce((v_opc ->> 'teste')::boolean, false);
  v_seg text;
  it jsonb; r jsonb; fr jsonb; pz jsonb;
  v_skus text[] := '{}'; v_qtds integer[] := '{}'; v_calcs jsonb[] := '{}';
  v_sku text; v_qtd integer; v_i integer;
  v_valor_itens numeric := 0; v_itens_frete jsonb := '[]'::jsonb;
  v_frete_modo text := 'retirada'; v_entrega text := 'retirada';
  v_avisos text[] := '{}'; v_arte_valor numeric := 0;
  v_pronto date; v_frase text; v_up jsonb;
  v_id uuid; v_num bigint; v_val jsonb; v_fin jsonb; v_unit numeric;
  v_pior text := 'alta'; v_tem_baixa boolean := false; v_tem_media boolean := false;
  v_itens_out jsonb := '[]'::jsonb; v_cep text; v_validade timestamptz; v_total numeric; v_frete_txt text;
  v_pub_avisos text[];
begin
  if not private.dono_ou_servidor() then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  if not exists (select 1 from public.contacts where id = p_contact) then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'contato_nao_encontrado', 'alternativa', 'Confirme o contato antes de orçar.');
  end if;
  if jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) not between 1 and 10 then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'alternativa', 'Informe de 1 a 10 itens com SKU e quantidade.');
  end if;
  if v_arte not in ('nenhuma', 'cliente', 'paga', 'com_frete') then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'arte_invalida', 'alternativa', 'Escolha: nenhuma, cliente, paga ou com_frete.');
  end if;
  select segment into v_seg from public.contacts where id = p_contact;

  -- 1) preço de cada SKU (primeira passada, sem entrega, só para saber o valor do pedido e o frete)
  for it in select * from jsonb_array_elements(p_itens) loop
    v_sku := btrim(coalesce(it ->> 'sku', ''));
    v_qtd := coalesce((it ->> 'quantidade')::integer, 1);
    if v_sku = '' or v_qtd < 1 or v_qtd > 50 then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'itens_invalidos', 'alternativa', 'Cada item precisa de SKU e quantidade de 1 a 50.');
    end if;
    r := public.calcular_preco(v_sku, v_qtd, jsonb_build_object('metodo', v_metodo));
    if not coalesce((r ->> 'ok')::boolean, false) then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'item_indisponivel', 'alternativa', 'Ofereça outro item do catálogo ou confirme com o dono.');
    end if;
    v_skus := v_skus || v_sku; v_qtds := v_qtds || v_qtd;
    v_valor_itens := v_valor_itens + (r ->> 'preco_total')::numeric;
    v_itens_frete := v_itens_frete || jsonb_build_array(jsonb_build_object('sku', v_sku, 'quantidade', v_qtd));
  end loop;

  -- 2) frete e arte
  if v_local is not null then
    fr := public.verificar_frete(v_local, v_itens_frete, v_valor_itens, v_arte = 'com_frete');
    if not coalesce((fr ->> 'ok')::boolean, false) then
      return jsonb_build_object('status', 'bloqueado', 'motivo', 'item_indisponivel', 'alternativa', 'Ofereça outro item do catálogo ou confirme com o dono.');
    end if;
    if coalesce((fr ->> 'frete_gratis')::boolean, false) then v_frete_modo := 'bike_gratis'; v_entrega := 'bike'; else v_frete_modo := 'uber_cliente'; end if;
    if (fr ->> 'dimensao_desconhecida')::boolean then v_avisos := array_append(v_avisos, 'frete_a_confirmar'); end if;
  end if;
  if v_arte = 'com_frete' and v_frete_modo <> 'bike_gratis' then
    v_arte := 'paga'; v_avisos := array_append(v_avisos, 'arte_com_frete_indisponivel');
  end if;
  v_arte_valor := case v_arte when 'paga' then pr.arte_valor when 'com_frete' then pr.arte_frete_valor else 0 end;

  -- 3) orçamento (rascunho) e itens, com o preço final calculado já considerando a entrega que é por nossa conta
  v_cep := case when v_local ~ '^\s*\d{5}-?\d{3}\s*$' then regexp_replace(v_local, '\D', '', 'g') end;
  v_validade := now() + make_interval(hours => pr.validade_orcamento_horas);
  for v_i in 1 .. cardinality(v_skus) loop
    r := public.calcular_preco(v_skus[v_i], v_qtds[v_i], jsonb_build_object('metodo', v_metodo, 'entrega', case when v_entrega = 'bike' then 'bike' end));
    v_calcs := v_calcs || r;
    if (r ->> 'confianca') = 'baixa' then v_tem_baixa := true; elsif (r ->> 'confianca') = 'media' then v_tem_media := true; end if;
  end loop;
  v_pior := case when v_tem_baixa then 'baixa' when v_tem_media then 'media' else 'alta' end;

  -- prazo: vale a data mais distante entre os itens
  for v_i in 1 .. cardinality(v_skus) loop
    pz := public.calcular_prazo(v_skus[v_i], now(), false);
    if coalesce((pz ->> 'ok')::boolean, false) and (v_pronto is null or (pz ->> 'data_pronto')::date > v_pronto) then
      v_pronto := (pz ->> 'data_pronto')::date; v_frase := pz ->> 'frase';
    end if;
  end loop;
  if v_pronto is null then v_avisos := array_append(v_avisos, 'prazo_a_confirmar'); end if;

  v_up := private.upsell_regra(v_skus, v_seg, v_arte);

  insert into public.orcamentos (contact_id, conversation_id, status, entrega, bairro, cep, metodo_previsto, arte_modo, arte_valor, frete_valor,
                                 validade_ate, frete_modo, upsell_tipo, upsell_texto, data_prevista, avisos, teste, regra_preco, confianca_preco)
  values (p_contact, v_conv, 'rascunho', v_entrega, case when v_cep is null then v_local end, v_cep, v_metodo, v_arte, v_arte_valor, 0,
          v_validade, v_frete_modo, v_up ->> 'tipo', v_up ->> 'texto', v_pronto, to_jsonb(v_avisos), v_teste,
          (v_calcs[1] ->> 'regra'), v_pior)
  returning id, numero into v_id, v_num;

  for v_i in 1 .. cardinality(v_skus) loop
    r := v_calcs[v_i];
    v_unit := ceil((r ->> 'preco_total')::numeric / v_qtds[v_i] * 100) / 100;     -- nunca arredonda para baixo do total calculado
    insert into public.orcamento_itens (orcamento_id, sku, descricao, quantidade, preco_unitario, regra_preco, confianca_preco, margem_liquida_pct,
                                        consulta_mercado_id, mercado_mediana, fontes_mercado, nao_competitivo, piso, piso_duro, lucro_liquido, especificacao)
    values (v_id, v_skus[v_i], (select descricao from public.catalogo where sku = v_skus[v_i]), v_qtds[v_i], v_unit,
            r ->> 'regra', r ->> 'confianca', (r ->> 'margem_liquida_pct')::numeric,
            nullif(r ->> 'consulta_mercado_id', '')::uuid, (r ->> 'mercado_mediana')::numeric, (r ->> 'fontes_mercado')::integer,
            coalesce((r ->> 'nao_competitivo')::boolean, false), (r ->> 'piso')::numeric, (r ->> 'piso_duro')::numeric, (r ->> 'lucro_liquido')::numeric,
            private.especificacao_publica(v_skus[v_i]));
  end loop;

  -- 4) trava final de lucro (defesa em profundidade)
  v_val := public.validar_margem(v_id);
  if v_val ->> 'status' <> 'ok' then
    delete from public.orcamentos where id = v_id;
    return jsonb_build_object('status', 'bloqueado', 'motivo', v_val ->> 'motivo',
                              'alternativa', 'Sugira uma especificação mais simples ou outra quantidade, ou chame o dono para decidir.');
  end if;
  v_fin := private.orcamento_financeiro(v_id);
  update public.orcamentos set custo_total = (v_fin ->> 'custo')::numeric + (v_fin ->> 'extra')::numeric,
         lucro_liquido = (v_fin ->> 'lucro')::numeric,
         margem_liquida_pct = round((v_fin ->> 'lucro')::numeric / nullif((v_fin ->> 'receita')::numeric, 0) * 100, 1)
   where id = v_id;
  select total into v_total from public.orcamentos where id = v_id;

  select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'especificacao', i.especificacao, 'quantidade', i.quantidade,
                                               'valor_unitario', i.preco_unitario, 'valor_total', i.quantidade * i.preco_unitario) order by i.criado_em, i.id), '[]'::jsonb)
    into v_itens_out from public.orcamento_itens i where i.orcamento_id = v_id;
  v_frete_txt := case v_frete_modo
    when 'bike_gratis' then 'Entrega grátis de bicicleta na região central, em horário comercial.'
    when 'uber_cliente' then 'Entrega por Uber Entrega, por conta do cliente. A retirada é grátis.'
    else 'Retirada grátis no centro de BH.' end;
  v_pub_avisos := array(select a from unnest(v_avisos) a where a in ('arte_com_frete_indisponivel', 'frete_a_confirmar', 'prazo_a_confirmar'));

  return jsonb_build_object(
    'status', 'ok', 'orcamento_id', v_id, 'numero', private.orcamento_numero(v_num),
    'itens', v_itens_out, 'subtotal', (select subtotal from public.orcamentos where id = v_id),
    'arte', jsonb_build_object('modo', v_arte, 'valor', v_arte_valor),
    'opcoes_arte', case when v_arte = 'nenhuma' then jsonb_build_array(
        jsonb_build_object('modo', 'paga', 'valor', pr.arte_valor, 'texto', 'Só a arte'),
        jsonb_build_object('modo', 'com_frete', 'valor', pr.arte_frete_valor, 'texto', 'Arte com frete grátis na região central',
                           'disponivel', v_frete_modo = 'bike_gratis' or v_local is null)) end,
    'frete', jsonb_build_object('modo', v_frete_modo, 'valor', 0, 'texto', v_frete_txt),
    'total', v_total, 'data_prevista', v_pronto, 'prazo', v_frase, 'validade_ate', v_validade,
    'upsell', v_up, 'avisos', to_jsonb(v_pub_avisos));
end;
$$;


revoke execute on function public.montar_orcamento(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.montar_orcamento(uuid, jsonb, jsonb) to authenticated, service_role;
