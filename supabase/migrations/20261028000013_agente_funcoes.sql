-- Agente de IA, Etapa 1 (3/4): funções determinísticas de preço, prazo, frete, margem e condição especial.
-- O modelo de IA NUNCA calcula nada disso: o n8n chama estas funções (service role) e repassa só o que o cliente pode ver.
-- Todas são SECURITY INVOKER: a RLS vale (só o dono ou a service role leem produtos e custos). Nenhuma devolve custo.
-- calcular_preco e validar_margem devolvem piso, piso_duro, lucro e margem para uso INTERNO; a ferramenta do agente filtra.

-- ---------------------------------------------------------------- utilidades
create or replace function private.norm_txt(p text) returns text
language sql immutable set search_path = ''
as $$
  select regexp_replace(
    lower(translate(trim(coalesce(p, '')), 'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ', 'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')),
    '\s+', ' ', 'g');
$$;

create or replace function private.brl(p numeric) returns text
language sql stable set search_path = ''
as $$ select 'R$ ' || replace(to_char(p, 'FM999999990.00'), '.', ','); $$;

-- Arredonda para o ,90 mais próximo (ex.: 167,99 vira 167,90; 168,60 vira 168,90)
create or replace function private.arredonda_90(p numeric) returns numeric
language sql immutable set search_path = ''
as $$
  select greatest(0.90, case
    when abs(p - (floor(p) + 0.90)) <= abs(p - (floor(p) - 0.10)) then floor(p) + 0.90
    else floor(p) - 0.10 end);
$$;

-- Menor valor terminado em ,90 que seja maior ou igual a p (nunca fica abaixo do piso)
create or replace function private.teto_90(p numeric) returns numeric
language sql immutable set search_path = ''
as $$ select case when p <= floor(p) + 0.90 then floor(p) + 0.90 else floor(p) + 1.90 end; $$;

-- Multiplicador da faixa de custo ("ate" é o limite superior exclusivo; null = sem limite)
create or replace function private.multiplicador_faixa(p_custo numeric) returns numeric
language plpgsql stable set search_path = ''
as $$
declare
  f jsonb;
  v_mult numeric;
begin
  for f in select * from jsonb_array_elements((select multiplicadores from public.parametros_comerciais where id = 1)) loop
    if f ->> 'ate' is null or p_custo < (f ->> 'ate')::numeric then
      return (f ->> 'multiplicador')::numeric;
    end if;
  end loop;
  return 1.6;
end;
$$;

-- Taxa do método de pagamento. Método desconhecido usa o método do piso (cartão de crédito, o mais caro).
create or replace function private.taxa_pagamento(p_metodo text) returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  m text := lower(coalesce(p_metodo, ''));
  v_chave text;
  v_conhecido boolean := true;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  v_chave := case
    when m in ('cartao_credito', 'cartao', 'credit_card', 'debit_card', 'visa', 'master', 'mastercard', 'elo', 'amex', 'hipercard', 'diners', 'cabal') then 'cartao_credito'
    when m in ('saldo_mercado_pago', 'account_money') then 'saldo_mercado_pago'
    when m in ('linha_credito', 'consumer_credits') then 'linha_credito'
    when m in ('cartao_prepago', 'prepaid_card') then 'cartao_prepago'
    when m = 'pix' then 'pix'
    when m = 'open_finance' then 'open_finance'
    when m in ('boleto', 'ticket', 'bolbradesco', 'pec') then 'boleto'
    else null end;
  if v_chave is null or not (pr.taxas_pagamento ? v_chave) then
    v_chave := pr.metodo_piso;
    v_conhecido := false;
  end if;
  return jsonb_build_object(
    'chave', v_chave,
    'pct', (pr.taxas_pagamento -> v_chave ->> 'pct')::numeric,
    'fixo', (pr.taxas_pagamento -> v_chave ->> 'fixo')::numeric,
    'conhecido', v_conhecido);
end;
$$;

-- Custos que não dependem do produto: WhatsApp e IA por conversa, mais a entrega quando o frete é nosso
create or replace function private.custos_operacionais(p_entrega text) returns numeric
language sql stable set search_path = ''
as $$
  select pr.custo_whatsapp_conversa + pr.custo_ia_conversa
    + case lower(coalesce(p_entrega, '')) when 'bike' then pr.custo_entrega_bike when 'uber' then pr.custo_entrega_uber else 0 end
  from public.parametros_comerciais pr where pr.id = 1;
$$;

-- Receita mínima para obter p_lucro líquido, depois de imposto, taxa do método, custo e extras (arredondada para cima, em centavos)
create or replace function private.receita_para_lucro(p_custo numeric, p_extra numeric, p_lucro numeric, p_metodo text) returns numeric
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  t jsonb := private.taxa_pagamento(p_metodo);
begin
  select * into pr from public.parametros_comerciais where id = 1;
  return ceil(((p_custo + p_extra + (t ->> 'fixo')::numeric + p_lucro) / (1 - pr.imposto_pct / 100 - (t ->> 'pct')::numeric / 100)) * 100) / 100;
end;
$$;

-- Lucro líquido de uma receita
create or replace function private.lucro(p_receita numeric, p_custo numeric, p_extra numeric, p_metodo text) returns numeric
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  t jsonb := private.taxa_pagamento(p_metodo);
begin
  select * into pr from public.parametros_comerciais where id = 1;
  return round(p_receita * (1 - pr.imposto_pct / 100 - (t ->> 'pct')::numeric / 100) - (t ->> 'fixo')::numeric - p_custo - p_extra, 2);
end;
$$;

-- Fechamento financeiro de um orçamento, a partir dos itens gravados (usado por validar_margem, condição especial e triggers)
create or replace function private.orcamento_financeiro(p_orcamento uuid) returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  o public.orcamentos%rowtype;
  pr public.parametros_comerciais%rowtype;
  v_n integer; v_sub numeric; v_custo numeric; v_sem_produto integer;
  v_extra numeric; v_receita numeric; v_itens_liq numeric;
  v_entrega_nossa text;
begin
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return null; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  select count(*), coalesce(sum(i.quantidade * i.preco_unitario), 0), coalesce(sum(p.cost * i.quantidade), 0), count(*) filter (where p.code is null)
    into v_n, v_sub, v_custo, v_sem_produto
  from public.orcamento_itens i left join public.products p on p.code = i.sku
  where i.orcamento_id = p_orcamento;
  v_entrega_nossa := case when o.frete_valor = 0 and o.entrega in ('bike', 'uber') then o.entrega else null end;
  v_extra := private.custos_operacionais(v_entrega_nossa);
  v_itens_liq := v_sub - o.desconto_valor;
  v_receita := v_itens_liq + o.arte_valor + o.frete_valor;
  return jsonb_build_object(
    'itens', v_n, 'itens_sem_produto', v_sem_produto, 'subtotal', v_sub, 'custo', v_custo, 'extra', v_extra,
    'receita_itens_liquida', v_itens_liq, 'receita', v_receita,
    'lucro', private.lucro(v_receita, v_custo, v_extra, o.metodo_previsto),
    'receita_piso_duro', private.receita_para_lucro(v_custo, v_extra, 0, o.metodo_previsto),
    'receita_piso', private.receita_para_lucro(v_custo, v_extra, pr.lucro_liquido_minimo, o.metodo_previsto));
end;
$$;

-- ---------------------------------------------------------------- 1. calcular_preco
create or replace function public.calcular_preco(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  prod record;
  v_qtd integer := greatest(coalesce(p_quantidade, 1), 1);
  v_metodo text := p_contexto ->> 'metodo';
  v_outros_receita numeric := coalesce((p_contexto ->> 'receita_outros')::numeric, 0);
  v_outros_custo numeric := coalesce((p_contexto ->> 'custo_outros')::numeric, 0);
  v_custo_item numeric; v_custo_total numeric; v_extra numeric;
  v_base numeric; v_piso numeric; v_piso_duro numeric;
  v_mediana numeric; v_n integer; v_alvo numeric; v_preco numeric;
  v_regra text; v_conf text; v_nao_comp boolean := false;
  v_receita numeric; v_lucro numeric;
  v_avisos text[] := '{}';
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select p.cost, p.active into prod from public.products p where p.code = p_sku;
  if not found or not prod.active then
    return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado');
  end if;

  v_custo_item := prod.cost * v_qtd;
  v_custo_total := v_custo_item + v_outros_custo;
  v_extra := private.custos_operacionais(p_contexto ->> 'entrega');
  -- piso: o maior entre custo x 1,5 e a receita que garante o lucro líquido mínimo; piso_duro: lucro líquido zero
  v_piso := ceil(greatest(v_custo_item * pr.multiplicador_piso,
                          private.receita_para_lucro(v_custo_total, v_extra, pr.lucro_liquido_minimo, v_metodo) - v_outros_receita) * 100) / 100;
  v_piso_duro := private.receita_para_lucro(v_custo_total, v_extra, 0, v_metodo) - v_outros_receita;
  v_base := private.arredonda_90(v_custo_item * private.multiplicador_faixa(v_custo_item));

  -- mercado: mediana das coletas recentes da mesma especificação (a pesquisa em si entra na Etapa 3)
  select percentile_cont(0.5) within group (order by m.preco), count(*)
    into v_mediana, v_n
  from public.precos_mercado m
  where m.sku = p_sku and not m.outlier and m.coletado_em >= now() - make_interval(days => pr.idade_max_pesquisa_dias);

  if v_n >= 2 then
    v_alvo := private.arredonda_90(v_mediana * v_qtd * pr.fator_competitivo);
    v_regra := 'mercado';
    v_conf := case when v_n >= 3 then 'alta' else 'media' end;
  else
    v_alvo := v_base;
    v_regra := 'custo_x_multiplicador';
    v_conf := 'baixa';
  end if;

  if v_alvo >= v_piso then
    v_preco := v_alvo;
  else
    v_preco := private.teto_90(v_piso);
    v_regra := 'piso';
    v_nao_comp := v_n >= 2;
    if v_nao_comp then v_avisos := array_append(v_avisos, 'mercado_abaixo_do_piso'); end if;
  end if;

  v_receita := v_preco + v_outros_receita;
  v_lucro := private.lucro(v_receita, v_custo_total, v_extra, v_metodo);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku, 'quantidade', v_qtd,
    'preco_unitario', round(v_preco / v_qtd, 2), 'preco_total', v_preco,
    'regra', v_regra, 'confianca', v_conf,
    'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1), 'lucro_liquido', v_lucro,
    'piso', round(v_piso, 2), 'piso_duro', round(v_piso_duro, 2),
    'nao_competitivo', v_nao_comp, 'fontes_mercado', v_n, 'avisos', to_jsonb(v_avisos));
end;
$$;

-- ---------------------------------------------------------------- 2. calcular_prazo
-- Dia em que a contagem do fornecedor começa: o próprio dia se for dia útil e antes do corte; senão o próximo dia útil
create or replace function private.inicio_contagem(p_momento timestamptz) returns date
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_local timestamp := p_momento at time zone 'America/Sao_Paulo';
  v_dia date := (p_momento at time zone 'America/Sao_Paulo')::date;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  if public.is_business_day(v_dia) and v_local::time < make_time(pr.corte_producao_hora, 0, 0) then
    return v_dia;
  end if;
  return public.add_business_days(v_dia, 1);
end;
$$;

-- Data em que fica pronto: dias úteis brutos do fornecedor + dias de logística, a partir do início da contagem
create or replace function private.prazo_data(p_lead_days integer, p_momento timestamptz) returns date
language sql stable set search_path = ''
as $$
  select public.add_business_days(private.inicio_contagem(p_momento), coalesce(p_lead_days, 0) + pr.dias_logistica)
  from public.parametros_comerciais pr where pr.id = 1;
$$;

create or replace function public.calcular_prazo(p_sku text, p_agora timestamptz default now(), p_arte_aprovada boolean default false)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_lead integer;
  v_inicio date; v_pronto date;
  v_hoje date := (p_agora at time zone 'America/Sao_Paulo')::date;
  dias text[] := array['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado'];
  chaves text[] := array['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sab'];
  v_dow integer; v_expediente jsonb;
  v_pronto_txt text; v_quando text; v_frase text;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select p.lead_days into v_lead from public.products p where p.code = p_sku and p.active;
  if not found then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  if v_lead is null then return jsonb_build_object('ok', false, 'erro', 'prazo_nao_informado'); end if;

  v_inicio := private.inicio_contagem(p_agora);
  v_pronto := private.prazo_data(v_lead, p_agora);
  v_dow := extract(dow from v_pronto)::integer;
  v_expediente := pr.horario_atendimento -> chaves[v_dow + 1];
  v_pronto_txt := dias[v_dow + 1] || ', dia ' || extract(day from v_pronto)::integer;
  v_quando := case when v_inicio = v_hoje then 'hoje'
                   else dias[extract(dow from v_inicio)::integer + 1] || ', dia ' || extract(day from v_inicio)::integer end;
  v_frase := format('se pagar%s até %sh de %s, fica pronto %s %s',
                    case when p_arte_aprovada then '' else ' e mandar a arte' end,
                    pr.corte_producao_hora, v_quando,
                    case when v_dow in (0, 6) then 'no' else 'na' end, v_pronto_txt);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku,
    'data_pronto', v_pronto, 'data_pronto_texto', v_pronto_txt, 'dia_semana', dias[v_dow + 1],
    'inicio_contagem', v_inicio, 'pagar_ate_hora', pr.corte_producao_hora,
    'depende_da_arte', not p_arte_aprovada,
    'retirada_abre', v_expediente ->> 'abre', 'retirada_fecha', v_expediente ->> 'fecha',
    'frase', v_frase);
end;
$$;

-- ---------------------------------------------------------------- 3. verificar_frete
create or replace function public.verificar_frete(p_cep_ou_bairro text, p_itens jsonb default '[]'::jsonb, p_valor_pedido numeric default 0, p_pacote_arte boolean default false)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_txt text := coalesce(p_cep_ou_bairro, '');
  v_cep text := regexp_replace(coalesce(p_cep_ou_bairro, ''), '\D', '', 'g');
  v_zona boolean := false;
  v_origem text;
  it jsonb; prod record; nums numeric[];
  v_peso numeric := 0; v_lado numeric := 0; v_desconhecido boolean := false; v_qtd integer;
  v_cabe boolean; v_elegivel_tamanho boolean; v_minimo_ok boolean; v_gratis boolean;
  v_motivo text; v_opcoes jsonb := '[]'::jsonb;
begin
  select * into pr from public.parametros_comerciais where id = 1;

  if v_txt ~ '^\s*\d{5}-?\d{3}\s*$' then
    v_origem := 'cep';
    v_zona := exists (select 1 from public.zonas_frete_gratis z where z.ativo and z.tipo = 'cep' and v_cep between z.cep_inicio and z.cep_fim);
  else
    v_origem := 'bairro';
    v_zona := exists (select 1 from public.zonas_frete_gratis z
                      where z.ativo and z.tipo = 'bairro'
                        and private.norm_txt(z.bairro) = regexp_replace(private.norm_txt(v_txt), '^bairro ', ''));
  end if;

  for it in select * from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) loop
    select p.weight, p.size into prod from public.products p where p.code = it ->> 'sku';
    if not found then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado', 'sku', it ->> 'sku'); end if;
    v_qtd := greatest(coalesce((it ->> 'quantidade')::integer, 1), 1);
    v_peso := v_peso + coalesce(prod.weight, 0) * v_qtd;
    nums := array(select replace((regexp_matches(coalesce(prod.size, ''), '\d+(?:[.,]\d+)?', 'g'))[1], ',', '.')::numeric);
    if prod.weight is null or cardinality(nums) = 0 then
      v_desconhecido := true;
    else
      v_lado := greatest(v_lado, (select max(n) from unnest(nums) n));
    end if;
  end loop;

  v_cabe := not v_desconhecido and v_peso <= pr.peso_max_bike_g and v_lado <= pr.lado_max_bike_mm;
  v_elegivel_tamanho := (not pr.exigir_cabe_na_bike) or v_cabe;
  v_minimo_ok := coalesce(p_pacote_arte, false) or coalesce(p_valor_pedido, 0) >= pr.pedido_minimo_frete_gratis;
  v_gratis := v_zona and v_elegivel_tamanho and v_minimo_ok;
  v_motivo := case
    when v_gratis then 'frete_gratis_regiao_central'
    when not v_zona then 'fora_da_regiao_central'
    when not v_elegivel_tamanho then case when v_desconhecido then 'dimensao_desconhecida' else 'nao_cabe_na_bike' end
    else 'abaixo_do_pedido_minimo' end;

  v_opcoes := jsonb_build_array(jsonb_build_object('tipo', 'retirada', 'valor_cliente', 0, 'obs', 'retirada grátis no centro de BH'));
  if v_gratis then
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('tipo', 'bike', 'valor_cliente', 0, 'obs', 'entrega grátis de bicicleta, em horário comercial'));
  else
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('tipo', 'uber', 'valor_cliente', pr.custo_entrega_uber, 'obs', 'Uber Entrega por conta do cliente (valor de referência)'));
  end if;

  return jsonb_build_object(
    'ok', true, 'origem_consulta', v_origem, 'regiao_central', v_zona,
    'cabe_na_bike', v_cabe, 'peso_total_g', v_peso, 'maior_lado_mm', v_lado, 'dimensao_desconhecida', v_desconhecido,
    'pedido_minimo', pr.pedido_minimo_frete_gratis, 'pedido_minimo_atingido', v_minimo_ok, 'pacote_arte', coalesce(p_pacote_arte, false),
    'falta_para_frete_gratis', case when v_minimo_ok then 0 else greatest(pr.pedido_minimo_frete_gratis - coalesce(p_valor_pedido, 0), 0) end,
    'frete_gratis', v_gratis,
    'valor_frete_cliente', case when v_gratis then 0 else pr.custo_entrega_uber end,
    'frete_estimado', not v_gratis,
    'custo_entrega_nosso', case when v_gratis then pr.custo_entrega_bike else 0 end,
    'entrega_sugerida', case when v_gratis then 'bike' else 'uber' end,
    'saidas_bike_por_dia', pr.saidas_bike_por_dia,
    'motivo', v_motivo, 'opcoes', v_opcoes);
end;
$$;

-- ---------------------------------------------------------------- 4. validar_margem
create or replace function public.validar_margem(p_orcamento uuid)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  o public.orcamentos%rowtype;
  pr public.parametros_comerciais%rowtype;
  f jsonb;
  v_maxpct numeric;
  v_motivos text[] := '{}';
  v_alt text := null;
  v_lucro numeric; v_receita numeric;
  v_item_piso_duro boolean; v_item_piso boolean;
  v_cond record;
  v_aprovado boolean;
begin
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return jsonb_build_object('status', 'bloqueado', 'motivo', 'orcamento_nao_encontrado'); end if;
  select * into pr from public.parametros_comerciais where id = 1;
  f := private.orcamento_financeiro(p_orcamento);
  v_aprovado := o.aprovado_dono_em is not null;
  v_lucro := (f ->> 'lucro')::numeric;
  v_receita := (f ->> 'receita')::numeric;

  if (f ->> 'itens')::integer = 0 then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'orcamento_sem_itens', 'motivos', jsonb_build_array('orcamento_sem_itens'),
                              'alternativa', 'Adicione ao menos um item com SKU ao orçamento.');
  end if;
  if (f ->> 'itens_sem_produto')::integer > 0 then
    v_motivos := array_append(v_motivos, 'item_sem_sku_valido');
  end if;

  select coalesce(bool_or(i.quantidade * i.preco_unitario * (1 - pr.imposto_pct / 100 - (private.taxa_pagamento(o.metodo_previsto) ->> 'pct')::numeric / 100) < p.cost * i.quantidade), false),
         coalesce(bool_or(i.quantidade * i.preco_unitario < p.cost * i.quantidade * pr.multiplicador_piso), false)
    into v_item_piso_duro, v_item_piso
  from public.orcamento_itens i join public.products p on p.code = i.sku
  where i.orcamento_id = p_orcamento;

  -- sem aprovação possível
  if v_item_piso_duro then v_motivos := array_append(v_motivos, 'item_abaixo_do_piso_duro'); end if;
  if v_lucro < 0 then v_motivos := array_append(v_motivos, 'prejuizo'); end if;
  -- aprovável pelo dono (entre o piso_duro e o piso)
  if not v_aprovado then
    if v_item_piso then v_motivos := array_append(v_motivos, 'item_abaixo_do_piso'); end if;
    if (f ->> 'receita_itens_liquida')::numeric < (f ->> 'custo')::numeric * pr.multiplicador_piso then
      v_motivos := array_append(v_motivos, 'conjunto_abaixo_do_piso');
    end if;
    if v_lucro >= 0 and v_lucro < pr.lucro_liquido_minimo then v_motivos := array_append(v_motivos, 'lucro_abaixo_do_minimo'); end if;
  end if;

  -- política de desconto: só com condição especial vigente, dentro do valor concedido e do teto percentual
  if o.desconto_valor > 0 then
    select max(percentual) into v_maxpct from public.politica_desconto where tipo = 'desconto' and ativo;
    select c.valor into v_cond from public.condicoes_especiais c
      where c.orcamento_id = o.id and c.tipo = 'desconto' and c.resultado in ('oferecida', 'aceita') and c.valida_ate > now()
      order by c.criado_em desc limit 1;
    if not found then
      v_motivos := array_append(v_motivos, 'desconto_sem_condicao_especial');
    elsif o.desconto_valor > v_cond.valor + 0.005 then
      v_motivos := array_append(v_motivos, 'desconto_acima_do_teto');
    end if;
    if (f ->> 'subtotal')::numeric > 0 and o.desconto_valor / (f ->> 'subtotal')::numeric * 100 > coalesce(v_maxpct, 10) + 0.005 then
      v_motivos := array_append(v_motivos, 'desconto_acima_do_percentual_maximo');
    end if;
  end if;

  if cardinality(v_motivos) > 0 then
    v_alt := case
      when v_motivos && array['desconto_sem_condicao_especial', 'desconto_acima_do_teto', 'desconto_acima_do_percentual_maximo']
        then 'Remover o desconto ou usar a condição especial calculada pela função.'
      when v_motivos && array['item_sem_sku_valido'] then 'Trocar o item por um SKU existente no catálogo.'
      else format('Subir o total para pelo menos %s ou simplificar a especificação.', private.brl((f ->> 'receita_piso')::numeric))
      end;
    return jsonb_build_object('status', 'bloqueado', 'motivo', v_motivos[1], 'motivos', to_jsonb(v_motivos), 'alternativa', v_alt,
                              'lucro_liquido', v_lucro, 'receita', v_receita, 'receita_minima', (f ->> 'receita_piso')::numeric,
                              'receita_piso_duro', (f ->> 'receita_piso_duro')::numeric);
  end if;
  return jsonb_build_object('status', 'ok', 'lucro_liquido', v_lucro, 'receita', v_receita,
                            'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1),
                            'aprovado_pelo_dono', v_aprovado);
end;
$$;

-- ---------------------------------------------------------------- 5. calcular_condicao_especial
create or replace function public.calcular_condicao_especial(p_orcamento uuid, p_gatilho text, p_registrar boolean default true)
returns jsonb
language plpgsql set search_path = ''
as $$
declare
  o public.orcamentos%rowtype;
  pr public.parametros_comerciais%rowtype;
  pol public.politica_desconto%rowtype;
  f jsonb; fr jsonb;
  v_custo numeric; v_receita_atual numeric; v_extra numeric; v_extra_bike numeric; v_piso numeric;
  v_gordura numeric; v_base_elegivel numeric; v_cap numeric; v_valor numeric;
  v_tipo text; v_texto text; v_motivo text := 'sem_vantagem_aplicavel';
  v_itens jsonb; v_valida timestamptz; v_id uuid;
  v_outros integer; v_cacador integer; v_max_cond smallint; v_intervalo smallint;
begin
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_nao_encontrado'); end if;
  if p_gatilho not in ('G1', 'G2', 'G3') then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'gatilho_invalido'); end if;
  if o.status = 'rascunho' then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_ainda_nao_enviado'); end if;
  if o.status not in ('enviado', 'aceito') then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_encerrado'); end if;
  select * into pr from public.parametros_comerciais where id = 1;

  select min(max_condicoes_por_orcamento), min(intervalo_dias_contato) into v_max_cond, v_intervalo from public.politica_desconto where ativo;
  if v_max_cond is null then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'politica_desligada'); end if;

  if (select count(*) from public.condicoes_especiais c where c.orcamento_id = o.id and c.resultado <> 'cancelada') >= v_max_cond then
    return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'ja_houve_condicao_neste_orcamento');
  end if;
  if exists (select 1 from public.condicoes_especiais c
             where c.contact_id = o.contact_id and c.orcamento_id <> o.id and c.resultado <> 'cancelada'
               and c.criado_em > now() - make_interval(days => v_intervalo)) then
    return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'intervalo_entre_condicoes_do_contato');
  end if;
  select count(*) into v_cacador from public.orcamentos x
    where x.contact_id = o.contact_id and x.id <> o.id and x.criado_em > now() - make_interval(days => pr.cacador_janela_dias)
      and x.status <> 'rascunho' and not x.teste;
  if v_cacador + 1 >= pr.cacador_min_orcamentos
     and not exists (select 1 from public.orcamentos x where x.contact_id = o.contact_id and x.status = 'pago') then
    return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'cacador_de_desconto', 'sinalizar_dono', true);
  end if;

  f := private.orcamento_financeiro(o.id);
  if (f ->> 'itens')::integer = 0 then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_sem_itens'); end if;
  v_custo := (f ->> 'custo')::numeric;
  v_receita_atual := (f ->> 'subtotal')::numeric + o.arte_valor + o.frete_valor;
  v_extra := (f ->> 'extra')::numeric;
  v_piso := ceil(greatest(v_custo * pr.multiplicador_piso, private.receita_para_lucro(v_custo, v_extra, pr.lucro_liquido_minimo, o.metodo_previsto)) * 100) / 100;
  v_gordura := greatest(v_receita_atual - v_piso, 0);

  -- G1 e G2: vantagem sem custo (degrau 1) e, se não houver, desconto do degrau 2. G3: degrau 3 e, se não couber, a vantagem.
  for pol in
    select * from public.politica_desconto d
    where d.ativo and (p_gatilho = any (d.gatilhos) or (p_gatilho = 'G3' and d.degrau = 1))
    order by case when p_gatilho = 'G3' then (case d.degrau when 3 then 0 else 1 end) else d.degrau end
  loop
    v_tipo := null; v_valor := 0;

    if pol.tipo = 'vantagem' then
      -- frete grátis sem pedido mínimo: região central, cabe na bike, frete hoje cobrado do cliente
      select coalesce(jsonb_agg(jsonb_build_object('sku', i.sku, 'quantidade', i.quantidade)), '[]'::jsonb) into v_itens
        from public.orcamento_itens i where i.orcamento_id = o.id;
      fr := public.verificar_frete(coalesce(o.cep, o.bairro), v_itens, (f ->> 'subtotal')::numeric, false);
      v_extra_bike := private.custos_operacionais('bike');
      if o.frete_valor > 0 and (fr ->> 'regiao_central')::boolean and ((not pr.exigir_cabe_na_bike) or (fr ->> 'cabe_na_bike')::boolean)
         and (v_receita_atual - o.frete_valor) >= ceil(greatest(v_custo * pr.multiplicador_piso, private.receita_para_lucro(v_custo, v_extra_bike, pr.lucro_liquido_minimo, o.metodo_previsto)) * 100) / 100 then
        v_tipo := 'frete_gratis'; v_valor := o.frete_valor; v_texto := 'frete grátis, sem pedido mínimo';
      elsif o.arte_modo = 'paga' and o.arte_valor > 0 and (v_receita_atual - o.arte_valor) >= v_piso then
        v_tipo := 'arte_gratis'; v_valor := o.arte_valor; v_texto := 'criação da arte grátis';
      end if;
    else
      -- desconto: só sobre itens que permitem desconto, limitado pela gordura acima do piso e pelo teto em reais
      select coalesce(sum(i.quantidade * i.preco_unitario) filter (
               where p.permite_desconto and not (coalesce(p.category, '') = any (pr.categorias_sem_desconto))), 0)
        into v_base_elegivel
        from public.orcamento_itens i join public.products p on p.code = i.sku where i.orcamento_id = o.id;
      if v_base_elegivel <= 0 then
        v_motivo := 'itens_sem_permissao_de_desconto';
      elsif v_gordura <= 0 then
        v_motivo := 'sem_gordura_acima_do_piso';
      else
        v_cap := floor(least(v_base_elegivel * pol.percentual / 100, v_gordura * pol.fracao_gordura_max, pol.desconto_max_reais) * 100) / 100;
        if v_cap < pol.valor_minimo_reais then
          v_motivo := 'desconto_menor_que_o_minimo';
        else
          v_tipo := 'desconto'; v_valor := v_cap; v_texto := 'desconto de ' || private.brl(v_cap);
        end if;
      end if;
    end if;

    if v_tipo is not null then
      v_valida := now() + make_interval(hours => pol.validade_horas);
      if p_registrar then
        insert into public.condicoes_especiais (orcamento_id, contact_id, degrau, gatilho, tipo, valor, texto_curto, valida_ate)
        values (o.id, o.contact_id, pol.degrau, p_gatilho, v_tipo, v_valor, v_texto, v_valida) returning id into v_id;
      end if;
      return jsonb_build_object('tipo', v_tipo, 'texto_curto', v_texto, 'valor', v_valor, 'valida_ate', v_valida, 'degrau', pol.degrau, 'condicao_id', v_id);
    end if;
  end loop;

  return jsonb_build_object('tipo', 'sem_condicao', 'motivo', v_motivo);
end;
$$;

-- Permissões: só o dono (RLS) e a service role chamam. O anon não.
do $$
declare f text;
begin
  foreach f in array array[
    'public.calcular_preco(text,integer,jsonb)', 'public.calcular_prazo(text,timestamptz,boolean)',
    'public.verificar_frete(text,jsonb,numeric,boolean)', 'public.validar_margem(uuid)',
    'public.calcular_condicao_especial(uuid,text,boolean)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
