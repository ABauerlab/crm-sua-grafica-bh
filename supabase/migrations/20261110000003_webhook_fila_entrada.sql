-- Fila de entrada do webhook da Meta: o evento bruto é gravado antes de responder 200, e o processamento roda em
-- segundo plano. Se o processamento falhar, o evento fica pendente e é reprocessado pelo próprio webhook.
-- Só o service role lê e escreve (RLS ligado, sem políticas). Aditiva e idempotente.

create table if not exists public.webhook_eventos (
  id uuid primary key default gen_random_uuid(),
  hash text not null unique,
  payload jsonb not null,
  recebido_em timestamptz not null default now(),
  processado_em timestamptz,
  tentativas integer not null default 0,
  ultimo_erro text
);

create index if not exists webhook_eventos_pendentes_idx on public.webhook_eventos (recebido_em) where processado_em is null;

alter table public.webhook_eventos enable row level security;
revoke all on public.webhook_eventos from anon, authenticated;
grant all on public.webhook_eventos to service_role;
