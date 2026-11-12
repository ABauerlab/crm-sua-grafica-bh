-- Aplicada em produção em 12/11/2026 (por substituição sobre a definição vigente, idempotente: falha se o padrão sumir).
-- 1) preparar_link_pagamento: "ok", "sim", "beleza" etc. só valem como aprovação se forem a mensagem inteira; saem "pix", "cartão", "certo" e "beleza" soltos.
-- 2) agente_salvar_contato: marketing_consent é texto (none, opted_in, opted_out), não booleano.
do $outer$
declare d text; d0 text;
begin
  d := pg_get_functiondef('public.preparar_link_pagamento(uuid)'::regprocedure); d0 := d;
  d := replace(d, 'and coalesce(m.body, '''') ~* ''(aprov', 'and (btrim(coalesce(m.body, '''')) ~* ''^(sim|ok|beleza|certo|perfeito|pode)[!. ]*$'' or coalesce(m.body, '''') ~* ''(aprov');
  d := replace(d, '|\mpix\M|cart[aã]o|certo|isso mesmo|tudo certo|beleza|combinado|\mok\M|\msim\M|pode ser|vamos)''', '|isso mesmo|tudo certo|combinado|pode ser|vamos)'')');
  if d = d0 then raise exception 'preparar_link_pagamento: padrão não encontrado'; end if;
  execute d;
  d := pg_get_functiondef('public.agente_salvar_contato(uuid,jsonb)'::regprocedure); d0 := d;
  d := replace(d, 'marketing_consent = case when v_cons = ''sim'' then true when v_cons = ''nao'' then false else marketing_consent end,', 'marketing_consent = case when v_cons in (''sim'', ''opted_in'') then ''opted_in'' when v_cons in (''nao'', ''opted_out'') then ''opted_out'' else marketing_consent end,');
  d := replace(d, 'v_cons in (''sim'', ''nao'')', 'v_cons in (''sim'', ''nao'', ''opted_in'', ''opted_out'')');
  d := replace(d, 'if c.marketing_consent is not null then', 'if c.marketing_consent is not null and c.marketing_consent <> ''none'' then');
  if d = d0 then raise exception 'agente_salvar_contato: padrão não encontrado'; end if;
  execute d;
end $outer$;
