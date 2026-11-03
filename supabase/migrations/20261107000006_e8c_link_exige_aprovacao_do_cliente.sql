-- Etapa 8C: o link de pagamento só sai depois que o CLIENTE aprova DEPOIS de receber o PDF formal. Antes o banco só exigia que o PDF
-- tivesse sido enviado; o agente podia gerar o PDF e o link na mesma resposta (testes e2e mostraram isso). Agora precisa existir uma
-- mensagem de entrada do cliente posterior ao PDF com aprovação (APROVADO, pode fechar, vai ser Pix, manda o link, sim, ok...).
-- Idempotente: aplica o patch uma vez sobre a definição atual.
do $m$
declare d text;
begin
  select pg_get_functiondef('public.preparar_link_pagamento(uuid)'::regprocedure) into d;
  if d like '%aprovacao_do_cliente_pendente%' then return; end if;
  d := replace(d, 'v_val := public.validar_margem(p_orcamento);',
    $b$if not exists (
    select 1 from public.messages m join public.conversations cv on cv.id = m.conversation_id
     where cv.contact_id = o.contact_id and m.direction = 'in' and m.created_at > o.pdf_enviado_em
       and coalesce(m.body, '') ~* '(aprov|pode fechar|\mfecha|fechado|fechou|pode mandar|manda o link|me manda|envia o link|quero pagar|vou pagar|vai ser (pix|cart)|\mpix\M|cart[aã]o|certo|isso mesmo|tudo certo|beleza|combinado|\mok\M|\msim\M|pode ser|vamos)'
       and coalesce(m.body, '') !~* 'n[ãa]o (aprov|quero|vou|fech)'
  ) then
    return jsonb_build_object('ok', false, 'motivo', 'aprovacao_do_cliente_pendente', 'alternativa', 'Peça que o cliente responda APROVADO e só então gere o link.');
  end if;
  v_val := public.validar_margem(p_orcamento);$b$);
  execute d;
end
$m$;
