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
