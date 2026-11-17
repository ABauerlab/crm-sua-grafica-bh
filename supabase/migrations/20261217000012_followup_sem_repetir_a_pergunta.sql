-- O lembrete de cliente quente repetia literalmente a última pergunta que a Laura já tinha feito (redundante).
-- Agora usa o ASSUNTO (`private.fu_assunto`: produto mais recente citado nas últimas mensagens) e a quantidade da ficha,
-- sem citar a pergunta anterior (`private.fu_texto_q`, duas variações por regra). Sem assunto nem quantidade, mantém o texto genérico.
-- Aplicada em produção pelo conector (marca /* q_sem_eco */ em followup_montar).
select 1;
