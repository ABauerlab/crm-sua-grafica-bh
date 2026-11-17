-- A Laura precisa se corrigir sozinha. (1) "tirantes de brinde" (produto que o cliente pediu) não é promessa de desconto.
-- (2) A trava de saída devolve `soft_only` e `texto_saneado` (resposta sem as frases barradas por preço não verificado
-- ou promessa), usados pelo WF2 depois de uma repetição. (3) Busca de crachá: o plástico/PVC é o crachá comum, e lotes
-- muito maiores que a quantidade pedida ficam por último. Aditiva e idempotente (aplicada em produção pelo conector).
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'agente_promessas_indevidas_execucao';
  if position('/* brinde_ok */' in v_def) = 0 then
    v_new := replace(v_def, $q$|de\s+brinde|ganha\s+(um|uma)\s+\w+\s+de\s+brinde)$q$, $q$|ganha(r|rá|ra)?\s+[^.!?]{0,40}brinde|brinde\s+(gr[aá]tis|de\s+cortesia))$q$);
    v_new := replace(v_new, 'v_cond_txt boolean;', 'v_cond_txt boolean; /* brinde_ok */');
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'agente_saida_segura';
  if position('/* texto_saneado */' in v_def) = 0 then
    v_new := replace(v_def, 'v_prom text[]; v_ct uuid; v_mot jsonb;', 'v_prom text[]; v_ct uuid; v_mot jsonb; v_s text; v_san text := ''''; v_soft boolean;');
    v_new := replace(v_new, E'  return r;\nend;', $q$  if not coalesce((r ->> 'ok')::boolean, true) then /* texto_saneado */
    v_soft := not exists (select 1 from jsonb_array_elements_text(r -> 'motivos') mm where mm not like 'promessa:%' and mm <> 'preco_nao_verificado');
    if v_soft then
      for v_s in select btrim(x) from regexp_split_to_table(coalesce(p_texto, ''), '(?<=[.!?])\s+|\n+') x where btrim(x) <> '' loop
        if jsonb_array_length(public.agente_saida_base_execucao(p_execucao, v_s) -> 'motivos') = 0
           and coalesce(array_length(public.agente_promessas_indevidas_execucao(p_execucao, v_s), 1), 0) = 0 then
          v_san := v_san || case when v_san = '' then '' else ' ' end || v_s;
        end if;
      end loop;
      r := r || jsonb_build_object('soft_only', true, 'texto_saneado', case when length(v_san) >= 25 then v_san end);
    else
      r := r || jsonb_build_object('soft_only', false);
    end if;
  end if;
  return r;
end;$q$);
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'buscar_produto';
  if position('/* lote_razoavel */' in v_def) = 0 then
    v_new := replace(v_def, 'order by case when v_cores_pref is not null',
      'order by case when v_qtd is not null and not v_exact and quantidade > greatest(v_qtd * 12, 30) then 1 else 0 end /* lote_razoavel */, case when v_cores_pref is not null');
    v_new := replace(v_new, $q$and not (x = 'pvc' and position('plastico' in v_norm) > 0) /* pvc_plastico */)$q$,
      $q$and not (x = 'pvc' and position('plastico' in v_norm) > 0) and not (x in ('plastico', 'pvc') and v_norm ~ 'cracha') /* pvc_plastico */)$q$);
    execute v_new;
  end if;
end $mig$;

-- Tirante é cordão de crachá (lanyard): a busca entende os dois nomes.
insert into public.sinonimos (grupo, termo) values ('cordao', 'cordao'), ('cordao', 'cordao para cracha'), ('cordao', 'tirante'), ('cordao', 'lanyard'), ('cordao', 'cordao de pescoco')
on conflict do nothing;
