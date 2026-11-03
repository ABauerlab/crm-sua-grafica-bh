-- Etapa 8C: fidelidade do simulador. Em conversa de TESTE (contacts.is_teste), quando o despachante simula gerar_pdf_orcamento o
-- orçamento passa a constar como "PDF enviado" (como acontece de verdade) e, quando simula enviar_foto_produto, as mensagens das
-- opções entram no histórico. Contatos reais não são afetados.
create or replace function public.agente_tool_fim(p_execucao uuid, p_ferramenta text, p_duracao_ms integer, p_ok boolean, p_skus text[] default '{}'::text[], p_valores numeric[] default '{}'::numeric[], p_resumo text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_conv uuid; v_contact uuid; v_teste boolean := false; k integer;
begin
  update public.agente_execucoes set
    skus_vistos = (select coalesce(array_agg(distinct s), '{}') from unnest(skus_vistos || coalesce(p_skus, '{}')) s where s is not null and s <> ''),
    valores_vistos = (select coalesce(array_agg(distinct round(v, 2)), '{}') from unnest(valores_vistos || coalesce(p_valores, '{}')) v where v is not null)
  where id = p_execucao
  returning conversation_id into v_conv;

  if p_ok and p_ferramenta in ('gerar_pdf_orcamento', 'enviar_foto_produto') and v_conv is not null then
    select c.id, c.is_teste into v_contact, v_teste from public.conversations cv join public.contacts c on c.id = cv.contact_id where cv.id = v_conv;
    if coalesce(v_teste, false) then
      if p_ferramenta = 'gerar_pdf_orcamento' then
        update public.orcamentos set pdf_enviado_em = now(), pdf_gerado_em = coalesce(pdf_gerado_em, now()), status = case when status = 'rascunho' then 'enviado' else status end
         where id = (select id from public.orcamentos where contact_id = v_contact and status in ('rascunho', 'enviado') and pdf_enviado_em is null order by criado_em desc limit 1);
      else
        for k in 1 .. 3 loop
          insert into public.messages (conversation_id, wa_message_id, direction, type, body, status, created_at)
          values (v_conv, 'teste.opcao.' || gen_random_uuid()::text, 'out', 'text', 'Opção ' || k || ' (foto e ficha enviadas)', 'sent', now() - make_interval(secs => (4 - k)));
        end loop;
      end if;
    end if;
  end if;

  return public.agente_log(p_execucao, 'ferramenta', p_ferramenta, null, 0, 0, p_duracao_ms,
    jsonb_build_object('resumo', left(coalesce(p_resumo, ''), 300)), case when p_ok then 'ok' else 'falhou' end);
end;
$function$;
