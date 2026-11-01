-- Etapa 8: com o PWA instalado, o WhatsApp do dono recebe só o indispensável (pagamento com problema e cliente esperando humano).
-- Erros de workflow e pedidos fora das regras ganham categorias próprias (somente push).
create or replace function private.alerta_categoria(p_tipo text) returns text
language sql immutable set search_path = ''
as $$
  select case
    when p_tipo = 'pedido_pago' then 'pedido_pago'
    when p_tipo = 'nova_mensagem_humano' then 'nova_mensagem_humano'
    when p_tipo = 'pagamento_pendente_demora' then 'pagamento_pendente'
    when p_tipo = 'pedido_sem_arte' then 'pedido_sem_arte'
    when p_tipo like 'padrao_desconto%' then 'politica_desconto'
    when p_tipo = 'resumo' then 'resumo'
    when p_tipo = 'pagamento_problema' then 'pagamento_problema'
    when p_tipo = 'erro_workflow' then 'erro_sistema'
    when p_tipo = 'pedido_fora_das_regras' then 'pedido_regras'
    else 'atencao_agente' end;
$$;
update public.app_settings
set value = jsonb_set(value, '{tipos}', (value -> 'tipos') || jsonb_build_object(
  'resumo',             jsonb_build_object('push', true, 'whatsapp', false, 'fura_silencio', false),
  'pedido_pago',        jsonb_build_object('push', true, 'whatsapp', false, 'fura_silencio', true),
  'atencao_agente',     jsonb_build_object('push', true, 'whatsapp', true,  'fura_silencio', true),
  'pedido_sem_arte',    jsonb_build_object('push', true, 'whatsapp', false, 'fura_silencio', false),
  'politica_desconto',  jsonb_build_object('push', true, 'whatsapp', false, 'fura_silencio', false),
  'pagamento_pendente', jsonb_build_object('push', true, 'whatsapp', false, 'fura_silencio', false),
  'pagamento_problema', jsonb_build_object('push', true, 'whatsapp', true,  'fura_silencio', true),
  'erro_sistema',       jsonb_build_object('push', true, 'whatsapp', false, 'fura_silencio', false),
  'pedido_regras',      jsonb_build_object('push', true, 'whatsapp', false, 'fura_silencio', false)))
where key = 'notificacoes';
