-- Etapa 8B: o retrato do teste passa a incluir os valores dos orçamentos do contato. O agente pode citar o total de um
-- orçamento já montado (por uma ferramenta ou pelo preparo do cenário); isso não é preço inventado.
create or replace function public.e2e_snapshot(p_caso uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  c record;
  v_conv uuid;
  v_contact uuid;
  v_ferr text[];
  v_valores jsonb;
  v_valores_orc jsonb;
  v_links text[];
  v_links_orc text[];
  v_tok bigint; v_custo numeric;
  v_lucro boolean;
begin
  select * into c from public.testes_conversa where id = p_caso;
  if not found then return jsonb_build_object('ok', false, 'motivo', 'caso_inexistente'); end if;
  v_conv := (c.ultimo_resultado ->> 'conversation_id')::uuid;
  v_contact := (c.ultimo_resultado ->> 'contact_id')::uuid;
  select coalesce(array_agg(distinct ferramenta), '{}') into v_ferr from public.agent_logs where conversation_id = v_conv and action = 'ferramenta' and ferramenta is not null;
  select coalesce(jsonb_agg(distinct v), '[]'::jsonb) into v_valores from public.agente_execucoes e, lateral unnest(coalesce(e.valores_vistos, '{}')) v where e.conversation_id = v_conv;
  select coalesce(jsonb_agg(distinct v), '[]'::jsonb) into v_valores_orc from (
    select unnest(array[o.subtotal, o.total, o.frete_valor, o.arte_valor, o.desconto_valor]) v from public.orcamentos o where o.contact_id = v_contact
    union all
    select unnest(array[i.valor_total, i.preco_unitario]) from public.orcamento_itens i join public.orcamentos o on o.id = i.orcamento_id where o.contact_id = v_contact
  ) x where v is not null and v > 0;
  select coalesce(array_agg(distinct m[1]), '{}') into v_links from public.agent_logs l, lateral regexp_matches(coalesce(l.result::text, ''), '(https?://[^\s"\\)]+)', 'g') m where l.conversation_id = v_conv;
  select coalesce(array_agg(link_pagamento) filter (where link_pagamento is not null), '{}') into v_links_orc from public.orcamentos where contact_id = v_contact;
  select coalesce(sum(coalesce(tokens_entrada, 0) + coalesce(tokens_saida, 0)), 0), coalesce(sum(custo_estimado), 0) into v_tok, v_custo from public.agente_execucoes where conversation_id = v_conv;
  select exists (
    select 1 from public.orcamentos o join public.orcamento_itens i on i.orcamento_id = o.id
     where o.contact_id = v_contact
       and ((i.piso_duro is not null and i.valor_total is not null and i.valor_total + 0.005 < i.piso_duro) or (i.lucro_liquido is not null and i.lucro_liquido < -0.005))
  ) into v_lucro;
  return jsonb_build_object('ok', true, 'status', c.ultimo_status, 'saidas', coalesce(c.ultimo_resultado -> 'saidas', '[]'::jsonb),
    'conversation_id', v_conv, 'contact_id', v_contact, 'ferramentas', to_jsonb(v_ferr), 'valores_vistos', v_valores, 'valores_orcamentos', v_valores_orc,
    'links_vistos', to_jsonb(v_links), 'links_orcamento', to_jsonb(v_links_orc), 'tokens', v_tok, 'custo', v_custo,
    'alerta', exists (select 1 from public.alertas where conversation_id = v_conv), 'violacao_lucro', v_lucro);
end;
$$;
revoke execute on function public.e2e_snapshot(uuid) from public, anon, authenticated;
grant execute on function public.e2e_snapshot(uuid) to service_role;
