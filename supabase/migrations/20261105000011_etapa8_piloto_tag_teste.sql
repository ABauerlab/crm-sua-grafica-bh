-- Etapa 8: contatos de teste (tag "teste", criados pelo webhook de teste do WF1) não ficam presos ao piloto.
do $$ declare d text; d2 text; begin
 d := pg_get_functiondef('public.agente_bloqueio(uuid)'::regprocedure);
 d2 := replace(d, 'ct.optout, ct.wa_id into v_conv', 'ct.optout, ct.wa_id, ct.tags into v_conv');
 d2 := replace(d2, 'if coalesce(cfg.piloto_ativo, false) then', 'if coalesce(cfg.piloto_ativo, false) and not (''teste'' = any (coalesce(v_conv.tags, ''{}''))) then');
 if d2 <> d then execute d2; end if;
end $$;
