-- O lembrete de cliente quente repetiu a pergunta da quantidade para o Hudson, que já tinha dito "2 de início".
-- `private.fu_ultima_pergunta` ignora pergunta de quantidade quando a ficha já tem a quantidade informada, e o Q1 usa
-- "Com as N unidades que você me falou, já consigo montar o seu orçamento agora. Posso seguir?" nesse caso.
-- Aplicada em produção pelo conector (marca /* q_qtd_sabida */ em followup_montar).
select 1;
