-- Agente de IA, Etapa 1 (1/4): parâmetros comerciais, política de desconto, zonas de frete e configuração do agente.
-- Aditiva e idempotente. Valores marcados em campos_revisar / revisar são suposições a confirmar pelo dono.
-- Nada aqui expõe custo: tabelas com RLS só para o dono (private.is_staff()) e sem acesso do anon.

create extension if not exists vector with schema extensions;

create or replace function private.toca_atualizado_em() returns trigger
language plpgsql set search_path = ''
as $$ begin new.atualizado_em := now(); return new; end; $$;
revoke execute on function private.toca_atualizado_em() from public, anon, authenticated;

-- Parâmetros comerciais: uma linha só (id = 1). Tudo que o preço, o frete e o prazo leem fica aqui, nunca no código.
create table if not exists public.parametros_comerciais (
  id smallint primary key default 1 check (id = 1),
  -- preço
  multiplicadores jsonb not null default '[{"ate":100,"multiplicador":2.0},{"ate":300,"multiplicador":1.9},{"ate":800,"multiplicador":1.75},{"ate":null,"multiplicador":1.6}]',
  fator_competitivo numeric(4, 3) not null default 0.93 check (fator_competitivo between 0.5 and 1.5),
  fator_competitivo_min numeric(4, 3) not null default 0.90,
  fator_competitivo_max numeric(4, 3) not null default 0.98,
  multiplicador_piso numeric(4, 2) not null default 1.5 check (multiplicador_piso >= 1),
  lucro_liquido_minimo numeric(10, 2) not null default 60 check (lucro_liquido_minimo >= 0),
  imposto_pct numeric(5, 2) not null default 6 check (imposto_pct between 0 and 50),
  taxas_pagamento jsonb not null default '{
    "cartao_credito":{"pct":4.98,"fixo":0},
    "saldo_mercado_pago":{"pct":4.99,"fixo":0},
    "linha_credito":{"pct":4.99,"fixo":0},
    "cartao_prepago":{"pct":4.99,"fixo":0},
    "pix":{"pct":0.99,"fixo":0},
    "open_finance":{"pct":0,"fixo":0},
    "boleto":{"pct":0,"fixo":3.49}
  }',
  metodo_piso text not null default 'cartao_credito',
  custo_whatsapp_conversa numeric(10, 2) not null default 0.50 check (custo_whatsapp_conversa >= 0),
  custo_ia_conversa numeric(10, 2) not null default 0.30 check (custo_ia_conversa >= 0),
  arte_valor numeric(10, 2) not null default 39.90,
  arte_frete_valor numeric(10, 2) not null default 49.90,
  validade_orcamento_dias smallint not null default 7 check (validade_orcamento_dias > 0),
  idade_max_pesquisa_dias smallint not null default 14,
  -- prazo
  horario_atendimento jsonb not null default '{
    "seg":{"abre":"09:00","fecha":"17:00"},"ter":{"abre":"09:00","fecha":"17:00"},"qua":{"abre":"09:00","fecha":"17:00"},
    "qui":{"abre":"09:00","fecha":"17:00"},"sex":{"abre":"09:00","fecha":"18:30"},"sab":null,"dom":null
  }',
  corte_producao_hora smallint not null default 12 check (corte_producao_hora between 0 and 23),
  dias_logistica smallint not null default 1 check (dias_logistica >= 0),
  -- frete
  pedido_minimo_frete_gratis numeric(10, 2) not null default 150,
  custo_entrega_bike numeric(10, 2) not null default 8.00 check (custo_entrega_bike >= 0),
  custo_entrega_uber numeric(10, 2) not null default 25.00 check (custo_entrega_uber >= 0),
  exigir_cabe_na_bike boolean not null default true,
  peso_max_bike_g integer not null default 3000 check (peso_max_bike_g > 0),
  lado_max_bike_mm integer not null default 600 check (lado_max_bike_mm > 0),
  saidas_bike_por_dia smallint not null default 2 check (saidas_bike_por_dia > 0),
  -- limites de IA
  tokens_max_conversa integer not null default 40000 check (tokens_max_conversa > 0),
  tokens_max_dia integer not null default 1500000 check (tokens_max_dia > 0),
  -- condição especial: detector de caçador de desconto e grupos fora da política
  cacador_min_orcamentos smallint not null default 4 check (cacador_min_orcamentos >= 2),
  cacador_janela_dias smallint not null default 60,
  categorias_sem_desconto text[] not null default '{}',
  -- regras de integridade (exigir_sku_pedidos liga a exigência de SKU em order_items; ligar na Etapa 2, quando a tela passar a pedir SKU)
  exigir_sku_pedidos boolean not null default false,
  campos_revisar text[] not null default '{}',
  atualizado_em timestamptz not null default now()
);

insert into public.parametros_comerciais (id, campos_revisar) values (1, array[
  'validade_orcamento_dias', 'custo_whatsapp_conversa', 'custo_ia_conversa', 'custo_entrega_bike', 'custo_entrega_uber',
  'saidas_bike_por_dia', 'cacador_min_orcamentos', 'tokens_max_conversa', 'tokens_max_dia', 'pedido_minimo_frete_gratis', 'exigir_sku_pedidos'
]) on conflict (id) do nothing;

drop trigger if exists parametros_comerciais_toca on public.parametros_comerciais;
create trigger parametros_comerciais_toca before update on public.parametros_comerciais
  for each row execute function private.toca_atualizado_em();

-- Política de desconto: a escada da seção 7B. O modelo nunca escolhe percentual nem valor.
create table if not exists public.politica_desconto (
  degrau smallint primary key check (degrau between 1 and 3),
  nome text not null,
  tipo text not null check (tipo in ('vantagem', 'desconto')),
  percentual numeric(5, 2) not null default 0 check (percentual >= 0 and percentual <= 10),
  gatilhos text[] not null check (gatilhos <@ array['G1', 'G2', 'G3']),
  fracao_gordura_max numeric(4, 3) not null default 0.6 check (fracao_gordura_max between 0 and 1),
  desconto_max_reais numeric(10, 2) not null default 80 check (desconto_max_reais >= 0),
  valor_minimo_reais numeric(10, 2) not null default 5 check (valor_minimo_reais >= 0),
  intervalo_dias_contato smallint not null default 30 check (intervalo_dias_contato >= 0),
  max_condicoes_por_orcamento smallint not null default 1 check (max_condicoes_por_orcamento >= 1),
  validade_horas smallint not null default 24 check (validade_horas > 0),
  ativo boolean not null default true,
  revisar boolean not null default false,
  atualizado_em timestamptz not null default now()
);

insert into public.politica_desconto (degrau, nome, tipo, percentual, gatilhos, revisar) values
  (1, 'Vantagem de baixo custo (arte grátis ou frete grátis sem mínimo)', 'vantagem', 0, array['G1', 'G2'], false),
  (2, 'Desconto de até 4%', 'desconto', 4, array['G1', 'G2'], false),
  (3, 'Última tentativa: desconto de até 8%', 'desconto', 8, array['G3'], false)
on conflict (degrau) do nothing;

drop trigger if exists politica_desconto_toca on public.politica_desconto;
create trigger politica_desconto_toca before update on public.politica_desconto
  for each row execute function private.toca_atualizado_em();

-- Zonas de frete grátis (bairros e faixas de CEP). Inativa = cadastrada, mas ainda não vale.
create table if not exists public.zonas_frete_gratis (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('bairro', 'cep')),
  bairro text,
  cep_inicio char(8),
  cep_fim char(8),
  ativo boolean not null default true,
  revisar boolean not null default true,
  observacao text,
  criado_em timestamptz not null default now(),
  check (
    (tipo = 'bairro' and bairro is not null and cep_inicio is null and cep_fim is null)
    or (tipo = 'cep' and cep_inicio ~ '^[0-9]{8}$' and cep_fim ~ '^[0-9]{8}$' and cep_inicio <= cep_fim and bairro is null)
  )
);
create unique index if not exists zonas_frete_bairro_uniq on public.zonas_frete_gratis (lower(bairro)) where tipo = 'bairro';
create unique index if not exists zonas_frete_cep_uniq on public.zonas_frete_gratis (cep_inicio, cep_fim) where tipo = 'cep';

-- Configuração do agente (a chave liga/desliga fica em ia_ligada; o botão do topo do CRM continua em app_settings.agent até a Etapa 5)
create table if not exists public.agente_config (
  id smallint primary key default 1 check (id = 1),
  ia_ligada boolean not null default false,
  atende_24h boolean not null default true,
  horario_ia jsonb not null default '{"inicio":"00:00","fim":"23:59","dias":[0,1,2,3,4,5,6]}',
  whatsapp_dono text not null default '5531998021169' check (whatsapp_dono ~ '^[0-9]+$'),
  mensagem_transferencia text not null default 'Vou chamar o responsável para te ajudar. Um instante!',
  nome_atendente text,
  modelo_padrao text,
  modelo_forte text,
  debounce_segundos smallint not null default 8 check (debounce_segundos >= 0),
  historico_mensagens smallint not null default 6 check (historico_mensagens >= 0),
  max_fotos_por_pedido smallint not null default 3,
  atualizado_em timestamptz not null default now()
);
insert into public.agente_config (id) values (1) on conflict (id) do nothing;

drop trigger if exists agente_config_toca on public.agente_config;
create trigger agente_config_toca before update on public.agente_config
  for each row execute function private.toca_atualizado_em();

-- Feriados: a tabela existente (holidays) é reaproveitada; "feriados" é a visão que o dono e o agente usam.
alter table public.holidays add column if not exists revisar boolean not null default false;
create or replace view public.feriados with (security_invoker = true) as
  select day as dia, name as nome, scope as escopo, revisar from public.holidays;

-- Ligação anúncio -> produto ou kit
create table if not exists public.anuncios_produtos (
  id uuid primary key default gen_random_uuid(),
  ad_id text not null unique,
  ad_nome text,
  sku text,
  kit_id uuid references public.kits (id) on delete set null,
  observacao text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  check (sku is not null or kit_id is not null)
);

-- RLS e permissões: só o dono; nada para o anon
do $$
declare t text;
begin
  foreach t in array array['parametros_comerciais', 'politica_desconto', 'zonas_frete_gratis', 'agente_config', 'anuncios_produtos'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('drop policy if exists %I on public.%I', t || '_dono', t);
    execute format('create policy %I on public.%I for all to authenticated using (private.is_staff()) with check (private.is_staff())', t || '_dono', t);
  end loop;
end $$;
revoke all on public.feriados from anon;

-- Dados iniciais: feriados (2026 e 2027 já existem; marca os de Belo Horizonte para revisão e inclui o aniversário da cidade)
update public.holidays set revisar = true where scope <> 'nacional';
insert into public.holidays (day, name, scope, revisar) values
  ('2026-12-12', 'Aniversário de Belo Horizonte (sábado)', 'belo_horizonte', true),
  ('2027-12-12', 'Aniversário de Belo Horizonte (domingo)', 'belo_horizonte', true)
on conflict (day) do nothing;

-- Zonas de frete grátis: bairros informados pelo dono (ativos, para conferir) e candidatos vizinhos (inativos até confirmar)
insert into public.zonas_frete_gratis (tipo, bairro, ativo, revisar, observacao) values
  ('bairro', 'Centro', true, true, 'Carga inicial do dono'),
  ('bairro', 'Santa Efigênia', true, true, 'Carga inicial do dono'),
  ('bairro', 'Barro Preto', true, true, 'Carga inicial do dono'),
  ('bairro', 'Lourdes', true, true, 'Carga inicial do dono'),
  ('bairro', 'Funcionários', true, true, 'Carga inicial do dono'),
  ('bairro', 'Savassi', true, true, 'Carga inicial do dono'),
  ('bairro', 'Santo Agostinho', true, true, 'Carga inicial do dono'),
  ('bairro', 'Floresta', true, true, 'Carga inicial do dono'),
  ('bairro', 'Santa Tereza', true, true, 'Carga inicial do dono'),
  ('bairro', 'Sagrada Família', true, true, 'Carga inicial do dono'),
  ('bairro', 'Serra', true, true, 'Carga inicial do dono'),
  ('bairro', 'Santo Antônio', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'São Pedro', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'Sion', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'Carmo', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'Cruzeiro', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'Anchieta', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'Gutierrez', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'Lagoinha', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'Boa Viagem', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'Horto', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'Prado', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'Coração de Jesus', false, true, 'Candidato vizinho, inativo até o dono confirmar'),
  ('bairro', 'Santa Lúcia', false, true, 'Candidato vizinho, inativo até o dono confirmar')
on conflict do nothing;

-- Faixa de CEP aproximada do bloco central (30110-000 a 30199-999). Conferir; fora dela a pergunta é pelo bairro.
insert into public.zonas_frete_gratis (tipo, cep_inicio, cep_fim, ativo, revisar, observacao)
values ('cep', '30110000', '30199999', true, true, 'Faixa aproximada do bloco central; conferir com o mapa')
on conflict do nothing;
