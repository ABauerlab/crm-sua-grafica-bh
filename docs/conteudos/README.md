# Central de Conteúdo | SUA GRÁFICA BH

Esta pasta documenta a integração entre o CRM operacional da SUA GRÁFICA BH e o repositório especializado de conteúdo.

## Fonte oficial dos conteúdos

O acervo completo de estratégia editorial, tendências, roteiros, referências, padrões de edição e análise de desempenho permanece no repositório dedicado:

**[ABauerlab/conteudosuagraficabh](https://github.com/ABauerlab/conteudosuagraficabh)**

Esse repositório é a fonte única de verdade para diretrizes editoriais, pesquisa de tendências e vídeos originais, banco de ganchos, matriz de aquisição, roteiros individuais, calendário, briefings, referências audiovisuais, status de direitos, métricas e aprendizados.

## Relação com o CRM

O CRM é o sistema operacional de atendimento, relacionamento e vendas. Ele pode receber futuramente dados de campanhas e conteúdo para ajudar a entender a origem de contatos, oportunidades, pedidos e resultados comerciais.

A integração deve ocorrer por contratos e interfaces explícitas, sem duplicar o acervo editorial dentro do aplicativo.

## Limites desta integração documental

Esta pasta é somente documentação. Não cria conexão técnica, sincronização de arquivos, tabelas, automações, telas ou funções.

Nenhuma alteração no banco de dados, Supabase, Edge Functions, n8n, front-end ou deploy faz parte desta integração.

## Diretriz de evolução

Antes de implementar uma integração técnica: definir o caso de uso e o fluxo de dados; identificar a fonte oficial de cada dado; definir IDs e campos compartilhados; avaliar consentimento, privacidade e atribuição; propor arquitetura e testes; implementar em branch separada, por PR, seguindo as regras de AGENTS.md.

## Documentação

- [Modelo conceitual de integração](INTEGRACAO-CRM-CONTEUDO.md)
- [Repositório especializado de conteúdo](https://github.com/ABauerlab/conteudosuagraficabh)