-- Rodada de 17/11/2026 (análise de vendas perdidas): o contexto do agente perdia o anúncio de origem
-- (a Meta devolve headline e body; o prompt lia titulo e texto) e o lembrete de conversa parada usava nome com emoji.
-- Aditiva e idempotente.

create or replace function pg_temp.trocar(p_def text, p_velho text, p_novo text) returns text language plpgsql as $f$
begin
  if position(p_velho in p_def) = 0 then raise exception 'trecho não encontrado: %', left(p_velho, 80); end if;
  return replace(p_def, p_velho, p_novo);
end $f$;

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'agente_contexto';
  if position('/* anuncio_titulo */' in v_def) = 0 then
    v_new := pg_temp.trocar(v_def, $q$if r ? 'erro' then return r; end if;$q$,
      $q$if r ? 'erro' then return r; end if;
  if jsonb_typeof(r -> 'anuncio') = 'object' then /* anuncio_titulo */
    r := jsonb_set(r, '{anuncio}', (r -> 'anuncio') || jsonb_build_object(
      'titulo', coalesce(r -> 'anuncio' ->> 'titulo', r -> 'anuncio' ->> 'headline'),
      'texto', coalesce(r -> 'anuncio' ->> 'texto', r -> 'anuncio' ->> 'body')));
  end if;$q$);
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'followup_montar';
  if position('/* q1_v2 */' in v_def) = 0 then
    v_new := pg_temp.trocar(v_def, $q$when 0 then format('Oi, %s! Vi que ficou faltando só um detalhe pra eu montar o seu orçamento. Me responde por aqui que eu já resolvo rapidinho, tá bom?', n)$q$,
      $q$when 0 then format('Oi, %s! Passando pra saber se deu pra ver o que te mandei. Me conta só o que falta que eu já fecho o seu orçamento e te mando o PDF ainda hoje, combinado?', n) /* q1_v2 */$q$);
    v_new := pg_temp.trocar(v_new, $q$else format('Oi, %s! Conseguiu ver a minha última mensagem? Me passa o que falta que eu já te mando o valor certinho.', n) end;$q$,
      $q$else format('Oi, %s! Ainda tá precisando disso? Se me confirmar a quantidade e se já tem a arte, eu monto o orçamento agora mesmo.', n) end;$q$);
    execute v_new;
  end if;
end $mig$;

-- Nome do lembrete: só letras (perfil com emoji ou símbolo vira "cliente").
create or replace function private.fu_nome(p_nome text) returns text language sql immutable set search_path = '' as
$$ select coalesce(nullif(initcap(regexp_replace(split_part(trim(coalesce(p_nome, '')), ' ', 1), '[^A-Za-zÀ-ÿ-]', '', 'g')), ''), 'cliente'); $$;
