# Etapa 4 em andamento: orçamento em PDF

Branch: `feat/agente-etapa4-orcamento`

## Feito nesta sessão
- Criada a migration aditiva `20261029000008_orcamentos.sql` para `orcamentos`, `orcamento_itens`, sequência SG-0001, views públicas e campos internos protegidos por convenção.
- Criado o template público `infra/renderer/orcamento-template.js`, com escape HTML, layout responsivo e sem custo, margem, piso, fornecedor ou SKU.

## Ainda falta
- Conferir e reaproveitar a tela existente do CRM para a aba Orçamentos.
- Implementar e validar `montar_orcamento` usando as funções determinísticas das Etapas 1 a 3.
- Criar pelo MCP do n8n os workflows `GBH | FERRAMENTA | montar_orcamento`, `GBH | WF3 | Orçamento PDF`, `GBH | FERRAMENTA | gerar_pdf_orcamento` e `GBH | FERRAMENTA | gerar_link_pagamento`, todos desativados.
- Integrar o renderer ao Gotenberg existente e o PDF ao Supabase Storage e WhatsApp.
- Gerar os seis PDFs de exemplo, revisar em celular e papel e adicionar os arquivos em `docs/exemplos-orcamento/`.
- Atualizar `docs/n8n-mapa.md` e `docs/agente/progresso.md` no fechamento da etapa.

## Bloqueios ou dependências
- O brandkit local informado no briefing não está disponível no repositório nem anexado nesta sessão, então o template usa somente tokens provisórios e não deve ser considerado identidade visual final.
- A confirmação do contato de WhatsApp, Instagram e site da empresa ainda é necessária para fechar o rodapé do PDF.
- Esta sessão para aqui, conforme a regra de não avançar além da Etapa 4.
