-- Etapa 4, correção: cole este arquivo inteiro no SQL Editor do Supabase (idempotente). É a migration 20261029000010.
-- Corrige o erro "column avisos is of type jsonb but expression is of type text[]": o banco já tinha colunas de uma tentativa anterior.
-- Remove duas views sobras dessa tentativa (orcamentos_cliente e orcamento_itens_cliente), que nenhuma tela ou função usa.

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
