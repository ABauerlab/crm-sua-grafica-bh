-- Registro das correções já aplicadas no projeto Supabase bhlosshvwmlyzhbghsrc.
-- Mantém o histórico versionado no repositório. As operações são seguras para reexecução.

-- 1. Correção dos 49 SKUs de Bandeiras e Sublimação importados sem decimal (divididos por 100)
UPDATE public.catalogo
SET custo = round(custo / 100.0, 2)
WHERE custo = trunc(custo)
  AND mod(custo, 100) = 99
  AND (categoria = 'BANDEIRAS' OR sku = 'IMPSUBLI01');

-- 2. Elevação segura dos limites operacionais por rodada
UPDATE public.agente_config
SET max_ferramenta_por_rodada = 12,
    max_chamadas_por_rodada = 20,
    atualizado_em = now()
WHERE id = 1;

UPDATE public.parametros_comerciais
SET tokens_max_conversa = GREATEST(tokens_max_conversa, 250000),
    tokens_max_dia = GREATEST(tokens_max_dia, 2000000),
    atualizado_em = now()
WHERE id = 1;
