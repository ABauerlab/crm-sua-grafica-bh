# Checklist de lançamento do tráfego pago (gerado em 15/11/2026)

## 0. BLOQUEIO (fazer primeiro): cobrança do Gemini
Em 15/11 às 21h os testes passaram a falhar com a mensagem **"Payment required - perhaps check your payment details?"** no nó do agente do WF2. Ou seja, a Laura NÃO consegue responder enquanto a conta do Google (Gemini API) estiver sem crédito ou com a cobrança bloqueada.
- Abra o Google AI Studio (ou o Google Cloud) do projeto da chave usada na credencial do n8n, confira Faturamento, saldo e limite de gasto, e recarregue ou ative a cobrança.
- Confirme com um teste: o cenário `e5-01-cartao-do-anuncio` deve voltar a responder (ver "Como rodar a bateria").
- Sem isso, nenhuma venda sai. O vigia de silêncio avisa o dono depois de 150 s, mas não responde o cliente.

## 1. Migrations que só aplicam no PC (o Supabase pede confirmação do dono)
Aprove a confirmação no app do Claude no PC e rode `supabase db push` (as migrations são idempotentes):
- `20261202000002_excluir_conversa_e_contato.sql`: funções de apagar conversa e contato (o botão já está no CRM).
- `20261203000003_pos_entrega_avaliacao_e_consentimento.sql`: agradecimento, avaliação no Google e consentimento depois da entrega.
Já aplicadas em produção hoje: `20261215000001` (vigia de silêncio), `20261215000002` e `20261215000003` (busca, alerta de orçamento alto) e `20261215000004` (ordem da loja por quantidade).

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
