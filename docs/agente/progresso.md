# Progresso do agente de IA

## Etapas concluídas

- Etapa 1: Fundação (PR mesclado, aplicada em produção).
- Etapa 2: **concluída** (PR #22 mesclado, aplicada em produção em 28/10/2026).
- Etapa 3: **concluída** (PR #24 mesclado, aplicada em produção em 28/10/2026).
- Etapa 4: **concluída** (aplicada em produção em 29/10/2026: banco, `orcamento-pdf` publicada, Gotenberg no ar; PDF de teste gerado e aprovado; o envio no WhatsApp ainda não foi testado com cliente real).

## Etapa 4: orçamento em PDF (concluída, aplicada em produção em 29/10/2026)

Branch `feat/agente-etapa4-orcamento`. Aplicado: migrations `…09` e `…10`, função `orcamento-pdf` (pelo painel, com o arquivo `docs/agente/funcoes/orcamento-pdf.bundle.ts`) e Gotenberg em `gotenberg.bauerlab.com.br`. Nenhum workflow do n8n foi ativado. Ajustes pedidos pelo dono no teste: página mais bem preenchida (passos "Como fechar seu pedido") e nome do arquivo `Orcamento-SG-0032-29-10-2026.pdf`. Detalhes em `docs/orcamento-pdf.md`.

### O que foi feito
- **Passo 0:** o CRM já tinha `orcamentos` e `orcamento_itens` (Etapa 1) e nenhum gerador de PDF de orçamento (só leitura de PDF do catálogo). Estendi as tabelas e unifiquei tudo no padrão novo. O trabalho da sessão interrompida nessa branch (migration com número repetido, funções sem autenticação que aceitavam piso e custo do chamador, provedor de pagamento genérico) foi **substituído**: removi os arquivos e arquivei no n8n os 4 workflows antigos.
- **Banco** (migration `20261029000009_etapa4_orcamento_pdf.sql`, aditiva e idempotente): `montar_orcamento` (preço, prazo, frete, arte, upsell por regra, `validar_margem`), `orcamento_documento` (só dados públicos + hash), `orcamento_renovar`, `preparar_link_pagamento`, `orcamento_registrar_link`, `validar_antes_de_cobrar` olhando a margem do orçamento, bucket privado `orcamentos`, colunas novas e tempo real em `orcamentos`.
- **Taxa do método e lucro real:** `validar_margem` já descontava a taxa do método previsto (Pix 0,99%, cartão 4,98%); agora, quando o pagamento chega, `confirmar_pagamento` grava a taxa real e o lucro líquido real no pedido (`taxa_pagamento_real_pct`, `lucro_liquido_real`) e passa o orçamento para `pago`.
- **PDF:** modelo HTML em `supabase/functions/_shared/orcamento-html.ts` (logo, paleta e Inter do CRM); Edge Function `orcamento-pdf` (Gotenberg, Storage, envio no WhatsApp, idempotente, vencido gera novo, trava de lucro antes de enviar). Infra em `infra/gotenberg/`.
- **n8n (MCP, desativados, tag gbh, exportados em `n8n/`):** `montar_orcamento`, `gerar_pdf_orcamento`, `gerar_link_pagamento`, `GBH | WF3 | Orçamento PDF`; o gancho de PDF de `condicao_especial` virou chamada real.
- **CRM:** Pedido > aba Orçamentos (número, status, valor, validade, margem, regra e confiança só do dono, abrir PDF, Enviar/Reenviar) e status do orçamento no cartão do kanban.
- **Exemplos:** 6 PDFs em `docs/exemplos-orcamento/` (catálogo fictício). Conferidos em tamanho de papel (A4) e de celular (390 px) e por texto: nenhum tem SKU, custo, margem, piso, fornecedor nem endereço de retirada; todos com 1 página e menos de 200 KB.
- **Testes:** `supabase/tests/orcamento_etapa4.sql` (**49 passam**), Etapas 1, 2 e 3 contra o schema novo (54, 82 e 67 passam), `npm test` (inclui `scripts/test-orcamento.ts`), typecheck e build verdes.

### Correção pós-aplicação (29/10/2026)
O banco de produção já tinha colunas da migration antiga da sessão interrompida (`orcamentos.avisos` e `orcamento_itens.especificacao` como `jsonb`), então `montar_orcamento` falhou com 42804. A migration `20261029000010_etapa4_compat_banco.sql` define o formato final (`avisos` jsonb, `especificacao` text), remove duas views sobras dessa tentativa e recria `montar_orcamento`. Testado em banco limpo e em banco com a migration antiga aplicada antes (49 + 67 + 54 + 82 passam). O erro foi reproduzido sem a correção.

### Correção 2 (29/10/2026, achada no teste de envio)
Nas Edge Functions a service role não alcança o schema `private`: `validar_margem` direto e a troca de status para `enviado` (trigger de lucro) falhavam com `permission denied for schema private`, e a função respondia "recusado pela trava de lucro" sem motivo. A migration `20261029000011` cria `orcamento_validar_margem` e `orcamento_marcar_enviado` (definer, só dono ou servidor) e a função passou a usá-los. Os testes locais rodam como administrador e não pegavam isso; agora há testes com `set role service_role` (51 passam). Lição: testar com o papel `service_role` sempre que uma Edge Function ou o n8n chamar uma função do banco.

### Regra do dono: entrega sem "bicicleta" (29/10/2026)
Para o cliente, a entrega grátis na região central é só "entrega grátis na região central, em horário comercial". A migration `20261029000012` troca os textos do orçamento e da ferramenta de frete, o código interno `bike_gratis` (o agente recebe `entrega_gratis`) e 4 trechos do conhecimento; o PDF e o seed foram ajustados e há testes que impedem a palavra. **Para a Etapa 5:** o prompt e os filtros do agente não podem citar bicicleta nem bike (`verificar_frete` ainda devolve campos internos como `cabe_na_bike` e `entrega_sugerida: bike`; o wrapper da ferramenta deve filtrar).

### Decisões
- O PDF é renderizado dentro da Edge Function (não no n8n) para o botão Reenviar do CRM funcionar sem o n8n e para o modelo ficar versionado e testado no repositório. O WF3 orquestra.
- O pedido (que o Mercado Pago cobra) nasce do orçamento na hora do link; arte entra como item "Criação de arte" (fora do catálogo, custo zero) e desconto vira `discount_pct` arredondado para baixo. Se um pedido já existente tiver valor diferente do orçamento, o link é recusado.
- Frete por Uber é por conta do cliente: não entra no total nem vira custo nosso. Entrega de bicicleta (grátis) entra como custo nosso no lucro.
- Texto livre nunca vira item: só SKU e quantidade. SKU e custo nunca saem para o agente.
- Os erros de preço (mercado abaixo do piso, `nao_competitivo`) ficam só nos campos protegidos do banco; o agente recebe só avisos públicos.

### O que NÃO foi feito (honestidade)
- **A identidade visual da pasta no seu computador (`G:\Meu Drive\...\SUA_GRAFICA_BH_BRANDKIT`) não estava acessível** a esta sessão (é uma pasta do Windows e o CRM roda em nuvem). Usei a paleta, o logo (mesmo do favicon) e a fonte Inter que o CRM já tem, que foram tirados do brand kit na Parte 1. **Compare um PDF de exemplo com o brand kit** (cores, fonte, logo) e me diga o que ajustar; é só o CSS do modelo.
- Gotenberg **não foi instalado** e a Edge Function não foi testada contra ele nem contra a Meta (sem acesso). Os PDFs de exemplo foram gerados com o Chromium local, o mesmo motor do Gotenberg.
- Os workflows do n8n foram validados pelo MCP, mas **não executados** (o gatilho "Execute Workflow" não roda pelo MCP). A lógica de preço, prazo, frete e travas foi testada no banco.
- Instagram (`@suagraficabh`) e site (`suagraficabh.com.br`) entram em `app_settings.company` por SQL (ver `depende-de-voce.md`); o PDF mostra só o que existir.

### Pendências (dono)
Ver `docs/agente/depende-de-voce.md`, seção Etapa 4. Resumo: aplicar a migration (`docs/agente/aplicar-etapa4.sql`), rodar o teste SQL e os advisors, instalar o Gotenberg, criar os segredos `GOTENBERG_*`, publicar `orcamento-pdf`, atribuir a credencial do Supabase nos nós HTTP dos 4 workflows, conferir o PDF contra o brand kit e confirmar o prefixo do número do orçamento.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/orcamento_etapa4.sql supabase/tests/preco_etapa3.sql supabase/tests/agente_etapa1.sql supabase/tests/catalogo_etapa2.sql
npm run exemplos:orcamento -- docs/exemplos-orcamento     # refaz os 6 PDFs (Postgres local no ar)
```
No CRM (depois de aplicar): abra um pedido > aba Orçamentos > Enviar; o cartão do kanban mostra o status do orçamento.

## Etapa 3: preço inteligente e condição especial (concluída, aplicada em produção em 28/10/2026)

Branch de trabalho da sessão: `claude/etapa3-preco-desconto-julfis` (parte de `feat/agente-etapa3-preco`, que tinha o início do trabalho). Nada foi aplicado no Supabase, nada foi ativado no n8n, nada foi instalado no servidor.

### O que foi feito
- **Passo 0:** todo ponto que exibe ou grava preço foi listado e classificado em `docs/agente/mapa-crm.md` (seção 7). Tudo o que vai para cliente, orçamento, PDF ou link lê `calcular_preco`; o resto ficou rotulado "base de custo, sem pesquisa".
- **Banco** (migrations `20261029000006` e `20261029000007`, juntas em `docs/agente/aplicar-etapa3.sql`): cache e consultas de mercado, `fontes_pesquisa` (robots, termos e intervalo por domínio), `registrar_pesquisa_mercado` (outliers por desvio absoluto, mediana, confiança), `calcular_preco` com mercado, fator por grupo, âncora de vendas (3 ou mais em 90 dias, limitada pelo mercado), `nao_competitivo` e trava final no piso duro; `agente_preco` com orientação para o agente; `precos_praticados` alimentado por trigger; `aprender_precos_semana`; `oferecer_condicao_especial` (orçamento atualizado, pedido ligado, tudo ou nada), expiração com `pg_cron`, detector de caçador e de padrão incomum, relatório e resumo semanais, política com `simular_politica_desconto` e `salvar_politica_desconto`, edição manual de preço com piso duro e confirmação (`definir_preco_item_pedido`, `precos_manuais_log`), `skus_para_aquecer`. `aplicar_desconto` não existia no repositório nem no banco; o `drop` está na migration por segurança.
- **n8n (MCP):** 4 workflows criados na pasta Sua Gráfica BH, desativados e exportados em `n8n/` (ver `docs/n8n-mapa.md`). Lógica testada no n8n com dados simulados nos nós de rede.
- **Infra:** `infra/searxng` e `infra/renderer` prontos, com passo a passo em `docs/agente/infra-busca.md`.
- **CRM:** Catálogo > Saúde de preços completa (cobertura, margem, conversão, fator por grupo, fontes de cada preço, itens não competitivos, condições, resumo semanal, ajustes); Configurações > Política de desconto com simulação do pior caso e grupos sem desconto; pedido com lucro líquido, bloqueio e confirmação do dono ao editar preço.
- **Testes:** `supabase/tests/preco_etapa3.sql` (**67 passam**, inclui a simulação de **1.000 combinações sem nenhuma violação**), Etapas 1 e 2 contra o schema novo (54 e 82 passam), `npm test`, typecheck e build verdes. Relatório em `docs/agente/etapa3-validacao.md`.

### Decisões
- Fonte prioritária (alfacards.com.br): `robots.txt` libera, **não há página de termos** (ficou `termos_ok` vazio até o dono confirmar) e o preço só aparece com JavaScript e só para as opções padrão. Cobertura esperada baixa; as outras fontes e o cache completam.
- Mercado com 1 fonte é usado com confiança baixa e aviso; com 0 fontes vale a fórmula de custo.
- Aprendizado conta só orçamentos **encerrados** (ganho, perdido, expirado) dos últimos 30 dias, sem os de teste; o orçamento atualizado por condição conta como o original.
- A condição que levaria o orçamento atualizado a ser recusado pela trava de lucro vira "sem condição"; o agente nunca vê o motivo.
- Meta de margem do aprendizado: 20% (`meta_margem_liquida_pct`, para você revisar).
- O workflow de condição devolve o orçamento atualizado e o link novo; o **PDF** fica para o gancho da Etapa 4.

### Pendências
- Dono: aplicar `docs/agente/aplicar-etapa3.sql`, rodar `supabase/tests/preco_etapa3.sql` e os advisors, instalar a busca no Coolify, criar as credenciais no n8n, confirmar os termos de uso do concorrente (`docs/agente/depende-de-voce.md`).
- Etapa 4: PDF do orçamento atualizado e gravar nos itens do orçamento a fonte do mercado (`consulta_mercado_id`, `mercado_mediana`, `fontes_mercado`, `nao_competitivo`, `piso`, `piso_duro`, `lucro_liquido`, colunas já criadas).
- Etapa 5: mensagem curta de espera durante a pesquisa e G1 no WF2. Etapa 7: G2 e G3 nos follow-ups.
- `GBH | WF9 | Erros` ainda não existe (etapa 7/8); os workflows já usam retentativas e `continueRegularOutput`.

### Como testar
```bash
npm test && npm run typecheck && npm run build
supabase/tests/rodar-local.sh supabase/tests/preco_etapa3.sql supabase/tests/agente_etapa1.sql supabase/tests/catalogo_etapa2.sql
psql -h /tmp -p 54329 -U postgres -d gbh -f supabase/tests/tabela-etapa3.sql    # tabelas da validação
```
No CRM (depois de aplicar): Catálogo > Saúde de preços; Configurações > Política de desconto (mude um percentual e veja a simulação); Pedido > Itens (mude o preço de um item abaixo do piso).

## Etapa 2: Catálogo com SKU e banco de conhecimento (concluída, 28/10/2026)

### Aplicação em produção e fechamento (28/10/2026)
- Backup antes: cópia das 20.381 linhas em `private.bkp_products_etapa2` (área privada; apague quando quiser).
- Migrations 15 a 19 aplicadas pelo SQL Editor (`docs/agente/aplicar-etapa2.sql`). Conferido: `catalogo` com as mesmas 20.381 linhas, todas com piso calculado; `products` virou visão; CFV02 = R$ 75,99; 90 trechos; 12 perguntas no cache; 40 sinônimos; bucket `catalogo-fornecedor` privado; agendamento `conhecimento-reindexar` a cada 5 minutos; SKU obrigatório ligado.
- Edge Function `conhecimento` publicada (sem JWT; confere dono, service role ou `x-cron-secret`). Vetores `gte-small` funcionando (20 por rodada de 5 minutos, os 90 ficam prontos em cerca de 20 minutos).
- Segurança em produção: `anon` sem privilégio em `catalogo`, `products_priced`, `catalogo_importacoes` nem nas funções novas; RLS ligada em todas as tabelas novas; `buscar_produto` e `agente_preco` testadas com dados reais sem custo, piso, margem, lucro ou fornecedor na resposta.
- Advisors de segurança: nenhum alerta novo grave. As funções novas aparecem em "executável por usuário logado" por desenho (cada uma confere a permissão por dentro). Seguem os 2 antigos: `rls_auto_enable` executável por `anon` (função do próprio Supabase) e proteção contra senhas vazadas desligada no Auth.
- **A tabela do fornecedor passou a ser só Excel** (não mais PDF). A pré-visualização da importação mostrou que a planilha é **idêntica ao catálogo atual**: 20.381 linhas lidas, 20.381 iguais, 0 novas, 0 alteradas, 0 sem código, 0 conflitos, 0 rejeitadas, 0 removidas, CFV02 = R$ 75,99. Não havia nada a aplicar; a importação foi fechada como cancelada.
- **Linhas sem código: nenhuma.** As cerca de 590 linhas sem código eram do PDF, que foi descartado. Se uma tabela futura trouxer linhas sem código, a aba Sem código cuida delas.
- Os 90 trechos de conhecimento foram marcados como revisados a pedido do dono (que revisa depois). Os `[CONFIRMAR]` continuam escritos nos fatos de cada trecho como lembrete interno.

(O texto abaixo foi escrito antes da aplicação e fica como histórico.)

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
