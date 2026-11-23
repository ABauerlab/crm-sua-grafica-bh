-- Aviso de novo lead (23/11/2026): o dono recebe um popup no celular (PWA) sempre que um contato NOVO escreve pela primeira vez
-- no WhatsApp da gráfica. Usa a fila de alertas que já existe (alerta_criar -> alertas-enviar -> Web Push), sem canal novo.
-- Aditiva e idempotente. Reverter: drop trigger messages_notifica_novo_lead on public.messages; drop function private.trg_novo_lead();
--
-- Regras:
-- * Dispara na PRIMEIRA mensagem recebida da conversa (uma conversa por contato), nunca mais para o mesmo contato.
-- * Gravidade alta (sai na hora, não vai para o resumo de 2 h). Só popup por padrão; WhatsApp do dono desligado.
-- * Respeita o horário de silêncio (22h às 7h): o aviso da madrugada não acorda ninguém e fica no resumo da manhã.
-- * Não avisa quando quem escreve é o próprio número do dono; contato de teste (is_teste) é gravado mas não entregue
--   (regra já embutida em alerta_criar).
-- * Nunca quebra a gravação da mensagem: qualquer erro vira warning.

-- 1) categoria própria (preferências em Configurações > Notificações); resto igual à versão anterior
create or replace function private.alerta_categoria(p_tipo text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_tipo = 'pedido_pago' then 'pedido_pago'
    when p_tipo = 'novo_lead' then 'novo_lead'
    when p_tipo = 'nova_mensagem_humano' then 'nova_mensagem_humano'
    when p_tipo = 'pagamento_pendente_demora' then 'pagamento_pendente'
    when p_tipo = 'pedido_sem_arte' then 'pedido_sem_arte'
    when p_tipo like 'padrao_desconto%' then 'politica_desconto'
    when p_tipo = 'resumo' then 'resumo'
    when p_tipo = 'pagamento_problema' then 'pagamento_problema'
    when p_tipo = 'erro_workflow' then 'erro_sistema'
    when p_tipo = 'pedido_fora_das_regras' then 'pedido_regras'
    when p_tipo = 'orcamento_valor_alto' then 'orcamento_valor_alto'
    else 'atencao_agente' end;
$$;

-- 2) preferência padrão (não sobrescreve o que o dono já tiver salvo)
update public.app_settings
   set value = jsonb_set(value, '{tipos}',
         jsonb_build_object('novo_lead', jsonb_build_object('push', true, 'whatsapp', false, 'fura_silencio', false)) || coalesce(value -> 'tipos', '{}'::jsonb))
 where key = 'notificacoes';

-- 3) gatilho: primeira mensagem recebida da conversa
create or replace function private.trg_novo_lead() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_ct uuid; v_wa text; v_dono text; v_previa text;
begin
  if new.direction <> 'in' then return new; end if;
  begin
    -- já houve outra mensagem recebida nesta conversa: não é lead novo
    if exists (select 1 from public.messages where conversation_id = new.conversation_id and direction = 'in' and id <> new.id) then return new; end if;
    select cv.contact_id, c.wa_id into v_ct, v_wa
      from public.conversations cv join public.contacts c on c.id = cv.contact_id
     where cv.id = new.conversation_id;
    if v_ct is null then return new; end if;
    select whatsapp_dono into v_dono from public.agente_config where id = 1;
    if v_wa is not distinct from v_dono then return new; end if;   -- o próprio dono falando com o número comercial
    v_previa := case when new.type = 'text' then left(regexp_replace(coalesce(new.body, ''), '\s+', ' ', 'g'), 80) else null end;
    perform public.alerta_criar('novo_lead', 'alta', v_ct, new.conversation_id, null,
      'Novo lead entrou em contato.', jsonb_build_object('previa', coalesce(v_previa, '')),
      'novo_lead:' || new.conversation_id::text);
  exception when others then
    raise warning 'alerta de novo lead não criado: %', sqlerrm;
  end;
  return new;
end;
$$;
revoke execute on function private.trg_novo_lead() from public, anon, authenticated;
drop trigger if exists messages_notifica_novo_lead on public.messages;
create trigger messages_notifica_novo_lead after insert on public.messages for each row execute function private.trg_novo_lead();
