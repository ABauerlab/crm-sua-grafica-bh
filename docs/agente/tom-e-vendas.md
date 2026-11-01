# Tom e vendas no WhatsApp

Base: pesquisa web (01/11/2026) mais as decisões do dono (`decisoes-e-melhorias.md`). Fontes: [Agendor](https://www.agendor.com.br/blog/?p=32051), [Stone](https://conteudo.stone.com.br/atendimento-via-whatsapp/), [Sebrae](https://sebrae.com.br/content/dam/portal-sebrae/na/midias/documentos/pdfs/ebook_como-vender-whatsapp-sem-perder-cliente.pdf), [Aurora Inbox](https://www.aurorainbox.com/pt/?p=36653), [Sendpulse](https://sendpulse.com/br/blog/texto-pronto-para-vendas-no-whatsapp). Muitas fontes são conteúdo promocional: usei só o que concorda entre elas.

## O que caracteriza atendimento humano que vende
1. **Escuta ativa:** responder ao que o cliente disse (não a um roteiro) e confirmar o entendimento ("então são 500 cartões com verniz, certo?").
2. **Espelhamento:** devolver as palavras do cliente e acompanhar o nível de formalidade e o tamanho das mensagens. Cliente curto recebe resposta curta.
3. **Perguntas abertas e curtas, uma por vez:** "Pra que tipo de negócio?" antes de "Qual gramatura?". No máximo duas perguntas por mensagem.
4. **Prova social honesta:** só o que é verdade (quantidade de clientes, prazo cumprido). Nada inventado, nada de depoimento falso.
5. **Tratamento de objeção:** acolher ("faz sentido olhar o valor"), entender o motivo (preço, prazo, insegurança) e responder com valor real: arte, agilidade, atendimento. Desconto só pela ferramenta, nunca por conta própria.
6. **Fechamento assumido:** depois de definido o item, propor o próximo passo como natural: "Posso já te mandar o link do Pix?".
7. **Pós-venda genuíno:** confirmar que chegou certo e pedir a avaliação sem oferecer nada em troca.

## Regras do agente (o que entrou no prompt e no conhecimento)
- Mensagens curtas, uma ideia por vez. Primeiro nome do cliente.
- Emoji com moderação. Abreviações naturais como "vc", "pra", "tá", sem erro de português. "kkkk" ou "rsrs" só se o cliente abrir espaço.
- Reclamação ou assunto sério: tom profissional, sem emoji, sem brincadeira, e chamar o dono com resumo.
- Sem travessão, sem lista, sem markdown.
- Pix sempre primeiro; parcelar em 2x só se o cliente perguntar ou hesitar por valor.
- Nunca prometer o que o sistema não confirma (pagamento, arte aprovada, produção, data, reembolso). A trava de saída barra essas promessas.
- Dados: pedir só o que falta; CPF ou CNPJ e endereço só para nota fiscal ou entrega; promoções são uma pergunta separada.

Os trechos `tom-vendedor`, `pag-formas`, `pag-pix`, `pag-parcelar`, `pag-nf`, `troca-politica`, `google-avaliacao`, `bauerlab`, `urgencia` e `dados-cliente` (migration `20261103000004`) carregam essas regras para o agente via `buscar_conhecimento`.

## Limites técnicos
- **A API oficial do WhatsApp não avisa quando o cliente está digitando** (só o negócio pode mostrar "digitando" para o cliente, por até cerca de 25 s, em [Meta](https://developers.facebook.com/documentation/business-messaging/whatsapp/typing-indicators/)). Por isso o agrupamento é de 10 s e, se a última mensagem parece incompleta (termina em ":" ou em "e", "então", "tipo"..., ou chegou só áudio ou arquivo), espera mais até 20 s, no máximo 60 s no total. Pergunta completa responde já.
- **Melhoria sugerida:** enviar o indicador "digitando" ao cliente enquanto o agente trabalha (marca como lida e mostra "digitando"). Deixa a conversa mais natural. Fica como próximo passo (pede uma chamada no `agente-enviar`).
