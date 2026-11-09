-- Decisão do dono (09/11/2026): no pedido, só o dono logado pode gravar preço abaixo do piso duro, com confirmação e motivo.
-- definir_preco_item_pedido (migration 20261110000001) já aceita a faixa abaixo_piso_duro, mas a restrição de
-- precos_manuais_log só aceitava 'ok' e 'entre_pisos': a gravação do log falhava e desfazia a confirmação.
-- Aqui a restrição passa a aceitar abaixo_piso_duro, para a exceção ficar auditada. Agente, n8n e service role
-- continuam bloqueados (is_staff() é falso sem o dono logado).
-- Aditiva e idempotente. Reverter: recriar a restrição com ('ok', 'entre_pisos') depois de tratar as linhas abaixo_piso_duro.
alter table public.precos_manuais_log drop constraint if exists precos_manuais_log_faixa_check;
alter table public.precos_manuais_log add constraint precos_manuais_log_faixa_check
  check (faixa = any (array['ok'::text, 'entre_pisos'::text, 'abaixo_piso_duro'::text]));
