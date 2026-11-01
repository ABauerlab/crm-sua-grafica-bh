# Redes sociais (Postiz e Meta): viabilidade

## O que o Postiz tem hoje (MCP, 01/11/2026)
Integrações conectadas: Facebook (Sua Gráfica BH, BauerLab, Teggly), Instagram (`suagraficabh`, `abauerlab`, `teggly`) e Threads (`suagraficabh`). O Postiz **publica e agenda** posts; as ferramentas do MCP são de agendamento, esquema por plataforma e geração de mídia. Ele **não recebe** comentários nem mensagens diretas.

## O que cada API permite (pesquisa; confirmar na documentação oficial antes de construir)
- **Instagram (Graph API):** webhooks de comentários e menções existem, mas a Meta diz que o app precisa passar pela **Análise de app (acesso avançado)** para receber os webhooks de comentários; permissões `instagram_manage_comments` e `instagram_business_manage_comments`. Com acesso padrão só vale para contas próprias, mas o webhook de comentários exige a análise ([Meta](https://developers.facebook.com/docs/graph-api/webhooks/getting-started/webhooks-for-instagram), [moderação](https://developers.facebook.com/docs/instagram-platform/comment-moderation)).
- **Mensagens diretas do Instagram:** pela API de Mensagens, com permissões próprias e janela de resposta; também pede análise. Não pesquisado a fundo.
- **Facebook Pages:** comentários e Messenger via webhooks do objeto `page`, também com permissões e análise.
- **Threads:** a API de respostas existe; webhooks não foram confirmados.

## Conclusão
**Exige aprovação da Meta**, então o `GBH | WF10 | Redes sociais` **não foi implementado** (vai para o BACKLOG, conforme a regra). Responder reclamação pública automaticamente continua proibido: chama o dono.

## Roteiro para o dono solicitar (quando quiser)
1. Em developers.facebook.com, usar um **app Meta próprio** (não o do WhatsApp) com os produtos Instagram e Páginas; callback de webhook **separado** do WhatsApp (a Meta aceita uma URL por produto; o webhook do WhatsApp não muda).
2. Pedir na Análise de app: `instagram_business_manage_comments`, `instagram_business_manage_messages`, `pages_read_engagement`, `pages_manage_engagement`, `pages_messaging`, com vídeo mostrando o caso de uso (responder comentários e DMs do próprio negócio).
3. Depois da aprovação, implementar o WF10: recebe evento, classifica (dúvida, interesse, reclamação), responde curto e natural, leva para o WhatsApp pelo link da bio (sem preço em comentário público), registra origem e campanha, usa a mesma base de conhecimento e as mesmas travas.
Enquanto isso, o conteúdo continua sendo publicado pelo Postiz.
