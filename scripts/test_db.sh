#!/usr/bin/env bash
#
# scripts/test_db.sh — end-to-end smoke test for the matrix-hub database.
#
# Validates the production schema, write/read/delete round-trip, triggers,
# pg_trgm indexes, and SQLAlchemy URL form. Works against any Postgres
# matrix-hub can target — the canonical use is the new Aiven service.
#
# CREDENTIALS POLICY
#   Never embeds, prints, or commits credentials. Pick one source:
#
#   1. ./.env on disk (preferred on the Hub VM):
#        TEST_DB_URL_VAR=DATABASE_URL_PRIMARY bash scripts/test_db.sh
#        # the script loads .env (un-committed) and reads the named var
#
#   2. Env vars (CI / local one-offs):
#        TEST_DB_URL='postgresql+psycopg://user:pw@host/db?sslmode=require' \
#          bash scripts/test_db.sh
#
#   3. ~/.pgpass + passwordless URL:
#        echo 'host:port:db:user:password' >> ~/.pgpass && chmod 600 ~/.pgpass
#        TEST_DB_URL='postgresql://user@host:port/db?sslmode=require' \
#          bash scripts/test_db.sh
#
#   4. Interactive prompt (last resort):
#        bash scripts/test_db.sh
#
# Knobs:
#   STRICT=1                   exit non-zero on the first warning
#   SKIP_WRITE=1               skip the INSERT / UPDATE / DELETE round-trip
#                              (useful against a production DB you don't want to mutate)
#   TEST_DB_URL_VAR=NAME       name of the env var to look up in .env (default DATABASE_URL_PRIMARY)
#   ENV_FILE=.env              path to the env file (default .env)

set -Eeuo pipefail

STRICT="${STRICT:-0}"
SKIP_WRITE="${SKIP_WRITE:-0}"
ENV_FILE="${ENV_FILE:-.env}"
TEST_DB_URL_VAR="${TEST_DB_URL_VAR:-DATABASE_URL_PRIMARY}"

bold(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASSES=$((PASSES+1)); }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; WARNS=$((WARNS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
info(){ printf '    %s\n' "$*"; }
hr()  { printf '%.0s-' {1..72}; printf '\n'; }
step(){ printf '\n'; bold "▶ $*"; hr; }
mask_url() { echo "$1" | sed -E 's#(://[^:]+:)[^@]+(@)#\1***\2#'; }
PASSES=0; WARNS=0; FAILS=0

# ---------- credential resolution ----------
URL="${TEST_DB_URL:-}"

if [ -z "$URL" ] && [ -f "$ENV_FILE" ]; then
  # Pull a single var out of .env without sourcing the whole file.
  URL="$(grep -E "^${TEST_DB_URL_VAR}=" "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r' | tr -d '"')"
  [ -n "$URL" ] && info "loaded ${TEST_DB_URL_VAR} from ${ENV_FILE}"
fi

# Final fallback: prompt
if [ -z "$URL" ]; then
  if [ ! -t 0 ]; then
    bad "no TEST_DB_URL set, no ${TEST_DB_URL_VAR} in ${ENV_FILE}, and stdin is not a TTY"
    exit 1
  fi
  read -r -p   "  Host                     : " H
  read -r -p   "  Port [24870]             : " P; P="${P:-24870}"
  read -r -p   "  Database [defaultdb]     : " D; D="${D:-defaultdb}"
  read -r -p   "  User [avnadmin]          : " U; U="${U:-avnadmin}"
  read -r -s -p "  Password (hidden)       : " PW; echo
  ENC_PW=""
  [ -n "$PW" ] && ENC_PW=":$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$PW")"
  URL="postgresql://${U}${ENC_PW}@${H}:${P}/${D}?sslmode=require"
fi

# Normalise to libpq for psql; record SQLAlchemy form for the report
PSQL_URL="$(echo "$URL" | sed -E 's#^postgresql\+(psycopg|asyncpg)://#postgresql://#; s#^postgres://#postgresql://#')"
SQLA_URL="$(echo "$URL" | sed -E 's#^postgres://#postgresql+psycopg://#; s#^postgresql://#postgresql+psycopg://#')"
case "$PSQL_URL" in *sslmode=*) :;; *) sep=$([[ $PSQL_URL == *\?* ]] && echo '&' || echo '?'); PSQL_URL="${PSQL_URL}${sep}sslmode=require";; esac

command -v psql >/dev/null || { bad "psql not installed (sudo apt install postgresql-client / sudo dnf install postgresql)"; exit 1; }

bold "▶ matrix-hub DB smoke test"
info "target: $(mask_url "$PSQL_URL")"
info "write tests: $([ "$SKIP_WRITE" = "1" ] && echo SKIPPED || echo enabled)"

run_sql() { PGCONNECT_TIMEOUT=10 psql "$PSQL_URL" -v ON_ERROR_STOP=1 -tAc "$1"; }

# ============================================================================
# 1. connectivity + version
# ============================================================================
step "1. Connectivity"
if VER="$(run_sql 'SELECT version();' 2>&1)"; then
  ok "connected: $(echo "$VER" | head -c 100)"
else
  bad "could not connect:"
  echo "$VER" | sed 's/^/      /'
  exit 1
fi

DBNAME="$(run_sql 'SELECT current_database();' 2>/dev/null || echo '?')"
DBUSER="$(run_sql 'SELECT current_user;'      2>/dev/null || echo '?')"
info "current_database=$DBNAME  current_user=$DBUSER"

# ============================================================================
# 2. extensions
# ============================================================================
step "2. Extensions"
EXTS="$(run_sql "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname IN ('uuid-ossp','pgcrypto','pg_trgm','vector');")"
for need in uuid-ossp pgcrypto pg_trgm; do
  if echo ",$EXTS," | grep -q ",${need},"; then ok "$need installed"; else bad "$need MISSING (run init_aiven.sh)"; fi
done
echo ",$EXTS," | grep -q ',vector,' && ok "vector installed (pgvector ready)" || warn "vector NOT installed — fine unless you flip SEARCH_VECTOR_BACKEND=pgvector"

# ============================================================================
# 3. tables + columns
# ============================================================================
step "3. Schema"
for t in entity remote embedding_chunk; do
  if [ "$(run_sql "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='$t';")" = "1" ]; then
    ok "table $t exists"
  else
    bad "table $t MISSING"
  fi
done

# Check a few critical columns
COLS="$(run_sql "SELECT string_agg(column_name, ',' ORDER BY column_name) FROM information_schema.columns WHERE table_name='entity';")"
for col in uid type name version capabilities frameworks providers tenant_id quality_score created_at updated_at mcp_registration; do
  echo ",$COLS," | grep -q ",${col}," && ok "entity.$col present" || bad "entity.$col MISSING"
done

# Check the type CHECK constraint
CONS="$(run_sql "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='public.entity'::regclass AND contype='c';" 2>/dev/null || echo "")"
if echo "$CONS" | grep -q "type.*= ANY.*agent.*tool.*mcp_server" || echo "$CONS" | grep -q "type IN ('agent','tool','mcp_server')"; then
  ok "entity.type CHECK constraint present"
else
  warn "entity.type CHECK constraint not detected (may use different syntax)"
fi

# ============================================================================
# 4. indexes
# ============================================================================
step "4. Indexes"
IDX="$(run_sql "SELECT string_agg(indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE schemaname='public';")"
for idx in ix_entity_type_name ix_entity_created_at ix_embedding_chunk_updated_at; do
  echo ",$IDX," | grep -q ",${idx}," && ok "$idx" || bad "$idx MISSING"
done
for idx in ix_entity_name_trgm ix_entity_summary_trgm; do
  echo ",$IDX," | grep -q ",${idx}," && ok "$idx (pg_trgm)" || warn "$idx missing — pg_trgm search will be slow"
done

# ============================================================================
# 5. triggers
# ============================================================================
step "5. Triggers"
TRG="$(run_sql "SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE NOT tgisinternal;")"
for t in trg_entity_updated_at trg_embedding_chunk_updated_at; do
  echo ",$TRG," | grep -q ",${t}," && ok "$t" || warn "$t missing — updated_at won't auto-bump"
done

# ============================================================================
# 6. seed
# ============================================================================
step "6. Seed"
REMOTE_COUNT="$(run_sql "SELECT count(*) FROM remote;")"
if [ "$REMOTE_COUNT" -ge 1 ]; then
  ok "remote table has $REMOTE_COUNT row(s)"
  run_sql "SELECT url FROM remote ORDER BY url LIMIT 5;" | sed 's/^/      /'
else
  warn "remote table is empty — matrix-hub won't ingest until a remote is seeded"
fi

# ============================================================================
# 7. write/read/delete round-trip
# ============================================================================
step "7. Round-trip"
if [ "$SKIP_WRITE" = "1" ]; then
  info "SKIP_WRITE=1 → skipping mutations"
else
  TEST_UID="test:smoke-$(date +%s)-$$"
  trap 'PGCONNECT_TIMEOUT=10 psql "$PSQL_URL" -v ON_ERROR_STOP=0 -c "DELETE FROM entity WHERE uid='\''${TEST_UID}'\'';" >/dev/null 2>&1 || true' EXIT
  run_sql "INSERT INTO entity (uid,type,name,version,summary) VALUES ('${TEST_UID}','tool','smoke-test','0.0.1','smoke test row, safe to delete');" >/dev/null \
    && ok "INSERT" || bad "INSERT failed"
  CREATED="$(run_sql "SELECT created_at FROM entity WHERE uid='${TEST_UID}';")"
  [ -n "$CREATED" ] && ok "READ (created_at=$CREATED)" || bad "READ failed"
  sleep 1
  run_sql "UPDATE entity SET summary='updated' WHERE uid='${TEST_UID}';" >/dev/null \
    && ok "UPDATE" || bad "UPDATE failed"
  UPDATED="$(run_sql "SELECT updated_at FROM entity WHERE uid='${TEST_UID}';")"
  if [ -n "$UPDATED" ] && [ "$UPDATED" != "$CREATED" ]; then
    ok "trigger bumped updated_at ($CREATED → $UPDATED)"
  else
    warn "updated_at did not change — auto-update trigger may be missing"
  fi
  # Insert+delete a child embedding_chunk to exercise the FK
  run_sql "INSERT INTO embedding_chunk (entity_uid,chunk_id,caps_text) VALUES ('${TEST_UID}','c1','x');" >/dev/null \
    && ok "INSERT child embedding_chunk" || bad "child INSERT failed"
  CHILDREN_BEFORE="$(run_sql "SELECT count(*) FROM embedding_chunk WHERE entity_uid='${TEST_UID}';")"
  run_sql "DELETE FROM entity WHERE uid='${TEST_UID}';" >/dev/null \
    && ok "DELETE parent" || bad "DELETE parent failed"
  CHILDREN_AFTER="$(run_sql "SELECT count(*) FROM embedding_chunk WHERE entity_uid='${TEST_UID}';")"
  if [ "$CHILDREN_BEFORE" = "1" ] && [ "$CHILDREN_AFTER" = "0" ]; then
    ok "ON DELETE CASCADE works (child cleaned up)"
  else
    bad "ON DELETE CASCADE broken (before=$CHILDREN_BEFORE after=$CHILDREN_AFTER)"
  fi
  trap - EXIT
fi

# ============================================================================
# 8. pg_trgm sanity (small functional test)
# ============================================================================
step "8. pg_trgm functional check"
if [ "$(run_sql "SELECT (similarity('matrixhub','matrix') > 0.3)::int;" 2>/dev/null)" = "1" ]; then
  ok "similarity() returns sensible scores"
else
  warn "pg_trgm.similarity() did not return as expected"
fi

# ============================================================================
# 9. SQLAlchemy URL hint
# ============================================================================
step "9. SQLAlchemy URL"
ok "use this in matrix-hub's .env (do NOT commit):"
info "  $(mask_url "$SQLA_URL")"

# ============================================================================
# summary
# ============================================================================
step "Summary"
printf "  passes : %d\n  warns  : %d\n  fails  : %d\n" "$PASSES" "$WARNS" "$FAILS"
if [ "$FAILS" -gt 0 ]; then
  bold "✗ DB smoke test FAILED"
  exit 1
fi
if [ "$STRICT" = "1" ] && [ "$WARNS" -gt 0 ]; then
  bold "✗ STRICT=1 + warnings → failing"
  exit 1
fi
bold "✓ DB smoke test passed"
