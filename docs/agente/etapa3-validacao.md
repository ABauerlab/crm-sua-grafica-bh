# Etapa 3: validação (preço sob demanda, aprendizado e condição especial)

Gerado em 28/10/2026 no Postgres 16 local com as 20 migrations do projeto replicadas. Reproduzir:

```bash
supabase/tests/rodar-local.sh supabase/tests/preco_etapa3.sql      # 67 testes, desfaz tudo
psql -h /tmp -p 54329 -U postgres -d gbh -f supabase/tests/tabela-etapa3.sql   # tabelas abaixo
```

> **Leia isto antes das tabelas.** O catálogo local é **fictício** (48 linhas montadas para teste, nenhum preço real do fornecedor) e o mercado é **simulado** (X vezes o custo, com 0 a 4 fontes). As tabelas provam a fórmula, as travas e o tempo de cálculo; **não** são preços de mercado reais. A pesquisa real só existe depois de instalar a busca (`docs/agente/infra-busca.md`), aplicar as migrations e ativar o workflow. Para ver a mesma tabela com o catálogo real, rode `supabase/tests/tabela-etapa3.sql` no SQL Editor depois de aplicar (ele usa `begin` e `rollback`, não grava nada).

## 1. Testes automáticos

| Suíte | Resultado |
|---|---|
| `supabase/tests/preco_etapa3.sql` (nova) | **67 testes passam** |
| `supabase/tests/agente_etapa1.sql` (Etapa 1, contra o schema novo) | 54 passam |
| `supabase/tests/catalogo_etapa2.sql` (Etapa 2) | 82 passam |
| `supabase/tests/conhecimento_recuperacao.sql` | 40 de 40 (100%) |
| `npm test`, `npm run typecheck`, `npm run build` | verdes |

Cobertura dos 67 novos: mercado ausente, mercado com 1, 2 e 3 fontes, **mercado muito abaixo do piso**, **mercado com outlier** (descartado pelo banco), pesquisa vencida (15 dias), cache, pesquisa em andamento, sem dado recente (não repete por 30 minutos), limite de taxa e robots por domínio, âncora de vendas (2 vendas não bastam, 3 em 90 dias entram, nunca passam do mercado), fator por grupo, **kit** (nunca abaixo do piso do conjunto, nem com mercado absurdo), aprendizado (11% baixa, 67% sobe, menos de 8 não muda, limites 0,90 e 0,98, teste ignorado, log com antes e depois), condição especial (nunca antes de enviar, validade de 24 h, pedido ligado, uma por orçamento, link novo, **expiração**: preço volta ao normal, link deixa de valer, não se repete), caçador de desconto, padrão incomum (3 condições e nenhuma compra), relatório e resumo semanal, política (valores fora do limite recusados, simulação do pior caso, salvar), edição manual de preço (piso duro bloqueia, entre pisos pede confirmação e grava log, trava de banco), segurança (anon sem acesso, RLS).

### Simulação obrigatória: 1.000 combinações aleatórias

Cada rodada sorteia item do catálogo, quantidade (1 a 5), entrega (nenhuma, bike, uber, retirada), frete cobrado ou não, arte paga ou não, bairro, gatilho (G1, G2, G3) e cenário de mercado (sem mercado, muito abaixo, abaixo, igual, acima, com outlier). Calcula o preço, cria o orçamento, pede a condição e confere o orçamento atualizado.

Resultado: **1.000 orçamentos, 738 com condição oferecida (423 descontos, 308 arte grátis, 7 frete grátis), 262 sem condição, 0 violações.** Nenhum preço ficou abaixo do `piso_duro`, nenhum orçamento atualizado teve lucro líquido negativo; o menor lucro líquido depois da condição foi **R$ 60,02** e a menor folga do preço sobre o piso duro foi R$ 67,41. (Casos em que a condição geraria orçamento abaixo do piso do conjunto foram recusados pelo banco, que é o comportamento esperado.)

## 2. Preço sugerido por especificação (13 especificações, mercado simulado)

| SKU | Quantidade | Cenário de mercado | Custo | Mediana de mercado | Fontes | Preço sugerido | Piso | Piso duro | Margem líquida | Confiança | Regra | Não competitivo | Cálculo (ms) |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|---:|
| ADV01 | 100 | 2 fontes | R$ 53,25 | R$ 154,43 | 2 | R$ 143,90 | R$ 128,12 | R$ 60,72 | 51,5 % | media | mercado | não | 5.4 |
| ADV01C | 300 | sem mercado | R$ 173,25 | n/d | 0 | R$ 328,90 | R$ 262,92 | R$ 195,52 | 36,1 % | baixa | custo_x_multiplicador | não | 0.7 |
| ADV02B | 200 | mercado abaixo do piso | R$ 129,50 | R$ 155,40 | 3 | R$ 213,90 | R$ 213,78 | R$ 146,38 | 28,1 % | alta | piso | sim | 0.7 |
| BAN01 | 1 | 3 fontes consistentes | R$ 48,81 | R$ 165,95 | 3 | R$ 153,90 | R$ 123,13 | R$ 55,73 | 56,8 % | alta | mercado | não | 0.6 |
| CFV02 | 1000 | 3 fontes consistentes | R$ 75,99 | R$ 205,17 | 3 | R$ 190,90 | R$ 153,67 | R$ 86,27 | 48,8 % | alta | mercado | não | 0.5 |
| CFV02B | 2000 | 2 fontes | R$ 140,58 | R$ 344,42 | 2 | R$ 319,90 | R$ 226,22 | R$ 158,82 | 44,8 % | media | mercado | não | 0.5 |
| CFV02D | 5000 | 1 fonte | R$ 379,95 | R$ 835,89 | 1 | R$ 776,90 | R$ 569,93 | R$ 427,72 | 40,0 % | baixa | mercado | não | 0.3 |
| CFV10 | 1000 | sem mercado | R$ 73,22 | n/d | 0 | R$ 150,90 | R$ 150,56 | R$ 83,15 | 40,0 % | baixa | piso | não | 0.3 |
| CFV20 | 1000 | mercado muito abaixo do piso | R$ 106,50 | R$ 58,58 | 3 | R$ 188,90 | R$ 187,94 | R$ 120,54 | 32,2 % | alta | piso | sim | 0.2 |
| IMG01 | 100 | 1 fonte | R$ 133,13 | R$ 252,95 | 1 | R$ 234,90 | R$ 217,85 | R$ 150,45 | 32,0 % | baixa | mercado | não | 0.2 |
| PFL01 | 1000 | 3 fontes e 1 outlier | R$ 79,88 | R$ 239,64 | 3 | R$ 222,90 | R$ 158,04 | R$ 90,64 | 52,8 % | alta | mercado | não | 0.3 |
| PFL02B | 2000 | 3 fontes consistentes | R$ 259,00 | R$ 621,60 | 3 | R$ 577,90 | R$ 388,50 | R$ 291,85 | 44,1 % | alta | mercado | não | 0.2 |
| TAG01B | 1000 | 2 fontes | R$ 83,25 | R$ 178,99 | 2 | R$ 166,90 | R$ 161,82 | R$ 94,42 | 38,7 % | media | mercado | não | 0.2 |

Leitura: com 3 fontes o preço é a mediana x 0,93 terminada em ,90 e fica bem acima do piso; com 2 ou 1 fonte a confiança cai (média, baixa) mas a regra é a mesma; sem mercado vale `custo x multiplicador` com as travas (quando o resultado ficaria abaixo do piso, vale o piso, como CFV10); mercado abaixo do piso (CFV20 e ADV02B) mantém o piso, marca **não competitivo** e o agente recebe a orientação de destacar valor, não de reduzir; o outlier de PFL01 (9x o custo) foi descartado e a mediana ficou em 3 fontes. O cálculo leva menos de 1 ms (o primeiro, 5 ms, inclui o carregamento do plano).

**Tempo de resposta da pesquisa real:** não medido (depende da infraestrutura instalada). Metas e limites do desenho: até 45 s no total (`parametros_comerciais.pesquisa_timeout_s`), 5 páginas, 15 s de intervalo por domínio. Estouro ou falha devolve `sem_dado` e a fórmula usa o custo com travas; o agente não espera em silêncio (a Etapa 5 envia a mensagem curta de espera).

## 3. Escada da condição especial (exemplos)

| Exemplo | Gatilho | Preço do orçamento | Piso | Gordura | Resultado | Valor | Degrau | Lucro líquido depois |
|---|---|---:|---:|---:|---|---:|---:|---:|
| Degrau 2 (G1) em cartões | G1 | R$ 453,67 | R$ 153,67 | R$ 300,00 | desconto de R$ 18,14 | R$ 18,14 | 2 | R$ 310,92 |
| Degrau 3 (G3), teto de R$ 80 | G3 | R$ 3.153,67 | R$ 153,67 | R$ 3.000,00 | desconto de R$ 80,00 | R$ 80,00 | 3 | R$ 2.659,39 |
| Degrau 1 (G1): frete grátis sem mínimo | G1 | R$ 221,75 | R$ 181,75 | R$ 40,00 | frete grátis, sem pedido mínimo | R$ 25,00 | 1 | R$ 95,61 |
| Gordura zero (preço no piso) | G1 | R$ 153,67 | R$ 153,67 | R$ 0,00 | sem condição (sem_gordura_acima_do_piso) | - | - | - |
| Desconto calculado abaixo de R$ 5 | G1 | R$ 159,67 | R$ 153,67 | R$ 6,00 | sem condição (desconto_menor_que_o_minimo) | - | - | - |
| Degrau 2 (G2) em adesivos | G2 | R$ 278,12 | R$ 128,12 | R$ 150,00 | desconto de R$ 11,12 | R$ 11,12 | 2 | R$ 183,63 |

Gordura zero e desconto abaixo de R$ 5 não geram desconto em dinheiro (o degrau 1, quando se aplica ao pedido, pula para a vantagem sem custo; sem frete nem arte para oferecer, não há condição). O degrau 3 respeita o teto de R$ 80. Todos os valores vêm da função `calcular_condicao_especial`; o agente só recebe `{tipo, texto_curto, valor, valida_ate}`.

## 4. Custo estimado de tokens e requisições por pesquisa

| Caminho | Requisições HTTP | Tokens do modelo | Custo aproximado |
|---|---:|---:|---|
| Cache válido (14 dias) | 1 (banco) | 0 | zero |
| Pesquisa com extração por regras (caso comum) | 1 cache + 3 buscas + até 5 x (reservar domínio + leitura) + 1 registro = **até 15** | **0** | zero com SearXNG; Tavily ou Serper gastam 3 créditos de busca; Firecrawl gasta 1 crédito por página lida com JavaScript |
| Pesquisa com o modelo pequeno (último recurso, só se nenhuma regra achar preço) | as mesmas, sem requisição extra de página | cerca de 2.500 de entrada e 200 de saída (2 trechos de até 3.500 caracteres + instruções), registrados em `consultas_preco_mercado.tokens_usados` | menos de R$ 0,01 por pesquisa com um modelo flash-lite |

O modelo nunca calcula preço: ele só extrai um número que precisa aparecer literalmente no texto e passar nas mesmas regras de especificação, e o banco ainda aplica outliers, mediana e as travas de lucro.

## 5. O que NÃO foi validado (honestidade)

- **Nada foi aplicado em produção**; as migrations foram testadas só no Postgres local (sem pgvector, sem pg_cron real). Rodar `supabase/tests/preco_etapa3.sql` em produção depois de aplicar é parte do aceite.
- **Pesquisa real de mercado:** SearXNG e o leitor de JavaScript não foram instalados no servidor. O leitor foi testado localmente contra a página pública do concorrente (devolveu o texto renderizado com preços), mas o workflow foi testado no n8n só com dados simulados nos nós de rede. Cobertura esperada do concorrente prioritário é baixa (preço só das opções padrão da página).
- **Os 4 workflows precisam de credenciais** (Supabase service role e, se usar, chaves de busca) e de seleção manual nos nós HTTP; foram criados desativados.
- **PDF do orçamento atualizado:** depende do workflow de PDF da Etapa 4; o gancho está marcado no workflow `condicao_especial` e o banco já gera o orçamento atualizado e o link novo.
