-- Atenção (needs_human) só em reclamação, cancelamento, estorno/reembolso, defeito, pedido explícito de pessoa
-- ou pagamento não identificado. Falha do agente, trava de saída e dúvida de venda viram aviso de baixa gravidade
-- e nunca travam a conversa. Aplicada pelo conector (marcas: atencao_so_reclamacao, vigia_baixa). Aditiva e idempotente.
create or replace function public.agente_chamar_dono(p_conversation uuid, p_motivo text, p_gravidade text default 'baixa', p_tipo text default 'agente_chamado')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_contact uuid; v_r jsonb; v_grav text; v_motivo text := left(trim(coalesce(p_motivo, '')), 300); v_critico boolean;
begin
  select contact_id into v_contact from public.conversations where id = p_conversation;
  if v_contact is null then return jsonb_build_object('ok', false, 'motivo', 'conversa_inexistente'); end if; /* atencao_so_reclamacao */
  v_critico := p_tipo in ('reclamacao', 'pagamento_problema', 'pedido_humano', 'cancelamento', 'estorno')
    or v_motivo ~* '(pediu\s+(atendente\s+)?humano|falar\s+com\s+(uma\s+|algu[eé]m|a\s+)?(pessoa|atendente|dono)|reclama[cç][aã]o|reclamou|estorno|reembolso|cancelar\s+(o\s+)?pedido|defeito|pagou\s+e\s+n[aã]o)';
  v_grav := case when v_critico and p_gravidade = 'alta' then 'alta' else 'baixa' end;
  v_r := public.alerta_criar(p_tipo, v_grav, v_contact, p_conversation, null, p_motivo,
    jsonb_build_object('motivo', v_motivo, 'critico', v_critico));
  if v_critico and v_grav = 'alta' then update public.conversations set needs_human = true where id = p_conversation; end if;
  return v_r;
end;
$$;
-- (vigia de silêncio passou a alertar com gravidade baixa e texto "retomada automática já trata"; limpeza de needs_human indevido feita na aplicação.)
