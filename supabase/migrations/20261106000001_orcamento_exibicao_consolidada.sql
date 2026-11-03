-- Orçamento em PDF: exibição consolidada e quadro de alternativas.
-- Aditiva e idempotente. O cálculo (orcamento_itens em lotes do catálogo, usado por validar_margem e pelo link de pagamento) não muda.
-- Duas colunas opcionais em orcamentos, só para o que o cliente vê:
--   itens_exibicao: uma linha por produto, com a quantidade real e o valor unitário (jsonb array de
--                   {descricao, especificacao, quantidade, valor_unitario, valor_total});
--   alternativas:   quadro "Opções e sugestões alternativas" (jsonb array de {titulo, texto}).
-- Segurança: a exibição só vale se a soma dos totais for igual ao subtotal do orçamento; senão o PDF cai para as linhas calculadas.

alter table public.orcamentos add column if not exists itens_exibicao jsonb;
alter table public.orcamentos add column if not exists alternativas jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orcamentos_itens_exibicao_tipo') then
    alter table public.orcamentos add constraint orcamentos_itens_exibicao_tipo
      check (itens_exibicao is null or (jsonb_typeof(itens_exibicao) = 'array' and jsonb_array_length(itens_exibicao) between 1 and 10));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'orcamentos_alternativas_tipo') then
    alter table public.orcamentos add constraint orcamentos_alternativas_tipo
      check (alternativas is null or (jsonb_typeof(alternativas) = 'array' and jsonb_array_length(alternativas) <= 6));
  end if;
end $$;

create or replace function public.orcamento_documento(p_orcamento uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o public.orcamentos%rowtype; pr public.parametros_comerciais%rowtype;
  v_cli text; v_emp jsonb; v_itens jsonb; v_cond record; v_cond_json jsonb := null;
  v_pronto date; v_frase text; pz jsonb; s text; v_versao integer; v_doc jsonb; v_opc jsonb := null;
  v_skus text[]; v_vencido boolean; v_inicio date; v_exib numeric;
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

  -- exibição consolidada (uma linha por produto): só vale se fechar com o subtotal; o prazo continua vindo dos SKUs
  if o.itens_exibicao is not null then
    select coalesce(sum((e ->> 'valor_total')::numeric), 0) into v_exib from jsonb_array_elements(o.itens_exibicao) e;
    if round(v_exib, 2) = round(coalesce(o.subtotal, 0), 2) then v_itens := o.itens_exibicao; end if;
  end if;

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
    'alternativas', o.alternativas,
    'empresa', jsonb_build_object(
      'nome', coalesce(v_emp ->> 'name', 'Sua Gráfica BH'), 'cnpj', coalesce(v_emp ->> 'cnpj', '58.481.181/0001-03'),
      'telefone', nullif(v_emp ->> 'phone', ''), 'email', nullif(v_emp ->> 'email', ''),
      'instagram', nullif(v_emp ->> 'instagram', ''), 'site', nullif(v_emp ->> 'site', '')));
  return v_doc || jsonb_build_object('hash', md5(v_doc::text), 'vencido', v_vencido, 'status', o.status);
end;
$$;
revoke execute on function public.orcamento_documento(uuid) from public, anon;
grant execute on function public.orcamento_documento(uuid) to authenticated, service_role;
