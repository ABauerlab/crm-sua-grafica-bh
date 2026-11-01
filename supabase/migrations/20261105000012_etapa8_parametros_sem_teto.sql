-- Etapa 8 (decisão do dono): atendimento sem teto por conversa. A primeira conversa real (Rose) parou ao passar de 40 mil tokens e perdeu a venda.
-- Os tetos viram apenas fusíveis altíssimos contra laço infinito; o custo é acompanhado no painel e pelo alerta de 70% do teto diário em R$.
update public.parametros_comerciais set tokens_max_conversa = 2000000, tokens_max_dia = 200000000 where id = 1;
update public.app_settings set value = value || '{"teto_custo_dia_brl":3000}'::jsonb where key = 'observabilidade';
update public.agente_config set debounce_segundos = 6 where id = 1;
