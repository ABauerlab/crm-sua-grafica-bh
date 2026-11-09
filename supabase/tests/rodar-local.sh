#!/usr/bin/env bash
# Sobe um Postgres 16 descartável, simula o básico do Supabase (roles, auth, storage, cron, vault) e aplica as migrations.
# pgvector não existe no Postgres local: vector(n) vira float4[] e o índice HNSW é ignorado (a busca vetorial só é testada em produção).
# Uso: supabase/tests/rodar-local.sh [arquivo.sql ...]   (os arquivos são executados depois das migrations)
set -euo pipefail
# EXTRA_SEED=arquivo.sql  carrega linhas extras antes da Etapa 2 (ex.: 20 mil linhas para medir o tempo da migration)
cd "$(dirname "$0")/../.."
PGBIN=/usr/lib/postgresql/16/bin
DIR="${LOCAL_PG_DIR:-/tmp/gbh-pg}"
PORT="${LOCAL_PG_PORT:-54329}"
if [ ! -d "$DIR/data" ]; then
  mkdir -p "$DIR"; chown -R postgres "$DIR" 2>/dev/null || true
  su postgres -c "$PGBIN/initdb -D $DIR/data -A trust >/dev/null"
fi
su postgres -c "$PGBIN/pg_ctl -D $DIR/data -o '-p $PORT -k /tmp' -l $DIR/log -w restart >/dev/null"
P="psql -h /tmp -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "drop database if exists gbh" -c "create database gbh"
P="$P -d gbh"
# igual ao Supabase: o role postgres enxerga o schema extensions sem prefixo (ex.: gin_trgm_ops)
$P -c "alter role postgres in database gbh set search_path = \"\$user\", public, extensions"
$P <<'SQL'
do $$ begin
  create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
exception when duplicate_object then null; end $$;
create schema extensions; create schema auth; create schema storage; create schema cron; create schema net; create schema vault; create schema realtime;
create extension pg_trgm with schema extensions; create extension unaccent with schema extensions;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
create function auth.uid() returns uuid language sql stable as $f$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;
create function auth.role() returns text language sql stable as $f$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'anon') $f$;
create function auth.jwt() returns jsonb language sql stable as $f$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $f$;
create table storage.buckets (id text primary key, name text, public boolean default false);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table storage.objects enable row level security;
create table cron.job (jobid serial, jobname text);
create function cron.schedule(a text, b text, c text) returns bigint language sql as $f$ select 1::bigint $f$;
create function cron.unschedule(a text) returns boolean language sql as $f$ select true $f$;
create function net.http_post(url text, headers jsonb default '{}', body jsonb default '{}') returns bigint language sql as $f$ select 1::bigint $f$;
create table vault.decrypted_secrets (name text, decrypted_secret text);
create publication supabase_realtime;
-- função do Supabase gerenciado (event trigger ensure_rls em produção); stub só para as migrations que mexem nas permissões dela
create function public.rls_auto_enable() returns event_trigger language plpgsql as $f$ begin null; end $f$;
grant usage on schema public, extensions, auth, storage to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
-- vetor falso para os testes locais: operador <=> = distância de cosseno
create function extensions.cos_dist(a float4[], b float4[]) returns float8 language sql immutable as $f$
  select 1 - coalesce(sum(x * y) / nullif(sqrt(sum(x * x)) * sqrt(sum(y * y)), 0), 0)
  from unnest(a, b) as t(x, y) $f$;
create operator extensions.<=> (leftarg = float4[], rightarg = float4[], function = extensions.cos_dist);
SQL
for f in supabase/migrations/*.sql; do
  # catálogo de teste (fictício) entra antes da Etapa 2, como os 20 mil itens de produção já estavam
  if [[ "$f" == *20261029000001* && -f supabase/tests/seed-catalogo.sql ]]; then $P -f supabase/tests/seed-catalogo.sql >/dev/null; [ -n "${EXTRA_SEED:-}" ] && $P -f "$EXTRA_SEED" >/dev/null; fi
  sed -E -e 's/create extension if not exists (pg_cron|pg_net|vector)[^;]*;//' \
         -e 's/extensions\.vector\([0-9]+\)/float4[]/g' -e 's/extensions\.vector\b/float4[]/g' \
         -e '/using hnsw/d' "$f" | $P >/dev/null 2>"$DIR/err.txt" || { echo "FALHOU: $f"; cat "$DIR/err.txt"; exit 1; }
done
echo "migrations aplicadas"
for f in "$@"; do echo "== $f"; $P -f "$f" 2>&1 | tail -5 || true; done
