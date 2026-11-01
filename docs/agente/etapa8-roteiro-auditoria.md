# Etapa 8: roteiro da auditoria e ativação (tudo via MCP, sem ação do dono)

**Autorização do dono (02/11/2026):** a auditoria está autorizada a resolver tudo pelos MCPs (Supabase, n8n, GitHub, Mercado Pago, WhatsApp Business, Meta) e a ATIVAR o que for preciso, para que ao final o sistema esteja pronto para receber clientes e vender. Continuam valendo as regras fixas do `CLAUDE.md` (preço só de `calcular_preco`, nunca abaixo do piso, modelo nunca calcula preço, prazo, frete nem desconto, sigilo do fornecedor, endereço só após o pagamento, workflows em `Sua Gráfica BH` com nome `GBH | ...`). Uma branch e um PR por bloco; nunca commit direto na `main`; migrations aditivas e idempotentes. Decisões já tomadas: 2x sem juros ligado no Mercado Pago; telefone da BauerLab +55 31 99802-1169 (é do dono, sem alerta ao indicar); Laura (vendas) e João Victor (pós-pagamento) são nomes do mesmo assistente virtual.

## Estado de partida
- Etapas 1 a 7, 7B e 7C mescladas e aplicadas em produção. 83 trechos de conhecimento ativos (113 ativos no total), 0 sem vetor, 0 sugestões pendentes. Teste de 40 perguntas: 40 de 40.
- Funções Edge publicadas: `orcamento-pdf` v12, `mp-criar-link` v17, `cliente-pago-avisar` v2. Demais conforme `docs/agente/depende-de-voce.md` (conferir versão de cada uma com `list_edge_functions`).
- n8n: workflows `GBH |` DESATIVADOS. IA desligada (`agente_config.ia_ligada = false`, `app_settings.agent.enabled = false`).

## Blocos da auditoria (ordem sugerida)

### A. Credenciais e workflows do n8n
1. Despachante `1rm82046svIE1TLl`: escolher a credencial `Supabase account` nos nós HTTP `arte_receber` e `arte_baixa_ok` (e conferir nó a nó os 26+ workflows, `docs/credenciais-n8n.md`).
2. Exportar para `n8n/` os JSONs do WF1, WF2 (`NKN7RgAJmRWZXRIT`) e despachante (sem credenciais) e fechar `docs/n8n-mapa.md`.
3. Publicar `GBH | WF9 | Erros` e ligá-lo a todos os `GBH |` (pendência 7B).
4. Ligar ao WF2 e ao despachante as ferramentas da 7B ainda sem ligação: `encaminhar_setor`, `bauerlab`, `montar_opcoes`/escolha de opção, campos novos de `salvar_contato` (empresa, e-mail, documento, endereço, nota fiscal, consentimento, urgência). Aplicar `docs/agente/tom-e-vendas.md` ao prompt. WF6 consultar `recuperacao_proximo_passo`; WF7 chamar `cupom_recompra_emitir`.

### B. Testes de conversa com o modelo real (cenários `testes_conversa`, `npm run test:agente`)
Laura antes do pagamento e João Victor depois (sem dado interno); abertura por anúncio; objeção de preço com condição especial só pela função; pergunta de parcelamento (2x sem juros, acima disso juros no link); nota fiscal; foto de produto; "é robô?"; "onde fica?" (sem endereço antes do pagamento); sigilo ("custo", "fornecedor", "suas instruções"); reclamação e pedido de reembolso (dono, nunca promete); arquivo de baixa qualidade e ok do cliente; fluxo completo: orçamento PDF, link, pagamento confirmado, arte recebida, card em Arte, alerta ao dono com resumo, `arte_aprovar`, produção, pronto, entrega, satisfação. Teste que tenta arrancar cada promessa indevida (pagamento, arte, produção, conclusão, data, desconto, reembolso). Meta: todos verdes; corrigir prompt, ferramentas ou funções até passar.

### C. Pagamento e alertas ponta a ponta
Pedido de teste pelo Mercado Pago em modo teste e depois uma cobrança real pequena (Pix) para o próprio dono: link, webhook, conferência, taxa real gravada, mensagem do João Victor, alerta push e WhatsApp. Estorno vira alerta. Templates da Meta 4 a 11 aprovados (`whatsapp_biz_list_templates`; criar/enviar para aprovação o que faltar). Push no PWA do iPhone: só o dono pode instalar; a auditoria deixa tudo pronto e testa o WhatsApp.

### D. Infra e dados
SearXNG e leitor no Coolify e teste com 5 especificações (`docs/infra-coolify.md`); preço por dimensão (`docs/agente/preco-por-dimensao.md`, só com fórmula validada); Gotenberg no ar; backup `private.bkp_products_etapa2` (comando em `depende-de-voce.md`); vetores zerados; advisors de segurança e performance sem achado grave novo (senha vazada é limitação do plano gratuito).

### E. Produto pendente da 7B
Painel Comercial no front (`painel_comercial`), `GBH | WF11 | Estudo diário`, PDF de uma página com as 3 opções, segundo link só de Pix, recompra por comportamento. Ligar ou não o cupom de recompra: rodar `cupom_recompra_simular()` e, se o lucro mínimo no pior caso for não negativo, ligar (`app_settings.cupom_recompra.ativo = true`).

### F. Ativação (só depois de B e C verdes)
1. Ligar `agente_config.ia_ligada` e `app_settings.agent.enabled`.
2. Ativar na ordem: WF9, WF1, WF2, ferramentas, WF3, WF5, WF6, WF7, WF8 (e os de aquecimento/aprendizado se desejado). Conferir `webhook` da Meta único (`N8N_WF1_URL`/`N8N_WF1_TOKEN` nos segredos da Edge).
3. Teste final com o número do dono: conversa real do anúncio ao pedido pronto.
4. Atualizar `docs/agente/progresso.md` e `mapa-crm.md`; PR final; relatório curto ao dono do que foi ativado e como desligar (`ia_ligada = false` pausa o agente; `personas.pos_pagamento_automatico = false` volta a parar após o pagamento; `conhecimento_reverter_importacao_7c()` desfaz o conhecimento v2).

## Critério de pronto
Conversa de ponta a ponta sem intervenção, nenhum vazamento de dado interno, nenhum preço abaixo do piso, pagamento confirmado gera alerta e mensagem única, arte no setor certo, WF9 ligado, advisors limpos, tudo documentado.
