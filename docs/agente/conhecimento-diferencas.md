# Etapa 7C: o que a importação faz com o que já existe

Banco de produção antes da importação: 97 trechos (carga da Etapa 2, 4B e 7B). O arquivo novo (`docs/agente/conhecimento_v2.json`, mantido como veio) tem 83 trechos com identificadores diferentes dos antigos. Por isso a importação usa uma tabela de equivalência (`scripts/gerar-conhecimento-v2.ts`, constante `SUBSTITUI`).

## Regras
1. **Nada é apagado nem sobrescrito.** Trecho novo entra como linha nova (`fonte = 'Etapa 7C'`).
2. **Antigo sem edição com equivalente novo** é DESATIVADO (`ativo = false`, `substituido_por = <id novo>`). Reversível: `select conhecimento_reverter_importacao_7c();` (service role) reativa os antigos e desativa os novos.
3. **Antigo que o dono editou depois da carga** (revisado e alterado mais de 1 minuto depois de criado) fica intacto e ativo; a versão nova vira linha em `conhecimento_sugestoes`, exibida em Configurações > Conhecimento > Sugestões da importação, com comparação lado a lado. Em produção, são os 4 trechos alterados em 29/10: `qual-banner` (sugestão `q_banner`) e `frete-gratis-centro` (sugestão `frete_gratis`); `frete-bike` e `frete-tamanho` não têm equivalente novo e seguem ativos.
4. **Mesmo identificador**: `bauerlab` e `urgencia` já existiam como rascunhos da 7B (`revisar = true`, nunca aprovados): foram atualizados com o texto novo.
5. **Sem equivalente novo, o antigo continua ativo** (guias de produto, kits, aberturas de ímã, tag, adesivo e banner, CNPJ, horário, endereço depois de pagar, frete de bicicleta, pedido mínimo, orçamento e validade, tom de vendedor, entre outros).
6. Perguntas frequentes (`faq_cache`) que apontavam para um antigo desativado passam a responder com o texto do novo.
7. Os vetores `gte-small` dos 83 novos são gerados pela Edge Function `conhecimento` (reindexação automática a cada 5 minutos); o índice HNSW atualiza com eles.

## Ajustes no texto do arquivo (o JSON original não foi alterado)
| Onde | O que mudou | Por quê |
|---|---|---|
| Respostas prontas com "Laura" e "João Victor" | viraram `{{persona_vendas}}` e `{{persona_pos_pagamento}}` | o nome fica em Configurações > Personas e política |
| `pv_cupom` | 5%, R$ 25 e 30 dias viraram `{{cupom_percentual}}`, `{{cupom_teto}}` e `{{cupom_validade_dias}}`; "limite de lucro" virou "limite interno" | parâmetros do dono em Configurações; a palavra "lucro" é proibida em trecho |
| `troca` | "2 dias úteis" virou `{{troca_prazo}}` | prazo da foto em Configurações; o lint não aceita prazo escrito |
| `q_banner`, `frete_gratis` (fatos) | "não vão de bicicleta" virou "podem não ser elegíveis à entrega grátis" | regra do dono: o cliente nunca vê a palavra bicicleta |
| Tags | frases que o cliente escreve foram somadas às tags (`TAGS_EXTRA`) | pedido da etapa: ajustar tags dos que falharem no teste de 40 perguntas |

Resultado de cada ajuste de texto, trecho por trecho: rode `node scripts/gerar-conhecimento-v2.ts` (a lista de ajustes aparece no código).
