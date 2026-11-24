-- Auditoria de 24/11/2026 (Jordan, Alice, Paulo) + varredura de erros desde 21/11. Aditiva e idempotente.
-- 1) Busca: "10x15cm" (ou 10 x 15) vira o tamanho do catálogo (100 x 150, nas duas orientações) e "frente e verso"
--    prefere 4X4. Antes a Laura via só as opções 4X0 e dizia que não produzia frente e verso (SKU PA65G6 existe).
-- 2) Guarda de loop das ferramentas: o limite de 4 por ferramenta e 12 no total travava listas de orçamento grandes.
-- 3) Pedido pago: a trava de saída barra confirmação de alteração (furo, tamanho, acabamento, quantidade) e a entrada
--    avisa o dono (alta) quando o cliente pede alteração depois de pago.
-- 4) Cron (arte-varredura, carrinho-abandonado-varrer, agente-silencio-vigia) falhava 100% com "Sem permissão"
--    porque o pg_cron roda sem JWT e as funções só aceitavam equipe ou service_role.

-- (4) pg_cron e conexões diretas privilegiadas (session_user postgres) valem como servidor; PostgREST usa o papel authenticator.
create or replace function private.dono_ou_servidor() returns boolean
language sql stable security definer set search_path = ''
as $$ select private.is_staff() or coalesce(auth.role(), '') = 'service_role'
          or (auth.uid() is null and session_user in ('postgres', 'supabase_admin')); $$;
create or replace function private.atendente_ou_servidor() returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.profiles where id = (select auth.uid())) or coalesce(auth.role(), '') = 'service_role'
          or (auth.uid() is null and session_user in ('postgres', 'supabase_admin')); $$;

-- (2) Limites por rodada: a repetição idêntica segue sendo limitada pelo teto total e pelo teto de tokens da conversa.
update public.agente_config set max_ferramenta_por_rodada = 20, max_chamadas_por_rodada = 50 where id = 1;

do $mig$
declare v_def text; v_new text;
begin
  -- (1) buscar_produto
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'buscar_produto';
  if position('/* medida_axb_cm */' in v_def) = 0 then
    v_new := replace(v_def, 'v_escada jsonb := null;', 'v_escada jsonb := null; v_tam2 text := null; v_dm text[]; v_da numeric; v_db numeric;');
    v_new := replace(v_new, $q$  v_norm := btrim(regexp_replace(v_norm, '(^| )a[3-6]( |$)', ' ', 'g'));$q$,
$q$  if v_tam is null then /* medida_axb_cm */
    v_dm := regexp_match(v_norm, '(^| )([0-9]{1,2}(?:[.,][0-9])?) ?x ?([0-9]{1,2}(?:[.,][0-9])?)( ?cm)?( |$)');
    if v_dm is not null then
      v_da := replace(v_dm[2], ',', '.')::numeric; v_db := replace(v_dm[3], ',', '.')::numeric;
      if (v_dm[4] is not null or least(v_da, v_db) >= 5)
         and exists (select 1 from public.catalogo c where c.active and c.vendavel and c.preco_venda is not null
                       and (cardinality(v_cats_ok) = 0 or c.categoria = any (v_cats_ok))
                       and (c.tamanho_mm ilike '%' || round(v_da * 10)::int || ' x ' || round(v_db * 10)::int || '%'
                         or c.tamanho_mm ilike '%' || round(v_db * 10)::int || ' x ' || round(v_da * 10)::int || '%')) then
        v_tam := round(v_da * 10)::int || ' x ' || round(v_db * 10)::int;
        v_tam2 := round(v_db * 10)::int || ' x ' || round(v_da * 10)::int;
        v_norm := btrim(regexp_replace(v_norm, '(^| )[0-9]{1,2}([.,][0-9])? ?x ?[0-9]{1,2}([.,][0-9])?( ?cm)?( |$)', ' ', 'g'));
      end if;
    end if;
  end if;
  v_norm := btrim(regexp_replace(v_norm, '(^| )a[3-6]( |$)', ' ', 'g'));$q$);
    v_new := replace(v_new, $q$when v_norm ~ '(^| )4 ?x ?1( |$)' then '4X1'$q$,
      $q$when v_norm ~ '(frente e verso|frente verso|dois lados|2 lados|ambos os lados)' and v_norm !~ '(preto|p b|1 ?x ?1|monocrom|uma cor|1 cor)' then '4X4'
      when v_norm ~ '(^| )4 ?x ?1( |$)' then '4X1'$q$);
    v_new := replace(v_new, E'then ''1X0'' end;\n  end if;',
      E'then ''1X0'' end;\n  end if;\n  if v_cores_pref = ''4X4'' then v_norm := btrim(regexp_replace(v_norm, ''(^| )(frente e verso|frente verso|dois lados|2 lados|ambos os lados)( |$)'', '' '', ''g'')); end if;');
    v_new := replace(v_new, $q$(v_tam is null or c.tamanho_mm ilike '%' || v_tam || '%')$q$,
      $q$(v_tam is null or c.tamanho_mm ilike '%' || v_tam || '%' or (v_tam2 is not null and c.tamanho_mm ilike '%' || v_tam2 || '%'))$q$);
    if position('/* medida_axb_cm */' in v_new) = 0 or position('v_tam2 is not null and c.tamanho_mm' in v_new) = 0
       or position('v_cores_pref = ''4X4'' then v_norm' in v_new) = 0 or position('frente e verso|frente verso' in v_new) = 0 then
      raise exception 'buscar_produto: padrão da função mudou, revisar a migration';
    end if;
    execute v_new;
  end if;

  -- (3) trava de saída: nunca confirmar alteração depois do pagamento
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'private'::regnamespace and p.proname = 'saida_travas_extra';
  if position('alteracao_pos_pagamento' in v_def) = 0 then
    v_new := replace(v_def, E'  return v;\nend', $q$  if p_texto ~* '((j[aá]\s+)?(anotei|confirmei|alterei|ajustei|troquei|mudei|providenciei|combinei|avisei a produ[cç][aã]o)[^.!?]{0,90}(furo|carteirinha|tamanho|acabamento|quantidade|lamina[cç][aã]o|verniz|corte|papel|modelo|arte|produ[cç][aã]o)|(vai|v[aã]o|ir[aá]|ficar[aã]o?)\s+(sair|ficar)[^.!?]{0,50}(sem (o )?furo|igual|iguaizinh|como (voc[eê]|vc) pediu)|(consigo|conseguimos|podemos|d[aá] (pra|para)|posso)\s+(sim\s+)?(trocar|alterar|mudar|ajustar|tirar o furo)|(sem problema|perfeito|combinado|fechado)[^.!?]{0,40}(trocar|alterar|mudar|ajustar|sem furo))' then
    select ex.contact_id into v_ct from public.agente_execucoes ex where ex.id = p_exec;
    if exists (select 1 from public.orders o where o.contact_id = v_ct and o.excluido_em is null and (o.payment_status = 'aprovado' or o.payment_manual)
                 and coalesce(o.stage, '') not in ('entregue', 'perdido', 'cancelado')) then
      v := array_append(v, 'promessa:alteracao_pos_pagamento'); /* alteracao_pos_pagamento */
    end if;
  end if;
  return v;
end$q$);
    if position('alteracao_pos_pagamento' in v_new) = 0 then raise exception 'saida_travas_extra: padrão mudou'; end if;
    execute v_new;
  end if;
end
$mig$;

-- (3) entrada: cliente com pedido pago pedindo alteração avisa o dono (alta) e orienta a Laura; nunca confirma.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'agente_entrada';
  if position('alteracao_pos_pagamento' in v_def) = 0 then
    v_new := replace(v_def, 'declare r jsonb; p jsonb;', 'declare r jsonb; p jsonb; v_msg record; v_pago_ativo boolean := false;');
    v_new := replace(v_new, E'  return r;\nend', $q$  if coalesce((r ->> 'processar')::boolean, false) and r ->> 'conversation_id' is not null then /* alteracao_pos_pagamento */
    begin
      select m.body, m.type into v_msg from public.messages m where m.id = p_message;
      select exists (select 1 from public.orders o where o.contact_id = (r ->> 'contact_id')::uuid and o.excluido_em is null
                       and (o.payment_status = 'aprovado' or o.payment_manual) and coalesce(o.stage, '') not in ('entregue', 'perdido', 'cancelado')) into v_pago_ativo;
      r := r || jsonb_build_object('pedido_pago_ativo', v_pago_ativo);
      if v_pago_ativo and coalesce(v_msg.body, '') ~* '(trocar|troca |alterar|altera[cç][aã]o|mudar|mudan[cç]a|ao inv[eé]s|em vez de|na verdade|corrig|sem (o )?furo|tirar o furo|aumentar|diminuir|mais [0-9]+ |menos [0-9]+ )' then
        perform public.agente_chamar_dono((r ->> 'conversation_id')::uuid,
          'Cliente com pedido PAGO pediu alteração de especificação. A Laura não confirma: verificar com a produção se ainda dá antes de imprimir.', 'alta');
        r := r || jsonb_build_object('alteracao_pos_pagamento', true,
          'orientacao_alteracao', 'Pedido já pago: NUNCA confirme alteração de produto, acabamento, furo, tamanho ou quantidade. Diga só que vai verificar com o responsável se ainda é possível antes da produção e que retorna em seguida.');
      end if;
    exception when others then null;
    end;
  end if;
  return r;
end$q$);
    if position('alteracao_pos_pagamento' in v_new) = 0 then raise exception 'agente_entrada: padrão mudou'; end if;
    execute v_new;
  end if;
end
$mig$;
