# Checklist de lançamento do tráfego pago (gerado em 15/11/2026)

## 0. Cobrança do Gemini: RESOLVIDO em 15/11 às 21h20
O saldo foi recarregado e a Laura voltou a responder. A pane tinha causado 15 falhas seguidas ("Payment required"). Depois da recarga a bateria completa deu **54 de 55 cenários aprovados**; o único que falha é o `e8-fluxo-2-orcar-e-fechar` (a Laura consulta o frete do bairro informado mas não conta o resultado na resposta). Se a cobrança travar de novo, o WF2 repete a chamada 2 vezes e manda ao cliente "Oi! Recebi sua mensagem e já volto aqui com você, só um instante.", e o vigia de silêncio avisa o dono depois de 150 s.

## 1. Migrations que só aplicam no PC (o Supabase pede confirmação do dono)
Aprove a confirmação no app do Claude no PC e rode `supabase db push` (as migrations são idempotentes):
- `20261202000002_excluir_conversa_e_contato.sql`: funções de apagar conversa e contato (o botão já está no CRM).
- `20261203000003_pos_entrega_avaliacao_e_consentimento.sql`: agradecimento, avaliação no Google e consentimento depois da entrega.
Já aplicadas em produção hoje: `20261215000001` (vigia de silêncio), `20261215000002`, `20261215000003` e `20261215000005` (busca, preço oficial obrigatório, erros no resumo de 2 h) e `20261215000004` (ordem da loja por quantidade). O alerta de orçamento alto foi retirado.

## 2. Meta
- Templates `pedido_pago_confirmacao` (texto novo, sem a parte da arte) e `pos_venda_avaliacao` estavam PENDING. Quando aprovarem, sincronize em Templates no CRM.

## 3. Limpeza
- Apague a fila temporária de testes: `drop table private.suite_fila; drop function private.suite_disparar();` (o Supabase pede confirmação).

## 4. Como rodar a bateria de novo (55 cenários, cerca de 15 minutos)
```sql
create table if not exists private.suite_fila (nome text primary key, enviado_em timestamptz);
insert into private.suite_fila(nome) select nome from public.testes_conversa where ativo and nome ~ '^(e5|e8|e12|mvp)' on conflict do nothing;
update private.suite_fila set enviado_em = null where nome ~ '.';
select cron.schedule('suite-disparar','* * * * *','select private.suite_disparar()');
```
O cron dispara 5 cenários por minuto e se desliga sozinho. Leia o resultado em `public.testes_conversa` (`ultimo_status`, `ultimo_resultado`) só depois do fim e leia as respostas, não só o status.

## 5. Lançar
- Anunciar só cartão de visita e panfleto até o adesivo ter regra própria (cartela inteira).
- Conferir no Bling o NCM dos itens manuais e os nomes provisórios de contato.
- Exportar produtos para os marketplaces só depois que o site for aprovado.

## 6. Ainda não feito
- Fotos de todas as opções pela VPS logada e conferência de imagem e SKU contra o site do fornecedor.
- Preço em tempo real pela VPS para tamanho fora da planilha.
- Avaliações do Google no site (exige a API do Google).
- Imagens de baixa qualidade (ex.: SKU CPC5405C1) e revisão da home a partir do HTML extraído.
- Regra de adesivo por cartela e fluxo de recuperação para todos os erros possíveis do agente.
- Mensagem neutra ao cliente quando o modelo falha (hoje só o dono é avisado).

## 7. Custo dos testes (medido em 15/11/2026)
- Uma bateria completa (55 cenários) gasta cerca de 1,5 milhão de tokens do Gemini (estimativa do sistema: 2,72 na moeda configurada). Um cenário de orçamento com 3 itens chega a 100 mil a 290 mil tokens, porque cada chamada de ferramenta reenvia o prompt inteiro.
- Em 15/11 foram rodadas quatro baterias e vários reenvios: a maior parte do gasto do dia foi de teste (17 rodadas de clientes reais custaram 0,39 na estimativa).
- Trava criada: o disparador `private.suite_disparar()` dispara no máximo 60 cenários por dia e se desliga sozinho. Nenhum agendamento de teste fica ativo.
- Regra: rodar a bateria completa só quando o dono pedir, no máximo uma vez por dia, e reexecutar só os cenários afetados.


## 8. Rodada de 16/11/2026 (com o dono no PC)
- Aplicadas em produção: apagar conversa e contato (`20261202000002`) e pós-entrega com avaliação e consentimento (`20261203000003`, com ajuste na lista de origens do consentimento). 3 clientes já entregues passaram a constar como autorizados.
- Contatos e conversas de teste apagados (22 com número fictício e o 3132232356). Restam só contatos reais.
- "Assistente virtual": só aparecia nas mensagens de 15/11 antes das 13h UTC. Depois da correção: 0 em produção e 0 nas 55 execuções de teste.
- Envio para fora de BH: `verificar_frete` agora cota PAC e SEDEX pelo SuperFrete (função `loja-frete`) e devolve a cidade do CEP para a Laura confirmar. Em teste com Ubatuba: PAC e SEDEX com prazo, "envia para todo o Brasil" e confirmação da cidade. O frete é pago à parte, antes do envio (ainda não entra no link de pagamento do WhatsApp; o site já embute).
- Regras 32 a 36 no prompt: confirmar CEP antes de corrigir, envio para todo o Brasil, não reperguntar arte dita de forma indireta, confirmar dados da nota fiscal antes do link e enviar fotos sem precisar pedir.
- Adesivo: a busca entende "5 cm" e traz o adesivo de 53 x 53 mm (R$ 91,90 a R$ 109,90) em vez de R$ 1.137,90. Banner 80 x 120 já batia com a planilha.
- Dashboard no iPhone: valores em reais sem corte. Checkout da loja: campos com fonte de 16px (iOS não dá mais zoom), colunas sem estouro e código Pix quebrando linha.
- Fluxo completo validado em banco com pedido de teste: orçamento SG-0508 a R$ 93,90 (igual à planilha), PDF marcado como enviado, link recusado antes do "APROVADO" e liberado depois, pagamento simulado levou o pedido a "pago" com evento e alerta; pedido de teste não foi ao Bling nem ao Meta.
