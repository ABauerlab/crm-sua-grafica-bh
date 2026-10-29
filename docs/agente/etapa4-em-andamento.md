# Etapa 4 em andamento: orçamento em PDF

Branch: `feat/agente-etapa4-orcamento`

## Feito nesta sessão
- Criada a migration aditiva `20261029000008_orcamentos.sql` para `orcamentos`, `orcamento_itens`, sequência SG-0001, views públicas e campos internos.
- Criado o template público `infra/renderer/orcamento-template.js`, com escape HTML e sem custo, margem, piso, fornecedor ou SKU.
- Criadas as Edge Functions `montar-orcamento`, `gerar-pdf-orcamento` e `gerar-link-pagamento`.
- Criados no MCP do n8n, na pasta `Sua Gráfica BH`, os workflows `GBH | FERRAMENTA | montar_orcamento`, `GBH | FERRAMENTA | gerar_pdf_orcamento`, `GBH | FERRAMENTA | gerar_link_pagamento` e `GBH | WF3 | Orçamento PDF`, todos desativados.

## Ainda falta
- Aplicar a migration no Supabase e verificar RLS/policies no projeto real.
- Configurar os segredos `SUPABASE_SERVICE_ROLE_KEY`, `RENDERER_URL`, `RENDERER_TOKEN`, `PAGAMENTO_PROVIDER_URL` e `PAGAMENTO_PROVIDER_TOKEN` somente nos ambientes apropriados.
- Configurar as credenciais HTTP dos quatro workflows no n8n. Elas não foram autoatribuídas.
- Conferir e reaproveitar a tela existente do CRM para a aba Orçamentos.
- Integrar o renderer real ao endpoint `/orcamento/pdf` e validar Gotenberg, Storage e download.
- Gerar os seis PDFs de exemplo, revisar em celular e papel e adicionar os arquivos em `docs/exemplos-orcamento/`.
- Atualizar `docs/n8n-mapa.md` e `docs/agente/progresso.md` no fechamento da etapa.

## Passagem de bastão
A etapa ainda não está pronta para merge. Não ativar workflows nem divulgar links até aplicar a migration, configurar os segredos e executar os testes de integração.
