-- Contato que recusa ou encerra vira status_lead = 'perdido' com motivo_perda (preco, quantidade_minima, prazo, concorrente,
-- sem_motivo), por gatilho em messages (private.lead_recusa_marcar, nunca bloqueia a entrada de mensagem). Se ele voltar com
-- interesse novo, volta para 'qualificando'. Não mexe em quem já tem pedido pago. Colunas contacts.motivo_perda e perdido_em.
-- Aplicada pelo conector; o banco é a fonte da verdade.
select 1;
