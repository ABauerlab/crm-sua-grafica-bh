-- Etapa 1 do agente: junção das migrations 11 a 14, para colar no SQL Editor do Supabase. Idempotente: pode rodar de novo sem problema.

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

-- Agente de IA, Etapa 1 (2/4): orçamentos, mercado, conhecimento, follow-ups, alertas, testes e campos novos.
-- Aditiva e idempotente. Reaproveita o que já existe (conversations.needs_human/summary/collected_data, agent_logs, holidays).

-- Campos novos em tabelas existentes
alter table public.conversations add column if not exists modo_atendimento text not null default 'humano'
  check (modo_atendimento in ('ia', 'humano'));

-- modo_atendimento e ai_handled andam juntos (a tela atual e o webhook continuam usando ai_handled)
create or replace function private.sync_modo_atendimento() returns trigger
language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.modo_atendimento = 'ia' then new.ai_handled := true;
    else new.modo_atendimento := case when new.ai_handled then 'ia' else 'humano' end;
    end if;
  elsif new.modo_atendimento is distinct from old.modo_atendimento then
    new.ai_handled := (new.modo_atendimento = 'ia');
  elsif new.ai_handled is distinct from old.ai_handled then
    new.modo_atendimento := case when new.ai_handled then 'ia' else 'humano' end;
  end if;
  return new;
end;
$$;
revoke execute on function private.sync_modo_atendimento() from public, anon, authenticated;
drop trigger if exists conversations_sync_modo on public.conversations;
create trigger conversations_sync_modo before insert or update on public.conversations
  for each row execute function private.sync_modo_atendimento();
update public.conversations set modo_atendimento = case when ai_handled then 'ia' else 'humano' end where modo_atendimento <> case when ai_handled then 'ia' else 'humano' end;

alter table public.contacts add column if not exists status_lead text not null default 'novo'
  check (status_lead in ('novo', 'qualificando', 'orcado', 'negociando', 'cliente', 'frio', 'perdido'));
alter table public.contacts add column if not exists bairro text;
alter table public.contacts add column if not exists cep text check (cep is null or cep ~ '^[0-9]{8}$');
alter table public.contacts add column if not exists optout boolean generated always as (marketing_consent = 'opted_out') stored;
alter table public.contacts add column if not exists origem_anuncio text generated always as (first_referral ->> 'source_id') stored;

alter table public.orders add column if not exists subestatus_pedido text;
alter table public.products add column if not exists permite_desconto boolean not null default true;

-- Taxa de pagamento padrão do pedido passa a ser a do cartão de crédito (a mais alta) até o método real ser conhecido
alter table public.orders alter column payment_fee_pct set default 4.98;
update public.app_settings set value = jsonb_set(value, '{payment_fee_pct}', '4.98') where key = 'pricing' and (value ->> 'payment_fee_pct')::numeric = 1.5;

-- Logs do agente: a tabela agent_logs existente ganha colunas de custo e a visão agente_logs
alter table public.agent_logs add column if not exists workflow text;
alter table public.agent_logs add column if not exists ferramenta text;
alter table public.agent_logs add column if not exists modelo text;
alter table public.agent_logs add column if not exists tokens_entrada integer;
alter table public.agent_logs add column if not exists tokens_saida integer;
alter table public.agent_logs add column if not exists custo_estimado numeric(10, 4);
alter table public.agent_logs add column if not exists duracao_ms integer;
create or replace view public.agente_logs with (security_invoker = true) as select * from public.agent_logs;

-- Orçamentos
create table if not exists public.orcamentos (
  id uuid primary key default gen_random_uuid(),
  numero bigint generated always as identity,
  contact_id uuid not null references public.contacts (id),
  conversation_id uuid references public.conversations (id) on delete set null,
  order_id uuid references public.orders (id) on delete set null,
  origem_id uuid references public.orcamentos (id) on delete set null,
  status text not null default 'rascunho' check (status in ('rascunho', 'enviado', 'aceito', 'pago', 'expirado', 'perdido', 'cancelado')),
  entrega text check (entrega in ('retirada', 'bike', 'uber')),
  bairro text,
  cep text check (cep is null or cep ~ '^[0-9]{8}$'),
  metodo_previsto text,
  arte_modo text not null default 'nenhuma' check (arte_modo in ('nenhuma', 'cliente', 'paga', 'com_frete')),
  arte_valor numeric(12, 2) not null default 0 check (arte_valor >= 0),
  frete_valor numeric(12, 2) not null default 0 check (frete_valor >= 0),
  desconto_valor numeric(12, 2) not null default 0 check (desconto_valor >= 0),
  subtotal numeric(12, 2) not null default 0,
  total numeric(12, 2) not null default 0,
  validade_ate timestamptz,
  regra_preco text,
  confianca_preco text check (confianca_preco in ('alta', 'media', 'baixa')),
  margem_liquida_pct numeric(6, 1),
  lucro_liquido numeric(12, 2),
  aprovado_dono_em timestamptz,
  aprovado_dono_motivo text,
  pdf_path text,
  link_pagamento text,
  teste boolean not null default false,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists orcamentos_contact_idx on public.orcamentos (contact_id, criado_em desc);
create index if not exists orcamentos_status_idx on public.orcamentos (status, validade_ate);

create table if not exists public.orcamento_itens (
  id uuid primary key default gen_random_uuid(),
  orcamento_id uuid not null references public.orcamentos (id) on delete cascade,
  sku text not null,
  descricao text not null,
  quantidade integer not null default 1 check (quantidade > 0),
  preco_unitario numeric(12, 2) not null check (preco_unitario > 0),
  regra_preco text,
  confianca_preco text check (confianca_preco in ('alta', 'media', 'baixa')),
  margem_liquida_pct numeric(6, 1),
  criado_em timestamptz not null default now()
);
create index if not exists orcamento_itens_orc_idx on public.orcamento_itens (orcamento_id);

-- Condições especiais (a escada da seção 7B)
create table if not exists public.condicoes_especiais (
  id uuid primary key default gen_random_uuid(),
  orcamento_id uuid not null references public.orcamentos (id) on delete cascade,
  contact_id uuid not null references public.contacts (id),
  degrau smallint not null references public.politica_desconto (degrau),
  gatilho text not null check (gatilho in ('G1', 'G2', 'G3')),
  tipo text not null check (tipo in ('frete_gratis', 'arte_gratis', 'desconto')),
  valor numeric(12, 2) not null check (valor >= 0),
  texto_curto text not null,
  valida_ate timestamptz not null,
  resultado text not null default 'oferecida' check (resultado in ('oferecida', 'aceita', 'expirada', 'cancelada')),
  criado_em timestamptz not null default now()
);
create index if not exists condicoes_orc_idx on public.condicoes_especiais (orcamento_id);
create index if not exists condicoes_contact_idx on public.condicoes_especiais (contact_id, criado_em desc);

-- Mercado e aprendizado de preços
create table if not exists public.precos_mercado (
  id uuid primary key default gen_random_uuid(),
  sku text,
  chave_especificacao text not null,
  descricao text,
  quantidade integer,
  fonte text not null,
  url text,
  preco numeric(12, 2) not null check (preco > 0),
  outlier boolean not null default false,
  confianca text check (confianca in ('alta', 'media', 'baixa')),
  coletado_em timestamptz not null default now()
);
create index if not exists precos_mercado_sku_idx on public.precos_mercado (sku, coletado_em desc);
create index if not exists precos_mercado_chave_idx on public.precos_mercado (chave_especificacao, coletado_em desc);

create table if not exists public.precos_praticados (
  id uuid primary key default gen_random_uuid(),
  orcamento_id uuid references public.orcamentos (id) on delete set null,
  contact_id uuid references public.contacts (id) on delete set null,
  sku text not null,
  grupo_produto text,
  quantidade integer not null check (quantidade > 0),
  preco_total numeric(12, 2) not null,
  margem_liquida_pct numeric(6, 1),
  regra_preco text,
  condicao_especial_id uuid references public.condicoes_especiais (id) on delete set null,
  resultado text not null default 'aberto' check (resultado in ('aberto', 'ganho', 'perdido', 'expirado')),
  criado_em timestamptz not null default now(),
  fechado_em timestamptz
);
create index if not exists precos_praticados_sku_idx on public.precos_praticados (sku, criado_em desc);

-- Base de conhecimento (pgvector). Dimensão 768 compatível com os embeddings do Gemini; a tabela está vazia e a Etapa 2 confirma o modelo.
create table if not exists public.conhecimento (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  conteudo text not null,
  categoria text,
  tags text[] not null default '{}',
  fonte text,
  embedding extensions.vector(768),
  ativo boolean not null default true,
  revisar boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists conhecimento_embedding_idx on public.conhecimento using hnsw (embedding extensions.vector_cosine_ops);
drop trigger if exists conhecimento_toca on public.conhecimento;
create trigger conhecimento_toca before update on public.conhecimento
  for each row execute function private.toca_atualizado_em();

-- Follow-ups
create table if not exists public.followup_regras (
  codigo text primary key,
  descricao text not null,
  referencia text not null check (referencia in ('orcamento_enviado', 'link_pagamento', 'pedido_entregue', 'pedido_pago')),
  atraso_minutos integer not null check (atraso_minutos >= 0),
  grupo_produto text,
  gatilho_condicao text check (gatilho_condicao in ('G2', 'G3')),
  template_janela_fechada text,
  template_alternativo text,
  hora_min smallint not null default 8,
  hora_max smallint not null default 20,
  ativo boolean not null default true,
  revisar boolean not null default false
);

insert into public.followup_regras (codigo, descricao, referencia, atraso_minutos, grupo_produto, gatilho_condicao, template_janela_fechada, template_alternativo, revisar) values
  ('F1', 'Cerca de 2 horas depois do orçamento (mensagem livre, sem desconto)', 'orcamento_enviado', 120, null, null, null, null, false),
  ('F2', 'Cerca de 20 horas depois, antes de fechar a janela de 24h (cita prazo e validade, sem desconto)', 'orcamento_enviado', 1200, null, null, 'orcamento_vence_hoje', null, false),
  ('F3', 'Dia 2: condição especial do degrau 1 ou 2, se a função permitir', 'orcamento_enviado', 2880, null, 'G2', 'condicao_especial_orcamento', 'orcamento_vence_hoje', false),
  ('F4', 'Dia 5: última condição (degrau 3), se a função permitir; senão última chance sem benefício', 'orcamento_enviado', 7200, null, 'G3', 'condicao_especial_orcamento', 'ultima_chance_orcamento', false),
  ('PAG_1H', 'Pagamento pendente: lembrete em 1 hora', 'link_pagamento', 60, null, null, 'pagamento_pendente', null, false),
  ('PAG_6H', 'Pagamento pendente: lembrete em 6 horas', 'link_pagamento', 360, null, null, 'pagamento_pendente', null, false),
  ('PAG_24H', 'Pagamento pendente: lembrete em 24 horas', 'link_pagamento', 1440, null, null, 'pagamento_pendente', null, false),
  ('POS_ENTREGA', 'Satisfação curta e abertura para novo pedido, 1 dia depois da entrega', 'pedido_entregue', 1440, null, null, 'pos_venda_satisfacao', null, true),
  ('RECOMPRA_CARTAO', 'Recompra de cartão de visita: cerca de 60 dias', 'pedido_entregue', 86400, 'CARTÕES DE VISITA', null, 'recompra_lembrete', null, true),
  ('RECOMPRA_ADESIVO', 'Recompra de adesivo: 45 dias', 'pedido_entregue', 64800, 'ADESIVOS', null, 'recompra_lembrete', null, true),
  ('RECOMPRA_PANFLETO', 'Recompra de panfleto: 30 dias', 'pedido_entregue', 43200, 'PANFLETOS, FLYERS E FOLHETOS', null, 'recompra_lembrete', null, true)
on conflict (codigo) do nothing;

create table if not exists public.followup_fila (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid not null references public.contacts (id) on delete cascade,
  conversation_id uuid references public.conversations (id) on delete set null,
  orcamento_id uuid references public.orcamentos (id) on delete cascade,
  order_id uuid references public.orders (id) on delete cascade,
  regra_codigo text not null references public.followup_regras (codigo),
  chave text not null unique,
  agendado_para timestamptz not null,
  status text not null default 'pendente' check (status in ('pendente', 'enviado', 'cancelado', 'pulado', 'erro')),
  tentativas smallint not null default 0,
  motivo text,
  enviado_em timestamptz,
  criado_em timestamptz not null default now()
);
create index if not exists followup_fila_pendentes_idx on public.followup_fila (agendado_para) where status = 'pendente';

-- Alertas ao dono (a regra de não repetir em 30 minutos é aplicada na Etapa 6)
create table if not exists public.alertas (
  id uuid primary key default gen_random_uuid(),
  tipo text not null,
  gravidade text not null default 'baixa' check (gravidade in ('alta', 'baixa')),
  contact_id uuid references public.contacts (id) on delete set null,
  conversation_id uuid references public.conversations (id) on delete set null,
  order_id uuid references public.orders (id) on delete set null,
  orcamento_id uuid references public.orcamentos (id) on delete set null,
  motivo text not null,
  canais text[] not null default array['whatsapp', 'push'],
  status_whatsapp text,
  status_push text,
  enviado_em timestamptz,
  criado_em timestamptz not null default now()
);
create index if not exists alertas_conversa_idx on public.alertas (conversation_id, tipo, criado_em desc);

-- Casos de teste de conversa (usados na auditoria da Etapa 8)
create table if not exists public.testes_conversa (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  descricao text,
  entradas jsonb not null default '[]',
  esperado jsonb not null default '{}',
  ativo boolean not null default true,
  ultimo_status text check (ultimo_status in ('passou', 'falhou', 'erro')),
  ultimo_resultado jsonb,
  executado_em timestamptz,
  criado_em timestamptz not null default now()
);

-- RLS: só o dono; nada para o anon
do $$
declare t text;
begin
  foreach t in array array['orcamentos', 'orcamento_itens', 'condicoes_especiais', 'precos_mercado', 'precos_praticados', 'conhecimento',
                           'followup_regras', 'followup_fila', 'alertas', 'testes_conversa'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('drop policy if exists %I on public.%I', t || '_dono', t);
    execute format('create policy %I on public.%I for all to authenticated using (private.is_staff()) with check (private.is_staff())', t || '_dono', t);
  end loop;
end $$;
revoke all on public.agente_logs from anon;

-- Endurecimento: o anon (chave publicável) não precisa de acesso direto a nenhuma tabela ou visão do schema public.
-- O front só usa o JWT do dono; as Edge Functions usam a service role. A RLS já bloqueava; aqui o privilégio também sai.
do $$
declare r record;
begin
  for r in select c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'm', 'p') loop
    execute format('revoke all on table public.%I from anon', r.relname);
  end loop;
end $$;
alter default privileges in schema public revoke all on tables from anon;

-- Agente de IA, Etapa 1 (3/4): funções determinísticas de preço, prazo, frete, margem e condição especial.
-- O modelo de IA NUNCA calcula nada disso: o n8n chama estas funções (service role) e repassa só o que o cliente pode ver.
-- Todas são SECURITY INVOKER: a RLS vale (só o dono ou a service role leem produtos e custos). Nenhuma devolve custo.
-- calcular_preco e validar_margem devolvem piso, piso_duro, lucro e margem para uso INTERNO; a ferramenta do agente filtra.

-- ---------------------------------------------------------------- utilidades
create or replace function private.norm_txt(p text) returns text
language sql immutable set search_path = ''
as $$
  select regexp_replace(
    lower(translate(trim(coalesce(p, '')), 'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ', 'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')),
    '\s+', ' ', 'g');
$$;

create or replace function private.brl(p numeric) returns text
language sql stable set search_path = ''
as $$ select 'R$ ' || replace(to_char(p, 'FM999999990.00'), '.', ','); $$;

-- Arredonda para o ,90 mais próximo (ex.: 167,99 vira 167,90; 168,60 vira 168,90)
create or replace function private.arredonda_90(p numeric) returns numeric
language sql immutable set search_path = ''
as $$
  select greatest(0.90, case
    when abs(p - (floor(p) + 0.90)) <= abs(p - (floor(p) - 0.10)) then floor(p) + 0.90
    else floor(p) - 0.10 end);
$$;

-- Menor valor terminado em ,90 que seja maior ou igual a p (nunca fica abaixo do piso)
create or replace function private.teto_90(p numeric) returns numeric
language sql immutable set search_path = ''
as $$ select case when p <= floor(p) + 0.90 then floor(p) + 0.90 else floor(p) + 1.90 end; $$;

-- Multiplicador da faixa de custo ("ate" é o limite superior exclusivo; null = sem limite)
create or replace function private.multiplicador_faixa(p_custo numeric) returns numeric
language plpgsql stable set search_path = ''
as $$
declare
  f jsonb;
  v_mult numeric;
begin
  for f in select * from jsonb_array_elements((select multiplicadores from public.parametros_comerciais where id = 1)) loop
    if f ->> 'ate' is null or p_custo < (f ->> 'ate')::numeric then
      return (f ->> 'multiplicador')::numeric;
    end if;
  end loop;
  return 1.6;
end;
$$;

-- Taxa do método de pagamento. Método desconhecido usa o método do piso (cartão de crédito, o mais caro).
create or replace function private.taxa_pagamento(p_metodo text) returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  m text := lower(coalesce(p_metodo, ''));
  v_chave text;
  v_conhecido boolean := true;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  v_chave := case
    when m in ('cartao_credito', 'cartao', 'credit_card', 'debit_card', 'visa', 'master', 'mastercard', 'elo', 'amex', 'hipercard', 'diners', 'cabal') then 'cartao_credito'
    when m in ('saldo_mercado_pago', 'account_money') then 'saldo_mercado_pago'
    when m in ('linha_credito', 'consumer_credits') then 'linha_credito'
    when m in ('cartao_prepago', 'prepaid_card') then 'cartao_prepago'
    when m = 'pix' then 'pix'
    when m = 'open_finance' then 'open_finance'
    when m in ('boleto', 'ticket', 'bolbradesco', 'pec') then 'boleto'
    else null end;
  if v_chave is null or not (pr.taxas_pagamento ? v_chave) then
    v_chave := pr.metodo_piso;
    v_conhecido := false;
  end if;
  return jsonb_build_object(
    'chave', v_chave,
    'pct', (pr.taxas_pagamento -> v_chave ->> 'pct')::numeric,
    'fixo', (pr.taxas_pagamento -> v_chave ->> 'fixo')::numeric,
    'conhecido', v_conhecido);
end;
$$;

-- Custos que não dependem do produto: WhatsApp e IA por conversa, mais a entrega quando o frete é nosso
create or replace function private.custos_operacionais(p_entrega text) returns numeric
language sql stable set search_path = ''
as $$
  select pr.custo_whatsapp_conversa + pr.custo_ia_conversa
    + case lower(coalesce(p_entrega, '')) when 'bike' then pr.custo_entrega_bike when 'uber' then pr.custo_entrega_uber else 0 end
  from public.parametros_comerciais pr where pr.id = 1;
$$;

-- Receita mínima para obter p_lucro líquido, depois de imposto, taxa do método, custo e extras (arredondada para cima, em centavos)
create or replace function private.receita_para_lucro(p_custo numeric, p_extra numeric, p_lucro numeric, p_metodo text) returns numeric
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  t jsonb := private.taxa_pagamento(p_metodo);
begin
  select * into pr from public.parametros_comerciais where id = 1;
  return ceil(((p_custo + p_extra + (t ->> 'fixo')::numeric + p_lucro) / (1 - pr.imposto_pct / 100 - (t ->> 'pct')::numeric / 100)) * 100) / 100;
end;
$$;

-- Lucro líquido de uma receita
create or replace function private.lucro(p_receita numeric, p_custo numeric, p_extra numeric, p_metodo text) returns numeric
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  t jsonb := private.taxa_pagamento(p_metodo);
begin
  select * into pr from public.parametros_comerciais where id = 1;
  return round(p_receita * (1 - pr.imposto_pct / 100 - (t ->> 'pct')::numeric / 100) - (t ->> 'fixo')::numeric - p_custo - p_extra, 2);
end;
$$;

-- Fechamento financeiro de um orçamento, a partir dos itens gravados (usado por validar_margem, condição especial e triggers)
create or replace function private.orcamento_financeiro(p_orcamento uuid) returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  o public.orcamentos%rowtype;
  pr public.parametros_comerciais%rowtype;
  v_n integer; v_sub numeric; v_custo numeric; v_sem_produto integer;
  v_extra numeric; v_receita numeric; v_itens_liq numeric;
  v_entrega_nossa text;
begin
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return null; end if;
  select * into pr from public.parametros_comerciais where id = 1;
  select count(*), coalesce(sum(i.quantidade * i.preco_unitario), 0), coalesce(sum(p.cost * i.quantidade), 0), count(*) filter (where p.code is null)
    into v_n, v_sub, v_custo, v_sem_produto
  from public.orcamento_itens i left join public.products p on p.code = i.sku
  where i.orcamento_id = p_orcamento;
  v_entrega_nossa := case when o.frete_valor = 0 and o.entrega in ('bike', 'uber') then o.entrega else null end;
  v_extra := private.custos_operacionais(v_entrega_nossa);
  v_itens_liq := v_sub - o.desconto_valor;
  v_receita := v_itens_liq + o.arte_valor + o.frete_valor;
  return jsonb_build_object(
    'itens', v_n, 'itens_sem_produto', v_sem_produto, 'subtotal', v_sub, 'custo', v_custo, 'extra', v_extra,
    'receita_itens_liquida', v_itens_liq, 'receita', v_receita,
    'lucro', private.lucro(v_receita, v_custo, v_extra, o.metodo_previsto),
    'receita_piso_duro', private.receita_para_lucro(v_custo, v_extra, 0, o.metodo_previsto),
    'receita_piso', private.receita_para_lucro(v_custo, v_extra, pr.lucro_liquido_minimo, o.metodo_previsto));
end;
$$;

-- ---------------------------------------------------------------- 1. calcular_preco
create or replace function public.calcular_preco(p_sku text, p_quantidade integer default 1, p_contexto jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  prod record;
  v_qtd integer := greatest(coalesce(p_quantidade, 1), 1);
  v_metodo text := p_contexto ->> 'metodo';
  v_outros_receita numeric := coalesce((p_contexto ->> 'receita_outros')::numeric, 0);
  v_outros_custo numeric := coalesce((p_contexto ->> 'custo_outros')::numeric, 0);
  v_custo_item numeric; v_custo_total numeric; v_extra numeric;
  v_base numeric; v_piso numeric; v_piso_duro numeric;
  v_mediana numeric; v_n integer; v_alvo numeric; v_preco numeric;
  v_regra text; v_conf text; v_nao_comp boolean := false;
  v_receita numeric; v_lucro numeric;
  v_avisos text[] := '{}';
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select p.cost, p.active into prod from public.products p where p.code = p_sku;
  if not found or not prod.active then
    return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado');
  end if;

  v_custo_item := prod.cost * v_qtd;
  v_custo_total := v_custo_item + v_outros_custo;
  v_extra := private.custos_operacionais(p_contexto ->> 'entrega');
  -- piso: o maior entre custo x 1,5 e a receita que garante o lucro líquido mínimo; piso_duro: lucro líquido zero
  v_piso := ceil(greatest(v_custo_item * pr.multiplicador_piso,
                          private.receita_para_lucro(v_custo_total, v_extra, pr.lucro_liquido_minimo, v_metodo) - v_outros_receita) * 100) / 100;
  v_piso_duro := private.receita_para_lucro(v_custo_total, v_extra, 0, v_metodo) - v_outros_receita;
  v_base := private.arredonda_90(v_custo_item * private.multiplicador_faixa(v_custo_item));

  -- mercado: mediana das coletas recentes da mesma especificação (a pesquisa em si entra na Etapa 3)
  select percentile_cont(0.5) within group (order by m.preco), count(*)
    into v_mediana, v_n
  from public.precos_mercado m
  where m.sku = p_sku and not m.outlier and m.coletado_em >= now() - make_interval(days => pr.idade_max_pesquisa_dias);

  if v_n >= 2 then
    v_alvo := private.arredonda_90(v_mediana * v_qtd * pr.fator_competitivo);
    v_regra := 'mercado';
    v_conf := case when v_n >= 3 then 'alta' else 'media' end;
  else
    v_alvo := v_base;
    v_regra := 'custo_x_multiplicador';
    v_conf := 'baixa';
  end if;

  if v_alvo >= v_piso then
    v_preco := v_alvo;
  else
    v_preco := private.teto_90(v_piso);
    v_regra := 'piso';
    v_nao_comp := v_n >= 2;
    if v_nao_comp then v_avisos := array_append(v_avisos, 'mercado_abaixo_do_piso'); end if;
  end if;

  v_receita := v_preco + v_outros_receita;
  v_lucro := private.lucro(v_receita, v_custo_total, v_extra, v_metodo);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku, 'quantidade', v_qtd,
    'preco_unitario', round(v_preco / v_qtd, 2), 'preco_total', v_preco,
    'regra', v_regra, 'confianca', v_conf,
    'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1), 'lucro_liquido', v_lucro,
    'piso', round(v_piso, 2), 'piso_duro', round(v_piso_duro, 2),
    'nao_competitivo', v_nao_comp, 'fontes_mercado', v_n, 'avisos', to_jsonb(v_avisos));
end;
$$;

-- ---------------------------------------------------------------- 2. calcular_prazo
-- Dia em que a contagem do fornecedor começa: o próprio dia se for dia útil e antes do corte; senão o próximo dia útil
create or replace function private.inicio_contagem(p_momento timestamptz) returns date
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_local timestamp := p_momento at time zone 'America/Sao_Paulo';
  v_dia date := (p_momento at time zone 'America/Sao_Paulo')::date;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  if public.is_business_day(v_dia) and v_local::time < make_time(pr.corte_producao_hora, 0, 0) then
    return v_dia;
  end if;
  return public.add_business_days(v_dia, 1);
end;
$$;

-- Data em que fica pronto: dias úteis brutos do fornecedor + dias de logística, a partir do início da contagem
create or replace function private.prazo_data(p_lead_days integer, p_momento timestamptz) returns date
language sql stable set search_path = ''
as $$
  select public.add_business_days(private.inicio_contagem(p_momento), coalesce(p_lead_days, 0) + pr.dias_logistica)
  from public.parametros_comerciais pr where pr.id = 1;
$$;

create or replace function public.calcular_prazo(p_sku text, p_agora timestamptz default now(), p_arte_aprovada boolean default false)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_lead integer;
  v_inicio date; v_pronto date;
  v_hoje date := (p_agora at time zone 'America/Sao_Paulo')::date;
  dias text[] := array['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado'];
  chaves text[] := array['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sab'];
  v_dow integer; v_expediente jsonb;
  v_pronto_txt text; v_quando text; v_frase text;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  select p.lead_days into v_lead from public.products p where p.code = p_sku and p.active;
  if not found then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado'); end if;
  if v_lead is null then return jsonb_build_object('ok', false, 'erro', 'prazo_nao_informado'); end if;

  v_inicio := private.inicio_contagem(p_agora);
  v_pronto := private.prazo_data(v_lead, p_agora);
  v_dow := extract(dow from v_pronto)::integer;
  v_expediente := pr.horario_atendimento -> chaves[v_dow + 1];
  v_pronto_txt := dias[v_dow + 1] || ', dia ' || extract(day from v_pronto)::integer;
  v_quando := case when v_inicio = v_hoje then 'hoje'
                   else dias[extract(dow from v_inicio)::integer + 1] || ', dia ' || extract(day from v_inicio)::integer end;
  v_frase := format('se pagar%s até %sh de %s, fica pronto %s %s',
                    case when p_arte_aprovada then '' else ' e mandar a arte' end,
                    pr.corte_producao_hora, v_quando,
                    case when v_dow in (0, 6) then 'no' else 'na' end, v_pronto_txt);
  return jsonb_build_object(
    'ok', true, 'sku', p_sku,
    'data_pronto', v_pronto, 'data_pronto_texto', v_pronto_txt, 'dia_semana', dias[v_dow + 1],
    'inicio_contagem', v_inicio, 'pagar_ate_hora', pr.corte_producao_hora,
    'depende_da_arte', not p_arte_aprovada,
    'retirada_abre', v_expediente ->> 'abre', 'retirada_fecha', v_expediente ->> 'fecha',
    'frase', v_frase);
end;
$$;

-- ---------------------------------------------------------------- 3. verificar_frete
create or replace function public.verificar_frete(p_cep_ou_bairro text, p_itens jsonb default '[]'::jsonb, p_valor_pedido numeric default 0, p_pacote_arte boolean default false)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_txt text := coalesce(p_cep_ou_bairro, '');
  v_cep text := regexp_replace(coalesce(p_cep_ou_bairro, ''), '\D', '', 'g');
  v_zona boolean := false;
  v_origem text;
  it jsonb; prod record; nums numeric[];
  v_peso numeric := 0; v_lado numeric := 0; v_desconhecido boolean := false; v_qtd integer;
  v_cabe boolean; v_elegivel_tamanho boolean; v_minimo_ok boolean; v_gratis boolean;
  v_motivo text; v_opcoes jsonb := '[]'::jsonb;
begin
  select * into pr from public.parametros_comerciais where id = 1;

  if v_txt ~ '^\s*\d{5}-?\d{3}\s*$' then
    v_origem := 'cep';
    v_zona := exists (select 1 from public.zonas_frete_gratis z where z.ativo and z.tipo = 'cep' and v_cep between z.cep_inicio and z.cep_fim);
  else
    v_origem := 'bairro';
    v_zona := exists (select 1 from public.zonas_frete_gratis z
                      where z.ativo and z.tipo = 'bairro'
                        and private.norm_txt(z.bairro) = regexp_replace(private.norm_txt(v_txt), '^bairro ', ''));
  end if;

  for it in select * from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) loop
    select p.weight, p.size into prod from public.products p where p.code = it ->> 'sku';
    if not found then return jsonb_build_object('ok', false, 'erro', 'sku_nao_encontrado', 'sku', it ->> 'sku'); end if;
    v_qtd := greatest(coalesce((it ->> 'quantidade')::integer, 1), 1);
    v_peso := v_peso + coalesce(prod.weight, 0) * v_qtd;
    nums := array(select replace((regexp_matches(coalesce(prod.size, ''), '\d+(?:[.,]\d+)?', 'g'))[1], ',', '.')::numeric);
    if prod.weight is null or cardinality(nums) = 0 then
      v_desconhecido := true;
    else
      v_lado := greatest(v_lado, (select max(n) from unnest(nums) n));
    end if;
  end loop;

  v_cabe := not v_desconhecido and v_peso <= pr.peso_max_bike_g and v_lado <= pr.lado_max_bike_mm;
  v_elegivel_tamanho := (not pr.exigir_cabe_na_bike) or v_cabe;
  v_minimo_ok := coalesce(p_pacote_arte, false) or coalesce(p_valor_pedido, 0) >= pr.pedido_minimo_frete_gratis;
  v_gratis := v_zona and v_elegivel_tamanho and v_minimo_ok;
  v_motivo := case
    when v_gratis then 'frete_gratis_regiao_central'
    when not v_zona then 'fora_da_regiao_central'
    when not v_elegivel_tamanho then case when v_desconhecido then 'dimensao_desconhecida' else 'nao_cabe_na_bike' end
    else 'abaixo_do_pedido_minimo' end;

  v_opcoes := jsonb_build_array(jsonb_build_object('tipo', 'retirada', 'valor_cliente', 0, 'obs', 'retirada grátis no centro de BH'));
  if v_gratis then
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('tipo', 'bike', 'valor_cliente', 0, 'obs', 'entrega grátis de bicicleta, em horário comercial'));
  else
    v_opcoes := v_opcoes || jsonb_build_array(jsonb_build_object('tipo', 'uber', 'valor_cliente', pr.custo_entrega_uber, 'obs', 'Uber Entrega por conta do cliente (valor de referência)'));
  end if;

  return jsonb_build_object(
    'ok', true, 'origem_consulta', v_origem, 'regiao_central', v_zona,
    'cabe_na_bike', v_cabe, 'peso_total_g', v_peso, 'maior_lado_mm', v_lado, 'dimensao_desconhecida', v_desconhecido,
    'pedido_minimo', pr.pedido_minimo_frete_gratis, 'pedido_minimo_atingido', v_minimo_ok, 'pacote_arte', coalesce(p_pacote_arte, false),
    'falta_para_frete_gratis', case when v_minimo_ok then 0 else greatest(pr.pedido_minimo_frete_gratis - coalesce(p_valor_pedido, 0), 0) end,
    'frete_gratis', v_gratis,
    'valor_frete_cliente', case when v_gratis then 0 else pr.custo_entrega_uber end,
    'frete_estimado', not v_gratis,
    'custo_entrega_nosso', case when v_gratis then pr.custo_entrega_bike else 0 end,
    'entrega_sugerida', case when v_gratis then 'bike' else 'uber' end,
    'saidas_bike_por_dia', pr.saidas_bike_por_dia,
    'motivo', v_motivo, 'opcoes', v_opcoes);
end;
$$;

-- ---------------------------------------------------------------- 4. validar_margem
create or replace function public.validar_margem(p_orcamento uuid)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  o public.orcamentos%rowtype;
  pr public.parametros_comerciais%rowtype;
  f jsonb;
  v_maxpct numeric;
  v_motivos text[] := '{}';
  v_alt text := null;
  v_lucro numeric; v_receita numeric;
  v_item_piso_duro boolean; v_item_piso boolean;
  v_cond record;
  v_aprovado boolean;
begin
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return jsonb_build_object('status', 'bloqueado', 'motivo', 'orcamento_nao_encontrado'); end if;
  select * into pr from public.parametros_comerciais where id = 1;
  f := private.orcamento_financeiro(p_orcamento);
  v_aprovado := o.aprovado_dono_em is not null;
  v_lucro := (f ->> 'lucro')::numeric;
  v_receita := (f ->> 'receita')::numeric;

  if (f ->> 'itens')::integer = 0 then
    return jsonb_build_object('status', 'bloqueado', 'motivo', 'orcamento_sem_itens', 'motivos', jsonb_build_array('orcamento_sem_itens'),
                              'alternativa', 'Adicione ao menos um item com SKU ao orçamento.');
  end if;
  if (f ->> 'itens_sem_produto')::integer > 0 then
    v_motivos := array_append(v_motivos, 'item_sem_sku_valido');
  end if;

  select coalesce(bool_or(i.quantidade * i.preco_unitario * (1 - pr.imposto_pct / 100 - (private.taxa_pagamento(o.metodo_previsto) ->> 'pct')::numeric / 100) < p.cost * i.quantidade), false),
         coalesce(bool_or(i.quantidade * i.preco_unitario < p.cost * i.quantidade * pr.multiplicador_piso), false)
    into v_item_piso_duro, v_item_piso
  from public.orcamento_itens i join public.products p on p.code = i.sku
  where i.orcamento_id = p_orcamento;

  -- sem aprovação possível
  if v_item_piso_duro then v_motivos := array_append(v_motivos, 'item_abaixo_do_piso_duro'); end if;
  if v_lucro < 0 then v_motivos := array_append(v_motivos, 'prejuizo'); end if;
  -- aprovável pelo dono (entre o piso_duro e o piso)
  if not v_aprovado then
    if v_item_piso then v_motivos := array_append(v_motivos, 'item_abaixo_do_piso'); end if;
    if (f ->> 'receita_itens_liquida')::numeric < (f ->> 'custo')::numeric * pr.multiplicador_piso then
      v_motivos := array_append(v_motivos, 'conjunto_abaixo_do_piso');
    end if;
    if v_lucro >= 0 and v_lucro < pr.lucro_liquido_minimo then v_motivos := array_append(v_motivos, 'lucro_abaixo_do_minimo'); end if;
  end if;

  -- política de desconto: só com condição especial vigente, dentro do valor concedido e do teto percentual
  if o.desconto_valor > 0 then
    select max(percentual) into v_maxpct from public.politica_desconto where tipo = 'desconto' and ativo;
    select c.valor into v_cond from public.condicoes_especiais c
      where c.orcamento_id = o.id and c.tipo = 'desconto' and c.resultado in ('oferecida', 'aceita') and c.valida_ate > now()
      order by c.criado_em desc limit 1;
    if not found then
      v_motivos := array_append(v_motivos, 'desconto_sem_condicao_especial');
    elsif o.desconto_valor > v_cond.valor + 0.005 then
      v_motivos := array_append(v_motivos, 'desconto_acima_do_teto');
    end if;
    if (f ->> 'subtotal')::numeric > 0 and o.desconto_valor / (f ->> 'subtotal')::numeric * 100 > coalesce(v_maxpct, 10) + 0.005 then
      v_motivos := array_append(v_motivos, 'desconto_acima_do_percentual_maximo');
    end if;
  end if;

  if cardinality(v_motivos) > 0 then
    v_alt := case
      when v_motivos && array['desconto_sem_condicao_especial', 'desconto_acima_do_teto', 'desconto_acima_do_percentual_maximo']
        then 'Remover o desconto ou usar a condição especial calculada pela função.'
      when v_motivos && array['item_sem_sku_valido'] then 'Trocar o item por um SKU existente no catálogo.'
      else format('Subir o total para pelo menos %s ou simplificar a especificação.', private.brl((f ->> 'receita_piso')::numeric))
      end;
    return jsonb_build_object('status', 'bloqueado', 'motivo', v_motivos[1], 'motivos', to_jsonb(v_motivos), 'alternativa', v_alt,
                              'lucro_liquido', v_lucro, 'receita', v_receita, 'receita_minima', (f ->> 'receita_piso')::numeric,
                              'receita_piso_duro', (f ->> 'receita_piso_duro')::numeric);
  end if;
  return jsonb_build_object('status', 'ok', 'lucro_liquido', v_lucro, 'receita', v_receita,
                            'margem_liquida_pct', round(v_lucro / nullif(v_receita, 0) * 100, 1),
                            'aprovado_pelo_dono', v_aprovado);
end;
$$;

-- ---------------------------------------------------------------- 5. calcular_condicao_especial
create or replace function public.calcular_condicao_especial(p_orcamento uuid, p_gatilho text, p_registrar boolean default true)
returns jsonb
language plpgsql set search_path = ''
as $$
declare
  o public.orcamentos%rowtype;
  pr public.parametros_comerciais%rowtype;
  pol public.politica_desconto%rowtype;
  f jsonb; fr jsonb;
  v_custo numeric; v_receita_atual numeric; v_extra numeric; v_extra_bike numeric; v_piso numeric;
  v_gordura numeric; v_base_elegivel numeric; v_cap numeric; v_valor numeric;
  v_tipo text; v_texto text; v_motivo text := 'sem_vantagem_aplicavel';
  v_itens jsonb; v_valida timestamptz; v_id uuid;
  v_outros integer; v_cacador integer; v_max_cond smallint; v_intervalo smallint;
begin
  select * into o from public.orcamentos where id = p_orcamento;
  if not found then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_nao_encontrado'); end if;
  if p_gatilho not in ('G1', 'G2', 'G3') then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'gatilho_invalido'); end if;
  if o.status = 'rascunho' then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_ainda_nao_enviado'); end if;
  if o.status not in ('enviado', 'aceito') then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_encerrado'); end if;
  select * into pr from public.parametros_comerciais where id = 1;

  select min(max_condicoes_por_orcamento), min(intervalo_dias_contato) into v_max_cond, v_intervalo from public.politica_desconto where ativo;
  if v_max_cond is null then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'politica_desligada'); end if;

  if (select count(*) from public.condicoes_especiais c where c.orcamento_id = o.id and c.resultado <> 'cancelada') >= v_max_cond then
    return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'ja_houve_condicao_neste_orcamento');
  end if;
  if exists (select 1 from public.condicoes_especiais c
             where c.contact_id = o.contact_id and c.orcamento_id <> o.id and c.resultado <> 'cancelada'
               and c.criado_em > now() - make_interval(days => v_intervalo)) then
    return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'intervalo_entre_condicoes_do_contato');
  end if;
  select count(*) into v_cacador from public.orcamentos x
    where x.contact_id = o.contact_id and x.id <> o.id and x.criado_em > now() - make_interval(days => pr.cacador_janela_dias)
      and x.status <> 'rascunho' and not x.teste;
  if v_cacador + 1 >= pr.cacador_min_orcamentos
     and not exists (select 1 from public.orcamentos x where x.contact_id = o.contact_id and x.status = 'pago') then
    return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'cacador_de_desconto', 'sinalizar_dono', true);
  end if;

  f := private.orcamento_financeiro(o.id);
  if (f ->> 'itens')::integer = 0 then return jsonb_build_object('tipo', 'sem_condicao', 'motivo', 'orcamento_sem_itens'); end if;
  v_custo := (f ->> 'custo')::numeric;
  v_receita_atual := (f ->> 'subtotal')::numeric + o.arte_valor + o.frete_valor;
  v_extra := (f ->> 'extra')::numeric;
  v_piso := ceil(greatest(v_custo * pr.multiplicador_piso, private.receita_para_lucro(v_custo, v_extra, pr.lucro_liquido_minimo, o.metodo_previsto)) * 100) / 100;
  v_gordura := greatest(v_receita_atual - v_piso, 0);

  -- G1 e G2: vantagem sem custo (degrau 1) e, se não houver, desconto do degrau 2. G3: degrau 3 e, se não couber, a vantagem.
  for pol in
    select * from public.politica_desconto d
    where d.ativo and (p_gatilho = any (d.gatilhos) or (p_gatilho = 'G3' and d.degrau = 1))
    order by case when p_gatilho = 'G3' then (case d.degrau when 3 then 0 else 1 end) else d.degrau end
  loop
    v_tipo := null; v_valor := 0;

    if pol.tipo = 'vantagem' then
      -- frete grátis sem pedido mínimo: região central, cabe na bike, frete hoje cobrado do cliente
      select coalesce(jsonb_agg(jsonb_build_object('sku', i.sku, 'quantidade', i.quantidade)), '[]'::jsonb) into v_itens
        from public.orcamento_itens i where i.orcamento_id = o.id;
      fr := public.verificar_frete(coalesce(o.cep, o.bairro), v_itens, (f ->> 'subtotal')::numeric, false);
      v_extra_bike := private.custos_operacionais('bike');
      if o.frete_valor > 0 and (fr ->> 'regiao_central')::boolean and ((not pr.exigir_cabe_na_bike) or (fr ->> 'cabe_na_bike')::boolean)
         and (v_receita_atual - o.frete_valor) >= ceil(greatest(v_custo * pr.multiplicador_piso, private.receita_para_lucro(v_custo, v_extra_bike, pr.lucro_liquido_minimo, o.metodo_previsto)) * 100) / 100 then
        v_tipo := 'frete_gratis'; v_valor := o.frete_valor; v_texto := 'frete grátis, sem pedido mínimo';
      elsif o.arte_modo = 'paga' and o.arte_valor > 0 and (v_receita_atual - o.arte_valor) >= v_piso then
        v_tipo := 'arte_gratis'; v_valor := o.arte_valor; v_texto := 'criação da arte grátis';
      end if;
    else
      -- desconto: só sobre itens que permitem desconto, limitado pela gordura acima do piso e pelo teto em reais
      select coalesce(sum(i.quantidade * i.preco_unitario) filter (
               where p.permite_desconto and not (coalesce(p.category, '') = any (pr.categorias_sem_desconto))), 0)
        into v_base_elegivel
        from public.orcamento_itens i join public.products p on p.code = i.sku where i.orcamento_id = o.id;
      if v_base_elegivel <= 0 then
        v_motivo := 'itens_sem_permissao_de_desconto';
      elsif v_gordura <= 0 then
        v_motivo := 'sem_gordura_acima_do_piso';
      else
        v_cap := floor(least(v_base_elegivel * pol.percentual / 100, v_gordura * pol.fracao_gordura_max, pol.desconto_max_reais) * 100) / 100;
        if v_cap < pol.valor_minimo_reais then
          v_motivo := 'desconto_menor_que_o_minimo';
        else
          v_tipo := 'desconto'; v_valor := v_cap; v_texto := 'desconto de ' || private.brl(v_cap);
        end if;
      end if;
    end if;

    if v_tipo is not null then
      v_valida := now() + make_interval(hours => pol.validade_horas);
      if p_registrar then
        insert into public.condicoes_especiais (orcamento_id, contact_id, degrau, gatilho, tipo, valor, texto_curto, valida_ate)
        values (o.id, o.contact_id, pol.degrau, p_gatilho, v_tipo, v_valor, v_texto, v_valida) returning id into v_id;
      end if;
      return jsonb_build_object('tipo', v_tipo, 'texto_curto', v_texto, 'valor', v_valor, 'valida_ate', v_valida, 'degrau', pol.degrau, 'condicao_id', v_id);
    end if;
  end loop;

  return jsonb_build_object('tipo', 'sem_condicao', 'motivo', v_motivo);
end;
$$;

-- Permissões: só o dono (RLS) e a service role chamam. O anon não.
do $$
declare f text;
begin
  foreach f in array array[
    'public.calcular_preco(text,integer,jsonb)', 'public.calcular_prazo(text,timestamptz,boolean)',
    'public.verificar_frete(text,jsonb,numeric,boolean)', 'public.validar_margem(uuid)',
    'public.calcular_condicao_especial(uuid,text,boolean)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

-- Agente de IA, Etapa 1 (4/4): travas de lucro no banco, prazo com corte das 12h e sincronia do prazo de logística.
-- Nenhum caminho (agente, automação, CRM, importação) grava preço com lucro líquido negativo.
-- Pagamento confirmado NUNCA é bloqueado por estas travas: elas olham só preço e desconto, não o status do pagamento.

-- Item de orçamento: SKU existente e preço acima do piso_duro do item (custo + imposto + taxa do método do piso)
create or replace function private.orcamento_itens_validar() returns trigger
language plpgsql set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_cost numeric;
  v_pct numeric;
begin
  if new.sku is null or btrim(new.sku) = '' then
    raise exception 'Item sem SKU não pode entrar no orçamento.' using errcode = 'P0001';
  end if;
  select p.cost into v_cost from public.products p where p.code = new.sku;
  if not found then
    raise exception 'SKU % não existe no catálogo.', new.sku using errcode = 'P0001';
  end if;
  select * into pr from public.parametros_comerciais where id = 1;
  v_pct := (private.taxa_pagamento(null) ->> 'pct')::numeric;
  if new.preco_unitario * new.quantidade * (1 - pr.imposto_pct / 100 - v_pct / 100) < v_cost * new.quantidade then
    raise exception 'Preço abaixo do piso duro: o item daria prejuízo. Ajuste o preço.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke execute on function private.orcamento_itens_validar() from public, anon, authenticated;
drop trigger if exists orcamento_itens_validar on public.orcamento_itens;
create trigger orcamento_itens_validar before insert or update on public.orcamento_itens
  for each row execute function private.orcamento_itens_validar();

-- Subtotal do orçamento acompanha os itens
create or replace function private.orcamento_itens_recalcular() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_id uuid := coalesce(new.orcamento_id, old.orcamento_id);
begin
  update public.orcamentos o
     set subtotal = coalesce((select sum(i.quantidade * i.preco_unitario) from public.orcamento_itens i where i.orcamento_id = v_id), 0)
   where o.id = v_id;
  return null;
end;
$$;
revoke execute on function private.orcamento_itens_recalcular() from public, anon, authenticated;
drop trigger if exists orcamento_itens_recalcular on public.orcamento_itens;
create trigger orcamento_itens_recalcular after insert or update or delete on public.orcamento_itens
  for each row execute function private.orcamento_itens_recalcular();

-- Orçamento: total consistente, validade padrão e recusa de prejuízo ao sair do rascunho ou quando o total muda
create or replace function private.orcamentos_validar() returns trigger
language plpgsql set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  f jsonb;
begin
  new.total := new.subtotal + new.arte_valor + new.frete_valor - new.desconto_valor;
  new.atualizado_em := now();
  select * into pr from public.parametros_comerciais where id = 1;
  if new.status = 'enviado' and new.validade_ate is null then
    new.validade_ate := now() + make_interval(days => pr.validade_orcamento_dias);
  end if;
  if tg_op = 'UPDATE' and new.status in ('enviado', 'aceito', 'pago')
     and (old.status = 'rascunho' or new.subtotal is distinct from old.subtotal or new.total is distinct from old.total
          or new.desconto_valor is distinct from old.desconto_valor or new.frete_valor is distinct from old.frete_valor) then
    -- o cálculo usa os itens gravados; subtotal e desconto novos entram pela própria linha
    f := private.orcamento_financeiro(new.id);
    if (f ->> 'itens')::integer = 0 and old.status = 'rascunho' then
      raise exception 'Orçamento sem itens não pode ser enviado.' using errcode = 'P0001';
    end if;
    if (f ->> 'itens')::integer > 0
       and private.lucro(new.subtotal - new.desconto_valor + new.arte_valor + new.frete_valor, (f ->> 'custo')::numeric, (f ->> 'extra')::numeric, new.metodo_previsto) < 0 then
      raise exception 'Orçamento recusado: o preço total daria prejuízo (abaixo do piso duro).' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function private.orcamentos_validar() from public, anon, authenticated;
drop trigger if exists orcamentos_validar on public.orcamentos;
create trigger orcamentos_validar before insert or update on public.orcamentos
  for each row execute function private.orcamentos_validar();

-- Item de pedido: preço abaixo do piso duro é recusado; SKU obrigatório quando exigir_sku_pedidos estiver ligado (Etapa 2)
create or replace function private.order_items_validar() returns trigger
language plpgsql set search_path = ''
as $$
declare
  pr public.parametros_comerciais%rowtype;
  v_pct numeric;
begin
  select * into pr from public.parametros_comerciais where id = 1;
  if pr.exigir_sku_pedidos and tg_op = 'INSERT' and (new.code is null or btrim(new.code) = '') then
    raise exception 'Item sem SKU não pode entrar no pedido.' using errcode = 'P0001';
  end if;
  if tg_op = 'INSERT' or new.unit_price is distinct from old.unit_price or new.unit_cost is distinct from old.unit_cost or new.qty is distinct from old.qty then
    v_pct := (private.taxa_pagamento(null) ->> 'pct')::numeric;
    if new.unit_cost > 0 and new.unit_price * (1 - pr.imposto_pct / 100 - v_pct / 100) < new.unit_cost then
      raise exception 'Preço abaixo do piso duro (%): o item daria prejuízo.', private.brl(round(new.unit_cost / (1 - pr.imposto_pct / 100 - v_pct / 100), 2))
        using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function private.order_items_validar() from public, anon, authenticated;
drop trigger if exists order_items_validar on public.order_items;
create trigger order_items_validar before insert or update on public.order_items
  for each row execute function private.order_items_validar();

-- Pedido: desconto ou taxas editados à mão não podem levar o total para prejuízo (só quando esses campos mudam; pagamento não passa por aqui)
create or replace function private.orders_validar_desconto() returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_gross numeric; v_cost numeric;
begin
  select coalesce(sum(qty * unit_price), 0), coalesce(sum(qty * unit_cost), 0) into v_gross, v_cost from public.order_items where order_id = new.id;
  if v_gross > 0 and v_cost > 0
     and round(v_gross * (1 - new.discount_pct / 100) * (1 - (new.tax_pct + new.payment_fee_pct) / 100), 2) < v_cost then
    raise exception 'Desconto recusado: o pedido daria prejuízo (abaixo do piso duro).' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke execute on function private.orders_validar_desconto() from public, anon, authenticated;
drop trigger if exists orders_validar_desconto on public.orders;
create trigger orders_validar_desconto before update of discount_pct, tax_pct, payment_fee_pct on public.orders
  for each row when (new.discount_pct is distinct from old.discount_pct or new.tax_pct is distinct from old.tax_pct or new.payment_fee_pct is distinct from old.payment_fee_pct)
  execute function private.orders_validar_desconto();

-- Prazo do pedido: marco inicial = pagamento confirmado E arte aprovada, com corte das 12h e dia de logística (calcular_prazo)
-- Antes da arte aprovada vale a estimativa pelo momento do pagamento; ao aprovar a arte a data é recalculada.
create or replace function private.orders_set_due_date() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_paid timestamptz := coalesce(new.payment_confirmed_at, case when new.payment_status = 'aprovado' then now() end);
begin
  if v_paid is not null and new.lead_days is not null and not new.due_date_manual then
    new.due_date := private.prazo_data(new.lead_days, greatest(v_paid, coalesce(new.art_approved_at, v_paid)));
  end if;
  return new;
end;
$$;

-- A tela Configurações > Prazos grava app_settings.deadline.extra_days; o valor segue para os parâmetros comerciais
create or replace function private.sync_prazo_logistica() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.key = 'deadline' and (new.value ->> 'extra_days') ~ '^[0-9]+$' then
    update public.parametros_comerciais set dias_logistica = (new.value ->> 'extra_days')::smallint where id = 1;
  end if;
  return new;
end;
$$;
revoke execute on function private.sync_prazo_logistica() from public, anon, authenticated;
drop trigger if exists app_settings_sync_prazo on public.app_settings;
create trigger app_settings_sync_prazo after insert or update on public.app_settings
  for each row execute function private.sync_prazo_logistica();
update public.parametros_comerciais set dias_logistica = coalesce((select (value ->> 'extra_days')::smallint from public.app_settings where key = 'deadline'), 1) where id = 1;
