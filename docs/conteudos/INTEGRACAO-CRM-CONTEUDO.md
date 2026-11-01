# Integração conceitual | Conteúdo ↔ CRM

## Objetivo

Conectar futuramente os esforços de conteúdo e marketing aos resultados comerciais acompanhados no CRM, preservando a separação de responsabilidades.

## Sistemas e responsabilidades

### Repositório de conteúdo

Responsável por estratégia, pauta, roteiro, referências, arquivos de produção, links de publicação e métricas de conteúdo.

### CRM

Responsável por contatos, conversas, consentimento, oportunidades, orçamentos, pedidos, pagamentos e dados comerciais autorizados.

## Casos de uso possíveis

1. Registrar no CRM a origem de um contato que veio de um conteúdo ou campanha.
2. Medir quantos contatos, orçamentos e pedidos foram associados a uma publicação ou campanha.
3. Identificar quais temas e formatos geram contatos qualificados, não apenas alcance.
4. Criar uma visão consolidada de conteúdo → contato → orçamento → pedido, quando houver dados confiáveis.

## Modelo conceitual mínimo (não implementado)

Um registro de publicação poderá ser identificado por:
- `content_id`: ID estável, por exemplo `SG-014`.
- `platform`: Instagram, Facebook ou Threads.
- `published_url`: URL pública da publicação.
- `published_at`: data/hora de publicação.
- `campaign_id`: identificador opcional de campanha.
- `content_format`: react, tela dividida, fundo verde, motion, voice-over etc.
- `content_theme`: tema ou linha editorial.

Um contato poderá ter um campo de origem/atribuição associado à publicação, campanha ou conjunto de conteúdos, desde que a informação esteja disponível e seja coletada de forma legítima.

## Atribuição: regras de qualidade

- Não assumir que todo contato recebido durante uma publicação veio dela.
- Preferir evidência: link rastreável, parâmetro de campanha, formulário, indicação explícita ou pergunta de origem no atendimento.
- Distinguir primeiro contato, último contato e influência assistida, se os dados permitirem.
- Permitir origem desconhecida; não preencher com suposição.
- Manter datas e plataformas para auditoria.
- Evitar atribuir venda a conteúdo sem evidência.

## Privacidade e consentimento

- Não copiar mensagens, telefones, nomes ou dados pessoais do CRM para o repositório de conteúdo.
- Não exportar conversas de clientes para análise editorial sem necessidade, base legítima e controles adequados.
- Agregar ou anonimizar métricas sempre que possível.
- Respeitar os estados de consentimento de marketing já adotados pelo CRM.
- Nunca usar a integração para contornar opt-out ou regras de comunicação da Meta.

## Arquitetura recomendada para uma fase futura

Começar com um contrato simples de dados e relatórios agregados, não com uma dependência entre os repositórios.

Possíveis caminhos a avaliar:
1. Parâmetros de campanha/UTM ou códigos por conteúdo para capturar origem.
2. Um evento controlado enviado ao CRM quando houver atribuição confirmada.
3. Uma tabela/view de atribuição somente depois de definir campos, RLS, retenção e testes.
4. Um relatório de conteúdo e resultado comercial com métricas agregadas.

Não criar tabela, coluna, endpoint, webhook ou workflow até que o caso de uso seja aprovado e as regras do CRM sejam revisadas.

## Estado atual

**DOCUMENTAÇÃO CONCEITUAL — NÃO IMPLEMENTADO.**

A existência deste documento não significa que CRM e repositório de conteúdo estejam tecnicamente sincronizados. O repositório de conteúdo continua sendo atualizado independentemente.