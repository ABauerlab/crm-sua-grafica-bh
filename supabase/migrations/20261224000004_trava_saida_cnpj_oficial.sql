-- A Laura citou o CNPJ de memória pra um cliente desconfiado e cortou o número pela metade
-- (58.481. em vez de 58.481.181/0001-03), mesmo o CNPJ correto já estando em `buscar_conhecimento`.
-- A trava de saída agora confere qualquer CNPJ citado contra o número oficial e bloqueia a
-- mensagem inteira se vier errado ou incompleto, obrigando o WF2 a reformular usando a ferramenta.
-- Aditiva e idempotente (reescreve a função inteira; aplicada em produção pelo conector).
CREATE OR REPLACE FUNCTION public.agente_saida_base_execucao(p_execucao uuid, p_texto text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  ex record;
  pc record;
  v text := coalesce(p_texto, '');
  v_motivos text[] := '{}';
  v_sku text;
  v_m text[];
  v_valor numeric;
  v_ok boolean;
  v_fixos numeric[];
  v_ctx numeric[];
  v_regras text[][] := array[
    array['custo', '(\m(nosso|nossa|nossos|meu|minha)\s+custos?\M|\mpre[cç]o\s+de\s+custo\M|\mcustos?\s+(de\s+)?(produ[cç][aã]o|fabrica[cç][aã]o|interno|internos|real|reais)\M|\mcustos?\s+do\s+fornecedor\M)'],
    array['margem', '\mmargem\M(?!\s+(de\s+|da\s+|do\s+)?(seguran[cç]a|sangria|corte|branca|interna|externa|impress[aã]o|arte|papel))'],
    array['piso', '\mpiso\M'],
    array['fornecedor', '\mfornecedor(es)?\M'],
    array['sku', '\msku\M'],
    array['bicicleta', '\m(bicicleta|bike|ciclista)\M'],
    array['endereco', '(rua rio de janeiro,? *n?º? *462|\m22\s*[ºo°]?\s*andar|\msala\s*(2216|2217)\M|\m30160-?040\M)']
  ];
  i int;
begin
  select * into ex from public.agente_execucoes where id = p_execucao;
  select arte_valor, arte_frete_valor, pedido_minimo_frete_gratis into pc from public.parametros_comerciais where id = 1;
  v_fixos := array[pc.arte_valor, pc.arte_frete_valor, pc.pedido_minimo_frete_gratis];

  select coalesce(array_agg(x), '{}') into v_ctx
  from (
    select unnest(array[o.total, o.subtotal, o.arte_valor, o.frete_valor, o.desconto_valor]) as x
    from public.orcamentos o
    join public.conversations cv on cv.contact_id = o.contact_id
    where cv.id = ex.conversation_id and o.status in ('rascunho', 'enviado', 'aceito')
      and (o.validade_ate is null or o.validade_ate > now())
  ) t where x is not null and x > 0;

  -- Valores que as ferramentas já confirmaram antes nesta mesma conversa (últimas 12 h) também valem: um resumo do que já foi cotado não pode ser bloqueado.
  select v_ctx || coalesce(array_agg(distinct y), '{}') into v_ctx /* valores_da_conversa */
    from (select unnest(e2.valores_vistos) as y from public.agente_execucoes e2
           where e2.conversation_id = ex.conversation_id and e2.id <> ex.id and e2.iniciado_em > now() - interval '12 hours' and e2.valores_vistos is not null) z
   where y is not null and y > 0;

  v := regexp_replace(v, '\s*[—–]\s*', ', ', 'g');
  v := regexp_replace(v, '\*+', '', 'g');
  v := regexp_replace(v, '`+', '', 'g');
  v := regexp_replace(v, '(^|\n)\s*#{1,6}\s+', '\1', 'g');
  v := regexp_replace(v, '(^|\n)\s*[-•]\s+', '\1', 'g');
  v := regexp_replace(v, '[ \t]+\n', E'\n', 'g');
  v := regexp_replace(v, '\n{3,}', E'\n\n', 'g');
  v := trim(v);
  if v = '' then v_motivos := array_append(v_motivos, 'vazia'::text); end if;

  for i in 1 .. array_length(v_regras, 1) loop
    if v ~* v_regras[i][2] then v_motivos := array_append(v_motivos, ('vazamento:' || v_regras[i][1])::text); end if;
  end loop;

  -- CNPJ oficial da Sua Gráfica BH (BauerLab): 58.481.181/0001-03. Dado público, mas só pode sair
  -- exatamente como está na ficha de conhecimento; nunca gerado de memória nem truncado.
  for v_m in select regexp_matches(v, '\mcnpj\M[^0-9]{0,12}([0-9][0-9./ -]{3,20})', 'gi') loop /* cnpj_oficial */
    if regexp_replace(v_m[1], '[^0-9]', '', 'g') <> '58481181000103' then
      v_motivos := array_append(v_motivos, 'vazamento:cnpj_incorreto'::text);
    end if;
  end loop;

  if ex.skus_vistos is not null then
    foreach v_sku in array ex.skus_vistos loop
      if length(v_sku) >= 3 and v ~* ('\m' || regexp_replace(v_sku, '([^[:alnum:]])', '\\\1', 'g') || '\M') then
        v_motivos := array_append(v_motivos, 'vazamento:sku_do_catalogo'::text);
      end if;
    end loop;
  end if;

  for v_m in select regexp_matches(v, 'R\$\s*(\d[\d\.]*(?:,\d{1,2})?)', 'g') loop
    v_valor := replace(replace(v_m[1], '.', ''), ',', '.')::numeric;
    v_ok := false;
    if ex.valores_vistos is not null and exists (select 1 from unnest(ex.valores_vistos) x where abs(x - v_valor) < 0.011) then v_ok := true; end if;
    if exists (select 1 from unnest(v_fixos) x where abs(x - v_valor) < 0.011) then v_ok := true; end if;
    if exists (select 1 from unnest(v_ctx) x where abs(x - v_valor) < 0.011) then v_ok := true; end if;
    if not v_ok then v_motivos := array_append(v_motivos, 'preco_nao_verificado'::text); end if;
  end loop;

  return jsonb_build_object(
    'ok', coalesce(array_length(v_motivos, 1), 0) = 0,
    'motivos', to_jsonb((select coalesce(array_agg(distinct x), '{}') from unnest(v_motivos) x)),
    'texto', v,
    'texto_seguro', 'Deixa eu confirmar isso certinho aqui e já te respondo, tá?');
end;
$function$;
