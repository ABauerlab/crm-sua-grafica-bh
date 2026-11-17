-- Resposta rápida /arte: pedido de aprovação da arte (mesmo texto do template aprovacao_arte e do botão Arte do chat).
-- Aditiva e idempotente: não sobrescreve se o dono já tiver editado.
insert into public.quick_replies (shortcut, title, body)
values ('arte', 'Aprovação da arte',
  E'Oi! Sua arte está pronta e segue aqui para aprovação.\n\nConfira com calma textos, nomes, telefones, cores e tamanho.\n\nSe estiver tudo certo, responda *APROVADO*. Depois disso a arte entra em produção e não dá mais para corrigir. Se tiver qualquer ajuste, me fala agora.')
on conflict (shortcut) do nothing;
