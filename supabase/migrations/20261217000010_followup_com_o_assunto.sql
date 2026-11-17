-- O lembrete de cliente quente (Q1 e Q2) cita o assunto da conversa: usa a última pergunta que a Laura fez ao cliente
-- (`private.fu_ultima_pergunta`, sem chamar o Gemini e sem valores) em vez de uma frase genérica. Sem pergunta
-- aproveitável, mantém o texto genérico. Aplicada em produção pelo conector (marca /* q_assunto */ em followup_montar).
select 1;
