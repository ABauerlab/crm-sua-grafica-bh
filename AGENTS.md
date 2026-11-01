# Regras do agente

Antes de qualquer tarefa, leia `docs/agente/00-contexto.md`, `docs/agente/progresso.md` e `docs/agente/mapa-crm.md`.

## Regras fixas
- O preço que vale é o de `calcular_preco`, com pesquisa de mercado mais trava de lucro.
- Nunca vender abaixo do piso nem com prejuízo.
- O modelo de IA nunca calcula preço, prazo, frete nem desconto.
- Segredos nunca ficam no repositório, no front nem em logs.
- A tabela e o custo do fornecedor nunca vão ao repositório nem ficam visíveis ao cliente.
- O SKU do fornecedor é interno.
- O endereço de retirada só é informado depois do pagamento.
- Workflows do n8n sempre são criados pelo MCP do n8n, na pasta `Sua Gráfica BH`, com nome `GBH | ...`, e ficam DESATIVADOS até a Etapa 8.

## Fluxo de trabalho
- Uma branch e um PR por etapa. Nunca faça commit direto na `main`, porque cada merge publica o CRM em produção.
- Migrations devem ser aditivas e idempotentes.
- Rode os testes antes do PR.
- Ao terminar, atualize `docs/agente/progresso.md` e `docs/agente/mapa-crm.md`.
- Depois pare sem avançar para a próxima etapa.

## Passagem de bastão
Se a sessão acabar no meio de uma etapa, registre em `docs/agente/progresso.md`, na seção `Em andamento`, o que foi feito, o que falta, a branch e os arquivos tocados, e faça commit na branch.

## Decisões do dono (Etapa 7B, resumo; completo em `docs/agente/decisoes-e-melhorias.md`)
- Pix sempre primeiro (qualquer banco). 2x sem juros só se o cliente perguntar ou hesitar; acima de 2x só por decisão do dono, com juros avisados antes.
- Taxa embutida no preço: o piso usa a pior taxa possível (cartão em 2x) enquanto o método é desconhecido; depois do pagamento vale a taxa REAL do Mercado Pago.
- Pedido manual exige método de pagamento escolhido; dinheiro e transferência sem taxa.
- Prazo oficial nunca muda e conta da aprovação da arte. Atrasado = em produção e fora do prazo útil. Urgência só ordena a fila.
- Pedido pago nunca é apagado (cancelar ou arquivar); exclusão lógica com motivo e auditoria.
- Avaliação no Google sem qualquer benefício em troca. Marketing só para quem consentiu.
- BauerLab (site, marca, anúncios): apresentar uma vez e passar o contato de João Victor.
- Tom humano de vendedor, sem travessão, emoji com moderação; reclamação chama o dono.


## Central de conteúdo
- A estratégia, roteiros, referências e produção de vídeos ficam no repositório especializado: https://github.com/ABauerlab/conteudosuagraficabh.
- Documentação da relação com o CRM: `docs/conteudos/README.md`.
- Não duplicar o acervo editorial dentro deste CRM.
- Não alterar o app, banco, migrations, Edge Functions ou workflows para integrar conteúdo sem escopo aprovado, branch e PR próprios.
- Não copiar dados pessoais de contatos/conversas para o repositório de conteúdo. Usar dados agregados e atribuição baseada em evidência.
