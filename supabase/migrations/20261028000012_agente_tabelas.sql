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
