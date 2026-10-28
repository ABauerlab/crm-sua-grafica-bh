# Progresso do agente de IA

## Etapas concluídas

- Etapa 1: Fundação (PR mesclado, aplicada em produção).
- Etapa 2: ver abaixo (**em revisão**; falta o PDF do fornecedor e aplicar as migrations).

## Etapa 2: Catálogo com SKU e banco de conhecimento (em revisão, 28/10/2026)

Branch da sessão `claude/optimistic-pasteur-9elhra` (pedida: `feat/agente-etapa2-catalogo-conhecimento`).

### O que foi feito
- Passo 0: o CRM já tinha upload do catálogo. Mapeei (tela, parser, tabela, colunas, preço) em `docs/agente/mapa-crm.md` e `docs/catalogo-e-sku.md`, listei as 11 lacunas e corrigi **na mesma tela**, mantendo as 20.381 linhas.
- Migrations 15 a 19 (aditivas, idempotentes): `products` virou `catalogo` com os campos finais, `catalogo_historico`, importação em duas fases (`catalogo_importacoes`, `catalogo_import_linhas`), bucket privado `catalogo-fornecedor`, SKU obrigatório (chaves estrangeiras `NOT VALID`, Produção bloqueada sem SKU, `itens_fora_catalogo`), `sinonimos`, `buscar_produto`, `agente_preco`, `kit_preco`, `pedido_para_fabrica`, banco de conhecimento v2 (`conhecimento`, `conhecimento_lacunas`, `conhecimento_consultas`, `faq_cache`), 90 trechos.
- Edge Function `conhecimento` (vetores `gte-small`, reindexação automática, busca para o n8n).
- Front: leitor de PDF, importação com pré-visualização e relatório, aba Sem código, SKU em destaque com copiar (catálogo, pedido, kanban, kit), aba "Pedido para a fábrica", Configurações > Conhecimento.
- Testes: `supabase/tests/catalogo_etapa2.sql` (**82 passam**), `agente_etapa1.sql` contra o schema novo (**54 passam**), recuperação (**37/40 = 92,5%**, só texto), `npm test` e `npm run typecheck` verdes.
- Documentos: `docs/catalogo-e-sku.md`, `docs/conhecimento.md`, `docs/agente/relatorio-importacao.md`, `docs/agente/relatorio-recuperacao.md`, `docs/agente/depende-de-voce.md`.

### Decisões
Ver `docs/agente/depende-de-voce.md` (renomear em vez de criar tabela nova; Pago nunca bloqueado; desativar em vez de apagar; limiares).

### O que NÃO foi feito (honestidade)
- **O PDF não foi anexado**, então a importação real e o relatório de linhas sem código **não existem ainda**.
- **Nada foi aplicado em produção.** Só consultei o banco de produção em modo leitura.
- A busca **vetorial** não foi medida (sem pgvector local); só a textual.
- Leiaute do PDF testado só com PDF fictício.
- Não rodei os advisors de segurança (dependem de aplicar).

### Pendências
Ver "O que depende de você". Resumo: PDF, aplicar migrations, deploy da função `conhecimento`, reindexar, advisors, códigos das linhas sem SKU, [CONFIRMAR] dos trechos.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/catalogo_etapa2.sql supabase/tests/conhecimento_recuperacao.sql supabase/tests/agente_etapa1.sql   # Postgres local descartável
```
No CRM (depois de aplicar): Catálogo e Kits > Importar tabela > Pré-visualizar; Pedido pago > aba Pedido para a fábrica; Configurações > Conhecimento.

## Etapa 1: Fundação (em revisão, 28/10/2026)

Branch `feat/agente-etapa1-fundacao`.

### O que foi feito
- Passo 0: mapa do CRM, do Supabase e do n8n em `docs/agente/mapa-crm.md` (conflitos e resoluções incluídos).
- Migrations 11 a 14 (aditivas e idempotentes): parâmetros comerciais, política de desconto, zonas de frete, configuração do agente, orçamentos, condições especiais, mercado, conhecimento (pgvector), follow-ups, alertas, testes de conversa, campos novos, endurecimento do `anon`.
- Funções `calcular_preco`, `calcular_prazo`, `verificar_frete`, `validar_margem`, `calcular_condicao_especial` e as travas de lucro no banco. Documentadas em `docs/agente-ia.md`.
- 54 testes SQL (`supabase/tests/agente_etapa1.sql`), executados em Postgres 16 local com as 14 migrations do projeto replicadas. `npm test` e `npm run typecheck` passam.
- 11 templates enviados à Meta (todos em análise), `docs/templates-whatsapp.md` e o painel de status em Configurações > WhatsApp e templates.

### Decisões
- Nomes que já existiam no CRM foram mantidos (`holidays`, `agent_logs`, `needs_human`, `summary`, `collected_data`); a tabela de mapeamento está no mapa.
- SKU = `products.code` por enquanto. A exigência de SKU em `order_items` fica desligada (`exigir_sku_pedidos`) até a Etapa 2 mudar a tela.
- Uma condição especial por orçamento (`max_condicoes_por_orcamento = 1`): se o F3 oferecer, o F4 não escala para o degrau 3. Para permitir a escalada, subir o parâmetro para 2.
- Zonas inativas (`ativo = false`) ficam cadastradas e não valem; só as 11 do dono e a faixa de CEP 30110-000 a 30199-999 valem.
- Taxa padrão do pedido passou de 1,5% para 4,98% (cartão de crédito) até o método real ser conhecido.

### Aplicação em produção (28/10/2026)
- Migrations 11 a 14 aplicadas no Supabase pelo SQL Editor (arquivo `docs/agente/aplicar-etapa1.sql`). Conferido: 15 tabelas, 5 funções, 6 triggers, 25 zonas (12 ativas), 11 regras de follow-up, 32 feriados, `anon` sem acesso a `products`.
- `supabase/tests/agente_etapa1.sql` rodado em produção: **54 testes passaram** (o bloco desfaz tudo, nada ficou gravado).
- Advisors de segurança: nenhum alerta novo. Os 2 que aparecem já existiam: `confirmar_pagamento_manual` executável pelo usuário logado (é o botão do dono, intencional) e proteção contra senhas vazadas desligada no Auth (ligar em Authentication > Policies).
- Observação: o histórico `supabase_migrations` de produção não registra estas 4 migrations (foram aplicadas pelo SQL Editor). Um futuro `supabase db push` as tentaria reaplicar; são idempotentes, então é seguro.

### Pendências
- Aprovação dos templates pela Meta.
- Ligar `exigir_sku_pedidos` e rotular o preço sugerido do catálogo na Etapa 2/3.
- Taxa real por método no lucro do pedido (Etapa 6).
- Ligar a proteção contra senhas vazadas no Auth.

### O que o dono deve revisar
1. **Feriados**: nacionais e de BH de 2026 e 2027 (tabela `feriados`, tela Prazos e feriados). Incluí 12/12 (aniversário de BH) para conferir; cai em fim de semana nos dois anos.
2. **Zonas de frete grátis**: lista abaixo. 11 bairros ativos e 13 candidatos inativos.
3. **`cabe_na_bike`**: 3.000 g e 600 mm. O peso do catálogo é o do pacote inteiro (soma de quantidades) e o lado é a maior medida de `size`. Banner de 1200 x 600 não cabe. Peso e tamanho vêm da planilha do fornecedor; itens sem medida entram como "dimensão desconhecida" e não ganham frete grátis.
4. **Parâmetros** marcados em `parametros_comerciais.campos_revisar`: validade do orçamento (7 dias), custo de WhatsApp (R$ 0,50) e de IA (R$ 0,30) por conversa, custo da bike (R$ 8,00) e do Uber (R$ 25,00), saídas de bike (2), pedido mínimo (R$ 150), tetos de tokens (40 mil por conversa, 1,5 milhão por dia), detector de caçador de desconto (4 orçamentos em 60 dias sem compra).
5. **Escada de desconto**: degrau 1 vantagem (frete grátis sem mínimo, senão arte grátis), degrau 2 até 4% (G1/G2), degrau 3 até 8% (G3), 60% da gordura, teto R$ 80, mínimo R$ 5, 24 h, 30 dias por contato.

### Zonas de frete grátis cadastradas

Ativas (carga inicial do dono): Centro, Santa Efigênia, Barro Preto, Lourdes, Funcionários, Savassi, Santo Agostinho, Floresta, Santa Tereza, Sagrada Família, Serra. Faixa de CEP ativa: 30110-000 a 30199-999 (aproximada).
Candidatas, inativas até confirmar: Santo Antônio, São Pedro, Sion, Carmo, Cruzeiro, Anchieta, Gutierrez, Lagoinha, Boa Viagem, Horto, Prado, Coração de Jesus, Santa Lúcia.

### Como testar
```bash
npm test && npm run typecheck
psql "$DATABASE_URL" -f supabase/tests/agente_etapa1.sql   # desfaz tudo; sucesso aparece como "OK: 54 testes passaram"
```
No CRM: Configurações > WhatsApp e templates mostra os 11 templates do agente e o status (clique em Sincronizar).
