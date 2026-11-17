-- A Laura repetia perguntas que o cliente já tinha respondido (caso Hudson: "2 de início" e depois perguntou a quantidade de novo).
-- `private.ficha_respostas(conversa)` monta, com a conversa inteira, os pares pergunta/resposta e a quantidade informada;
-- `agente_contexto` devolve em `ficha`; o WF2 coloca a ficha no prompt (nó "Ficha do que o cliente já respondeu") e a
-- trava de saída (`agente_saida_segura`) marca `pergunta_repetida:quantidade` (motivo leve: repete a resposta uma vez e,
-- se ainda repetir, envia a resposta sem a frase repetida). Aplicada em produção pelo conector (blocos idempotentes
-- com as marcas /* ficha */ e /* pergunta_repetida */); este arquivo registra a mudança.
select 1;
