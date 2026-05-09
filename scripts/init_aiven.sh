#!/usr/bin/env bash
#
# scripts/init_aiven.sh — production-ready Aiven Postgres initialiser.
#
# CREDENTIALS POLICY
#   Never embeds, prints, or commits credentials. Provide them at runtime:
#
#   1. Interactive (recommended for one-offs):
#        bash scripts/init_aiven.sh
#        # prompts for host/port/db/user/password (hidden input)
#
#   2. Env vars (use for CI; do not commit the file you sourced from):
#        AIVEN_HOST=… AIVEN_PORT=… AIVEN_DB=… AIVEN_USER=… AIVEN_PASSWORD=… \
#          bash scripts/init_aiven.sh
#
#   3. Full URL via env:
#        AIVEN_URL='postgres://user:pw@host:port/db?sslmode=require' bash scripts/init_aiven.sh
#
#   4. ~/.pgpass (libpq standard; password never appears in the URL):
#        echo 'host:port:db:user:password' >> ~/.pgpass && chmod 600 ~/.pgpass
#        AIVEN_URL='postgres://user@host:port/db?sslmode=require' bash scripts/init_aiven.sh
#
#   5. First positional arg as URL (DISCOURAGED — leaks via `ps`/history):
#        bash scripts/init_aiven.sh 'postgres://user:pw@host/db?sslmode=require'
#
# What it does (idempotent, safe to re-run):
#   1. TLS + version probe
#   2. Extensions:  uuid-ossp, pgcrypto, pg_trgm   (and pgvector if ENABLE_VECTOR=1)
#   3. Schema:      entity, remote, embedding_chunk        (matches Alembic)
#   4. Triggers:    auto-bump updated_at on entity / embedding_chunk
#   5. Indexes:     standard + pg_trgm GIN on name/summary
#   6. Seed remote: optional, default ON
#   7. Sanity:      \dt, \dx, row counts
#   8. Prints DATABASE_URL_PRIMARY (password masked unless PRINT_SECRET=1)
#
# Knobs:
#   ENABLE_VECTOR=1    also CREATE EXTENSION vector
#   SEED_REMOTES=0     skip seeding the canonical catalog remote
#   STRICT=1           fail on any extension warning
#   PRINT_SECRET=1     print the URL with the password un-masked

set -Eeuo pipefail

ENABLE_VECTOR="${ENABLE_VECTOR:-0}"
SEED_REMOTES="${SEED_REMOTES:-1}"
STRICT="${STRICT:-0}"
PRINT_SECRET="${PRINT_SECRET:-0}"

bold(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
info(){ printf '    %s\n' "$*"; }
hr()  { printf '%.0s-' {1..72}; printf '\n'; }
step(){ printf '\n'; bold "▶ $*"; hr; }
mask_url() { echo "$1" | sed -E 's#(://[^:]+:)[^@]+(@)#\1***\2#; s#(://[^@]+@)#\1#'; }
urlencode() { python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

build_url_from_parts() {
  local user="$1" pw="$2" host="$3" port="$4" db="$5"
  local enc_pw=""
  [ -n "$pw" ] && enc_pw=":$(urlencode "$pw")"
  printf 'postgresql://%s%s@%s:%s/%s?sslmode=require\n' "$user" "$enc_pw" "$host" "$port" "$db"
}

URL=""
if [ -n "${AIVEN_URL:-}" ]; then
  URL="$AIVEN_URL"
elif [ -n "${1:-}" ]; then
  URL="$1"
elif [ -n "${AIVEN_HOST:-}" ] && [ -n "${AIVEN_USER:-}" ] && [ -n "${AIVEN_DB:-}" ]; then
  URL="$(build_url_from_parts \
          "${AIVEN_USER}" "${AIVEN_PASSWORD:-}" \
          "${AIVEN_HOST}" "${AIVEN_PORT:-5432}" \
          "${AIVEN_DB}")"
else
  bold "▶ No URL/env provided — interactive setup"
  read -r -p   "  Host (e.g. pg-xxx.aivencloud.com): " AIVEN_HOST
  read -r -p   "  Port [24870]: " AIVEN_PORT; AIVEN_PORT="${AIVEN_PORT:-24870}"
  read -r -p   "  Database [defaultdb]: " AIVEN_DB; AIVEN_DB="${AIVEN_DB:-defaultdb}"
  read -r -p   "  User [avnadmin]: " AIVEN_USER; AIVEN_USER="${AIVEN_USER:-avnadmin}"
  read -r -s -p "  Password (hidden, leave empty to use ~/.pgpass): " AIVEN_PASSWORD; echo
  URL="$(build_url_from_parts "$AIVEN_USER" "$AIVEN_PASSWORD" "$AIVEN_HOST" "$AIVEN_PORT" "$AIVEN_DB")"
fi

to_libpq() { echo "$1" | sed -E 's#^postgresql\+(psycopg|asyncpg)://#postgresql://#; s#^postgres://#postgresql://#'; }
to_sqla()  { echo "$1" | sed -E 's#^postgres://#postgresql+psycopg://#; s#^postgresql://#postgresql+psycopg://#'; }
PSQL_URL="$(to_libpq "$URL")"
SQLA_URL="$(to_sqla  "$URL")"
case "$PSQL_URL" in *sslmode=*) :;; *) sep=$([[ $PSQL_URL == *\?* ]] && echo '&' || echo '?'); PSQL_URL="${PSQL_URL}${sep}sslmode=require"; SQLA_URL="${SQLA_URL}${sep}sslmode=require";; esac

command -v psql >/dev/null || { bad "psql not installed (sudo apt install postgresql-client / sudo dnf install postgresql)"; exit 1; }

bold "▶ Initialising Aiven for matrix-hub"
info "target: $(mask_url "$PSQL_URL")"

run_sql() { PGCONNECT_TIMEOUT=15 psql "$PSQL_URL" -v ON_ERROR_STOP=1 "$@"; }

step "1. Probe"
run_sql -c 'SELECT version(), current_database(), current_user, now();' | sed 's/^/    /'

step "2. Extensions"
for ext in 'uuid-ossp' 'pgcrypto' 'pg_trgm'; do
  if run_sql -c "CREATE EXTENSION IF NOT EXISTS \"$ext\";" >/dev/null; then
    ok "$ext"
  else
    if [ "$STRICT" = "1" ]; then bad "$ext FAILED (STRICT=1)"; exit 1; else warn "$ext failed — continuing"; fi
  fi
done
if [ "$ENABLE_VECTOR" = "1" ]; then
  if run_sql -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    ok "vector"
  else
    warn "vector not available on this Aiven plan — leave SEARCH_VECTOR_BACKEND=none"
  fi
fi

step "3. Schema (entity / remote / embedding_chunk)"
run_sql <<'SQL' | sed 's/^/    /'
CREATE TABLE IF NOT EXISTS entity (
  uid                   text PRIMARY KEY,
  type                  text NOT NULL CHECK (type in ('agent','tool','mcp_server')),
  name                  text NOT NULL,
  version               text NOT NULL,
  summary               text,
  description           text,
  license               text,
  homepage              text,
  source_url            text,
  tenant_id             text NOT NULL DEFAULT 'public',
  capabilities          jsonb NOT NULL DEFAULT '[]'::jsonb,
  frameworks            jsonb NOT NULL DEFAULT '[]'::jsonb,
  providers             jsonb NOT NULL DEFAULT '[]'::jsonb,
  readme_blob_ref       text,
  quality_score         double precision NOT NULL DEFAULT 0.0,
  release_ts            timestamptz,
  created_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at            timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  gateway_registered_at timestamptz,
  gateway_error         text,
  mcp_registration      jsonb
);

CREATE TABLE IF NOT EXISTS remote (
  url text PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS embedding_chunk (
  entity_uid      text NOT NULL REFERENCES entity(uid) ON DELETE CASCADE,
  chunk_id        text NOT NULL,
  vector          jsonb,
  caps_text       text,
  frameworks_text text,
  providers_text  text,
  quality_score   double precision,
  embed_model     text,
  raw_ref         text,
  updated_at      timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (entity_uid, chunk_id)
);

CREATE OR REPLACE FUNCTION matrixhub_set_updated_at()
RETURNS trigger AS $$
BEGIN NEW.updated_at = CURRENT_TIMESTAMP; RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_entity_updated_at ON entity;
CREATE TRIGGER trg_entity_updated_at
BEFORE UPDATE ON entity
FOR EACH ROW EXECUTE FUNCTION matrixhub_set_updated_at();

DROP TRIGGER IF EXISTS trg_embedding_chunk_updated_at ON embedding_chunk;
CREATE TRIGGER trg_embedding_chunk_updated_at
BEFORE UPDATE ON embedding_chunk
FOR EACH ROW EXECUTE FUNCTION matrixhub_set_updated_at();
SQL
ok "schema applied"

step "4. Indexes"
run_sql <<'SQL' | sed 's/^/    /'
CREATE INDEX IF NOT EXISTS ix_entity_type_name           ON entity (type, name);
CREATE INDEX IF NOT EXISTS ix_entity_created_at          ON entity (created_at);
CREATE INDEX IF NOT EXISTS ix_embedding_chunk_updated_at ON embedding_chunk (updated_at);
CREATE INDEX IF NOT EXISTS ix_entity_name_trgm           ON entity USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS ix_entity_summary_trgm        ON entity USING GIN (summary gin_trgm_ops);
SQL
ok "indexes applied"

step "5. Seed canonical remote"
if [ "$SEED_REMOTES" = "1" ]; then
  run_sql -c "INSERT INTO remote(url) VALUES ('https://raw.githubusercontent.com/agent-matrix/catalog/main/index.json') ON CONFLICT (url) DO NOTHING;"
  ok "seeded agent-matrix catalog remote"
else
  info "SEED_REMOTES=0 → skipping"
fi

step "6. Sanity"
echo "  Tables:";     run_sql -c "\dt public.*"                           | sed 's/^/    /'
echo "  Extensions:"; run_sql -tAc "SELECT extname||' '||extversion FROM pg_extension ORDER BY extname;" | sed 's/^/    /'
echo "  Row counts:"; run_sql -tAc "SELECT 'entity='||(SELECT count(*) FROM entity)||', remote='||(SELECT count(*) FROM remote)||', embedding_chunk='||(SELECT count(*) FROM embedding_chunk);" | sed 's/^/    /'

step "7. Ready"
ok "Aiven is initialised. matrix-hub will run its own Alembic migrations on first boot;"
info "since this script created the same tables Alembic creates, the migrations are no-ops."
info ""
info "Paste this into ~/matrix-hub/.env (DO NOT commit .env):"
echo
if [ "$PRINT_SECRET" = "1" ]; then
  printf '    DATABASE_URL_PRIMARY=%s\n'  "$SQLA_URL"
else
  printf '    DATABASE_URL_PRIMARY=%s\n'  "$(mask_url "$SQLA_URL")"
  info "(Password masked. Re-run with PRINT_SECRET=1 to print it un-masked,"
  info " or substitute it from your secret manager.)"
fi
echo
info "Optional fallback while OL9 is still alive:"
printf '    # DATABASE_URL_FALLBACK=postgresql+psycopg://matrix:OL9_PW@10.0.0.185:5432/matrixhub\n'
echo
info "Then on the Hub host:"
info "  docker stop matrixhub && docker rm matrixhub"
info "  bash scripts/run_container.sh"
info "  curl -ksS https://127.0.0.1:443/health?check_db=true   # expect db:\"ok\""

unset AIVEN_PASSWORD URL PSQL_URL SQLA_URL || true
bold "✓ init_aiven.sh complete"
