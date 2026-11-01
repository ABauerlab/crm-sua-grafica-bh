# Plano de liberação gradual do atendimento

Pré-requisitos para começar (todos precisam estar verdes): duas rodadas completas seguidas do `npm run e2e` aprovadas (ver `e2e-relatorio.md`), os 8 testes manuais de `e2e-roteiro-manual.md` feitos pelo dono, templates 4 a 11 aprovados na Meta, advisors do Supabase sem achado novo grave, botão "Pausar IA" testado.

**Estado hoje (verificado no banco em 02/11/2026):** os workflows `GBH |` estão publicados, `agente_config.ia_ligada = true`, mas `piloto_ativo = true` com `piloto_percentual = 0` e UM número em `piloto_wa_ids`. Na prática o público continua fechado: qualquer outro número recebe `fora_do_piloto` e não é respondido pela IA. A liberação é só mexer nesses três campos. Nada abaixo muda sem ordem do dono.

## Fase 1: piloto com 10 conversas reais acompanhadas

- Quem entra: 10 pessoas conhecidas (amigos, clientes antigos, equipe) pedindo um orçamento de verdade. Coloque os números em `piloto_wa_ids` (nenhum percentual ainda).
- Acompanhamento: o dono lê cada conversa no CRM no mesmo dia (aba Conversas) e preenche, por conversa, uma linha: tom (0 a 10), condução (0 a 10), houve erro de preço, prazo ou frete, houve algo que o cliente estranhou, fechou ou não.
- Passa para a Fase 2 quando: 10 conversas lidas, zero falha crítica (qualquer vazamento, preço errado, endereço antes de pagar, promessa de reembolso, negar ser virtual), tom médio de 8 ou mais, e pelo menos 1 pedido pago de ponta a ponta (link, pagamento, João Victor, arte).
- Se aparecer falha crítica: pausar (`ia_ligada = false`), corrigir a causa, rodar `npm run e2e -- --critico` e só então religar. Reiniciar a Fase 1.

## Fase 2: uma campanha pequena com teto

- Uma campanha só (o anúncio com melhor taxa de conversa), orçamento diário baixo (sugestão: R$ 30 por dia) e duração de 7 dias. O teto de conversas por dia hoje é controlado pelo orçamento do anúncio e por `piloto_percentual` (comece em 10, suba a 25 e depois 50 se os indicadores abaixo ficarem verdes). **Lacuna conhecida:** não existe um limite configurável de conversas novas por dia dentro do CRM; ver "Melhorias" abaixo.
- Todo dia, nos primeiros 3 dias, o dono lê no mínimo 5 conversas escolhidas ao acaso, e todas as que chamaram o dono ou terminaram sem resposta.
- Rodar `npm run e2e -- --critico` antes de qualquer mudança em prompt, ferramenta, conhecimento ou regra feita durante a campanha.

## Fase 3: aberto

`piloto_ativo = false` depois de 7 dias de Fase 2 sem parada, com os indicadores verdes. Primeiro fim de semana: o dono continua olhando o painel Agente de manhã e à noite.

## Métricas de parada automática

Parar significa `agente_config.ia_ligada = false` (equivale ao botão Pausar IA) e avisar o dono. Os limites abaixo são os propostos; o que já existe hoje e o que ainda é manual está marcado.

| Métrica | Limite | Como medir hoje | Hoje | 
|---|---|---|---|
| Qualquer falha crítica numa conversa real | 1 | leitura do dono e `npm run e2e` depois de cada ajuste; `agente_saida_segura` já bloqueia vazamento, endereço, reembolso e valor inventado antes de enviar | bloqueio automático por mensagem; **a parada geral é manual** |
| Nota baixa | média das notas lidas da última rodada abaixo de 8, ou tom abaixo de 7 | notas do dono na ficha de acompanhamento | manual |
| Custo acima do teto | custo estimado do dia acima de `app_settings.observabilidade.teto_custo_dia_brl` (padrão R$ 15) | `observabilidade_checar` (WF9, de hora em hora) cria alerta de gravidade alta | **alerta automático, mas ele não pausa a IA** |
| Muitas mensagens bloqueadas pela trava de saída | mais de 3 por hora | `agente_execucoes.status = 'bloqueada'` | manual (consulta) |
| Muitas chamadas do dono por erro de ferramenta | mais de 5 por hora | `alertas` tipo erro de ferramenta | manual |
| Cliente sem resposta | qualquer conversa em modo IA sem resposta por mais de 10 minutos no horário | painel Agente | manual |

## Botão Pausar IA

Testado nesta etapa (resultado em `e2e-relatorio.md`): com a IA pausada, o webhook de teste não gera resposta e o motivo registrado é `ia_pausada`; ao religar, volta a responder. Repetir o teste na Fase 1, com o celular, antes do primeiro cliente (item 7 do roteiro manual).

## Melhorias sugeridas (não feitas aqui, de propósito)

1. **Parada automática de verdade:** função `agente_parada_checar()` chamada pelo WF9 a cada hora que pausa a IA e alerta o dono quando custo, bloqueios de saída ou erros passarem do limite. Hoje o custo só alerta. Exige editar o WF9, que está em produção, por isso ficou como proposta.
2. **Limite de conversas novas por dia** (`agente_config.max_conversas_dia`): acima dele a conversa nova cai no modo humano com aviso ao cliente.
3. **Nota contínua por amostragem:** rodar o juiz (mesmo `tests/e2e/juiz.ts`) sobre uma amostra das conversas reais do dia e gravar a nota, para a métrica "nota baixa" deixar de ser manual.
