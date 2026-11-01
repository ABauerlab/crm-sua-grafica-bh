-- Etapa 8: números BR chegam da Meta com ou sem o 9 depois do DDD. Compara as duas formas (dono e piloto).
-- Reverter: restaurar agente_bloqueio de 20261105000003 e dropar private.wa_variantes.
-- (Corpo aplicado no banco via MCP; ver docs/auditoria-agente.md.)
create or replace function private.wa_variantes(p text) returns text[]
language sql immutable set search_path = ''
as $$
  select case
    when p ~ '^55[0-9]{2}9[0-9]{8}$' then array[p, substr(p,1,4) || substr(p,6)]
    when p ~ '^55[0-9]{2}[0-9]{8}$'  then array[p, substr(p,1,4) || '9' || substr(p,5)]
    else array[coalesce(p,'')]
  end;
$$;
-- agente_bloqueio passa a usar: v_conv.wa_id = any (private.wa_variantes(cfg.whatsapp_dono)) e as variantes de piloto_wa_ids.
