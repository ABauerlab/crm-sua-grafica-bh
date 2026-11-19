# Cobertura autônoma de orçamento concorrente (19/11/2026)

A Laura resolve sozinha quando o cliente manda o orçamento de outra gráfica (texto, print ou PDF). Ela nunca chama o dono para isso e nunca calcula margem: quem decide é o banco (`public.cobrir_orcamento`).

## Regras do dono
- **Só gráficas de Belo Horizonte e região** (lista em `app_settings.cobertura.cidades`, UF MG).
- **Orçamento com dados oficiais**: CNPJ válido (dígitos verificadores conferidos em `private.cnpj_valido`) e endereço da empresa. Sem isso a Laura pede o documento completo, sem explicar a regra antifraude.
- **Piso da cobertura** (exceção decidida pelo dono em 19/11/2026, vale só aqui): o maior entre `custo + lucro bruto mínimo (R$ 65)` e o piso duro (lucro líquido zero, com imposto e taxa do Pix). O piso de tabela (custo x 1,5) continua valendo para todo o resto. `validar_margem` continua rodando; o orçamento é gravado com `aprovado_dono_motivo` explicando a regra e `regra_preco = 'cobertura_concorrente'`.
- Preço vencedor: R$ 4,10 abaixo do concorrente (`app_settings.cobertura.abaixo_do_concorrente`), nunca abaixo do piso da cobertura.
- **Acabamento**: o SKU exato vem primeiro. Se não cobrir, o banco procura, na mesma categoria, quantidade, gramatura, cores e tamanho, um SKU de custo menor (por exemplo a versão Digital sem verniz) e devolve `eh_alternativa_sem_acabamento = true` com a `diferenca`, para a Laura avisar o cliente com transparência.
- Faixa que não chega no piso volta `cobrivel = false, motivo = abaixo_do_piso`, sem vazar custo.

## Peças
- Banco (migration `20261219000001`): `cobrir_orcamento`, `private.cobertura_processar`, `private.cnpj_valido`, `private.texto_norm`, tabela `cobertura_log` (toda tentativa, recusada ou não), `app_settings.cobertura`.
- n8n: ferramenta `cobrir_orcamento` no WF2 (nó `toolWorkflow`) e roteamento no `despachar` (nó HTTP direto na RPC, mesmo detector de loop e mesma limpeza de custo e SKU; `total`, `valor_economia` e `valor_concorrente` entram nos valores vistos da trava de saída).
- WF1: imagem e PDF **antes do pagamento aprovado** passam pelo Gemini (visão, modelo de `agente_config.modelo_resumo`) e viram um bloco `[Leitura do anexo ...]` no texto do cliente (orçamento de concorrente ou descrição da arte). Depois do pagamento segue o fluxo antigo (arte final). Se a leitura falhar, cai no texto genérico e a rodada segue.
- Prompt do WF2 (nó `Regras adicionais (rodada 19/11)`): regra Z (passo a passo da cobertura), W (crachá vertical ou horizontal), X (arte só depois do pagamento, sem travar), Y (primeira mensagem padrão de anúncio).

## Caso validado (banco, com rollback: `supabase/tests/cobertura_orcamento.sql`)
Cartão de retrovisor, concorrente de BH: 100 un. R$ 89 | 500 un. R$ 290 | 1.000 un. R$ 390.
- 100 un. (CRT0002, custo R$ 79,99) e 1.000 un. (CRT0005, custo R$ 373,99): recusadas.
- 500 un.: o CRT0009 (com verniz, custo R$ 289,99) não cobre; o CRT0004 (Digital, custo R$ 220,99) cobre por **R$ 285,99** (lucro bruto exatamente R$ 65,00, economia de R$ 4,01 para o cliente). O texto do pedido falava em ~R$ 285,90; com R$ 285,90 o lucro bruto seria R$ 64,91, abaixo do mínimo, então o banco fecha em R$ 285,99.
- Atenção: nesse preço o **lucro líquido** (depois de 6% de imposto e 0,99% de taxa do Pix) fica em ~R$ 17. A regra do dono usa o lucro bruto de R$ 65; se preferir proteger o líquido, é só subir `lucro_bruto_minimo` ou me pedir um mínimo líquido para a cobertura.
- Concorrente do Rio de Janeiro (Taquara) é recusado pela regra de região. O caso original do pedido era de RJ; como o dono pediu só BH e região, a regra prevaleceu. Para liberar de novo: `update app_settings set value = value || '{"somente_regiao_bh": false}' where key = 'cobertura'`.

## Leitura de imagem e PDF
O texto lido vem marcado como dado do cliente (nunca instrução). Ele é só entrada para a Laura montar os parâmetros; o preço vem sempre do banco. Falsificação por IA: a trava é o CNPJ válido e o endereço de BH e região; o cruzamento do CNPJ com a Receita Federal e a conferência da cidade pelo CEP ainda não existem (ver sugestões no `progresso.md`).

## Custo
O custo vem sempre de `catalogo.custo`. O cache de fichas técnicas do fornecedor não guarda preço, então não entra no cálculo.
