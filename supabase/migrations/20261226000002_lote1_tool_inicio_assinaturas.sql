-- Lote 1: assinaturas de agente_tool_inicio sem ambiguidade.
-- A versão de 3 argumentos com valor padrão colidia, em chamada posicional, com a sobrecarga antiga
-- (p_conversa, p_ferramenta, p_args, p_contadores). Agora:
--   * (uuid, text) volta a existir (chamadas antigas e testes continuam iguais);
--   * (uuid, text, jsonb) não tem padrão; o n8n chama por nome (p_execucao, p_ferramenta, p_args).
drop function if exists public.agente_tool_inicio(uuid, text, jsonb);

create or replace function public.agente_tool_inicio(p_execucao uuid, p_ferramenta text, p_args jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  cfg record; v_n integer; v_total integer; v_falha text; v_ferr jsonb; v_buscas jsonb := '[]'::jsonb;
  v_termo text; v_qtd text; v_bloqueio text; v_idem integer; v_len integer; v_vazias integer; v_sim integer;
begin
  select * into cfg from public.agente_config where id = 1;
  if exists (select 1 from public.agente_execucoes ex where ex.id = p_execucao and ex.rascunho) /* rascunho_bloqueio */
     and p_ferramenta not in ('buscar_produto', 'buscar_conhecimento', 'montar_orcamento', 'verificar_frete', 'salvar_contato') then
    return jsonb_build_object('permitido', false, 'motivo', 'rascunho');
  end if;
  update public.agente_execucoes
  set ferramentas = jsonb_set(ferramentas, array[p_ferramenta], to_jsonb(coalesce((ferramentas ->> p_ferramenta)::int, 0) + 1))
  where id = p_execucao
  returning ferramentas, teste_falha, buscas into v_ferr, v_falha, v_buscas;
  if v_ferr is null then return jsonb_build_object('permitido', false, 'motivo', 'sem_execucao'); end if;
  v_n := (v_ferr ->> p_ferramenta)::int;
  select coalesce(sum(value::int), 0) into v_total from jsonb_each_text(v_ferr);
  if v_n > cfg.max_ferramenta_por_rodada or v_total > cfg.max_chamadas_por_rodada then
    perform public.agente_log(p_execucao, 'loop_ferramenta', p_ferramenta, null, 0, 0, null, jsonb_build_object('chamadas', v_n, 'total', v_total), 'bloqueado');
    return jsonb_build_object('permitido', false, 'motivo', 'loop', 'chamadas', v_n);
  end if;

  -- Freio específico das buscas (o teto global de 20 distintas continua valendo): 4a busca idêntica, 3 buscas
  -- seguidas sem nenhum resultado, ou 5 buscas seguidas quase iguais (sem progresso) encerram o loop.
  if p_ferramenta = 'buscar_produto' then
    v_termo := btrim(regexp_replace(lower(extensions.unaccent(coalesce(p_args ->> 'termo', ''))), '[^a-z0-9 ]+', ' ', 'g'));
    v_termo := regexp_replace(v_termo, '\s+', ' ', 'g');
    v_qtd := coalesce(p_args ->> 'quantidade', '');
    v_len := jsonb_array_length(v_buscas);
    if v_termo <> '' then
      select count(*) into v_idem from jsonb_array_elements(v_buscas) b where b ->> 't' = v_termo and coalesce(b ->> 'q', '') = v_qtd;
      if v_idem >= 3 then v_bloqueio := 'busca_repetida'; end if;
      if v_bloqueio is null and v_len >= 5 then
        select count(*) into v_sim from (select b from jsonb_array_elements(v_buscas) with ordinality t(b, i) order by i desc limit 5) x
         where private.jaccard_tokens(x.b ->> 't', v_termo) >= 0.5;
        if v_sim >= 5 then v_bloqueio := 'busca_sem_progresso'; end if;
      end if;
    end if;
    if v_bloqueio is null and v_len >= 3 then
      select count(*) filter (where (x.b ->> 'v') = 'true') into v_vazias from (select b from jsonb_array_elements(v_buscas) with ordinality t(b, i) order by i desc limit 3) x;
      if v_vazias = 3 then v_bloqueio := 'buscas_sem_retorno'; end if;
    end if;
    if v_bloqueio is not null then
      perform public.agente_log(p_execucao, 'loop_ferramenta', p_ferramenta, null, 0, 0, null,
        jsonb_build_object('motivo', v_bloqueio, 'termo', v_termo, 'quantidade', v_qtd, 'buscas', v_len), 'bloqueado');
      return jsonb_build_object('permitido', false, 'motivo', v_bloqueio, 'chamadas', v_n);
    end if;
    update public.agente_execucoes set buscas = v_buscas || jsonb_build_array(jsonb_build_object('t', v_termo, 'q', v_qtd, 'v', null)) where id = p_execucao;
  end if;
  return jsonb_build_object('permitido', true, 'simular_falha', coalesce(v_falha = p_ferramenta, false), 'chamada', v_n);
end;
$function$;

create or replace function public.agente_tool_inicio(p_execucao uuid, p_ferramenta text)
 returns jsonb
 language sql
 security definer
 set search_path to ''
as $function$
  select public.agente_tool_inicio(p_execucao := p_execucao, p_ferramenta := p_ferramenta, p_args := '{}'::jsonb);
$function$;
