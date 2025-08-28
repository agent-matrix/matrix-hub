#!/usr/bin/env bash
set -Eeuo pipefail

# Start/stop/status Watsonx MCP agent (FastMCP SSE on /sse)
# Usage:
#   examples/start-watsonx-agent.sh start [--background] [--wait] [--timeout 20] [--log <path>] [--pid <path>]
#   examples/start-watsonx-agent.sh stop
#   examples/start-watsonx-agent.sh status
#
# Defaults:
#   venv:    <repo>/.venv
#   project: <repo>/examples/agents/watsonx-agent
#   port:    $WATSONX_AGENT_PORT or 6288
#
# Notes:
#   • Loads .env from the repo root (auto-discovered).
#   • When --wait is used, we poll http://127.0.0.1:$PORT/sse until 2xx or timeout.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="${REPO_ROOT:-"$(cd "$SCRIPT_DIR/.." && pwd)"}"
PROJECT_DIR="${PROJECT_DIR:-"$REPO_ROOT/examples/agents/watsonx-agent"}"
VENV_DIR="${VENV_DIR:-"$REPO_ROOT/.venv"}"

# ── find .env upward (repo root will usually have it)
find_env_up() {
  local dir="$1"
  while [[ -n "$dir" && "$dir" != "/" && "$dir" != "." ]]; do
    if [[ -f "$dir/.env" ]]; then echo "$dir/.env"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}
ENV_FILE="${ENV_FILE:-"$(find_env_up "$REPO_ROOT" || true)"}"
if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
  echo "ℹ️  Loading .env from $ENV_FILE"
  set +u; set -a; source "$ENV_FILE"; set +a; set -u
else
  echo "ℹ️  No .env found (looked under $REPO_ROOT). Continuing…"
fi

# ── config (after .env is loaded)
HOST="${HOST:-127.0.0.1}"
PORT="${WATSONX_AGENT_PORT:-6288}"
SSE_URL="http://${HOST}:${PORT}/sse"

PIDFILE_DEFAULT="$PROJECT_DIR/.watsonx-agent.pid"
LOGFILE_DEFAULT="$PROJECT_DIR/.watsonx-agent.log"

# ── helpers
usage() {
  cat <<EOF
Usage:
  $0 start [--background] [--wait] [--timeout <secs>] [--log <path>] [--pid <path>]
  $0 stop
  $0 status

Options (start):
  --background          Run server in background (nohup), write PID to pidfile.
  --wait                Wait for SSE readiness (2xx) before returning.
  --timeout <secs>      Max seconds to wait when --wait is used (default 20).
  --log <path>          Log file path (default: $LOGFILE_DEFAULT).
  --pid <path>          PID file path (default: $PIDFILE_DEFAULT).
Env:
  REPO_ROOT, PROJECT_DIR, VENV_DIR, WATSONX_AGENT_PORT, HOST can override defaults.
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "✖ $1 is required"; exit 1; }; }

is_running_pid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  ps -p "$pid" -o pid= >/dev/null 2>&1
}

read_pidfile() {
  local pf="$1"
  [[ -f "$pf" ]] || return 1
  local pid; pid="$(cat "$pf" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  echo "$pid"
}

wait_ready() {
  local url="$1" timeout_secs="$2"
  local start t
  start="$(date +%s)"
  echo "⏱  Waiting for readiness at $url (timeout ${timeout_secs}s)…"
  while :; do
    if curl -sS -I --connect-timeout 1 --max-time 2 "$url" 2>/dev/null | head -n1 | grep -qE 'HTTP/[0-9.]+\s2[0-9][0-9]'; then
      echo "✅ Ready ($url)"
      return 0
    fi
    t="$(date +%s)"
    if (( t - start >= timeout_secs )); then
      echo "⚠️  Timed out waiting for readiness at $url"
      return 1
    fi
    sleep 0.5
  done
}

start_fg() {
  echo "🚀 Starting Watsonx MCP server (foreground) at $SSE_URL"
  echo "   Project: $PROJECT_DIR"
  echo "   Venv:    $VENV_DIR"
  ( cd "$PROJECT_DIR" && exec python server.py )
}

start_bg() {
  local pidfile="$1" logfile="$2" wait_flag="$3" timeout_secs="$4"

  mkdir -p "$(dirname "$pidfile")" "$(dirname "$logfile")"
  # If already running, don't start another
  if pid="$(read_pidfile "$pidfile")" && is_running_pid "$pid"; then
    echo "ℹ️  Already running (pid $pid)."
    if [[ "$wait_flag" == "1" ]]; then wait_ready "$SSE_URL" "$timeout_secs" || true; fi
    return 0
  fi

  echo "🚀 Starting Watsonx MCP server (background) at $SSE_URL"
  echo "   Project: $PROJECT_DIR"
  echo "   Venv:    $VENV_DIR"
  echo "   Log:     $logfile"
  echo "   PID:     $pidfile"

  # Start
  (
    cd "$PROJECT_DIR"
    # Use nohup so it survives caller shell exit
    nohup python server.py >>"$logfile" 2>&1 &
    echo $! >"$pidfile"
  )

  sleep 0.2
  if pid="$(read_pidfile "$pidfile")" && is_running_pid "$pid"; then
    echo "✅ Launched (pid $pid)."
  else
    echo "✖ Failed to start — see log: $logfile"
    exit 1
  fi

  if [[ "$wait_flag" == "1" ]]; then
    wait_ready "$SSE_URL" "$timeout_secs" || true
  fi
}

stop_server() {
  local pidfile="$1"
  if ! pid="$(read_pidfile "$pidfile")"; then
    echo "ℹ️  No pidfile at $pidfile; nothing to stop."
    return 0
  fi
  if ! is_running_pid "$pid"; then
    echo "ℹ️  Stale pidfile ($pid). Removing."
    rm -f "$pidfile"
    return 0
  fi
  echo "🛑 Stopping pid $pid…"
  kill "$pid" 2>/dev/null || true
  # Wait a bit then force kill if needed
  for _ in {1..20}; do
    if ! is_running_pid "$pid"; then
      echo "✅ Stopped."
      rm -f "$pidfile"
      return 0
    fi
    sleep 0.25
  done
  echo "⚠️  Force killing pid $pid"
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$pidfile"
  echo "✅ Stopped."
}

status_server() {
  local pidfile="$1"
  local running="no"
  if pid="$(read_pidfile "$pidfile")" && is_running_pid "$pid"; then
    running="yes"
    echo "ℹ️  Process running (pid $pid)."
  else
    echo "ℹ️  Not running."
  fi
  # SSE probe
  if curl -sS -I --connect-timeout 1 --max-time 2 "$SSE_URL" 2>/dev/null | head -n1 | grep -qE 'HTTP/[0-9.]+\s2[0-9][0-9]'; then
    echo "ℹ️  SSE endpoint responsive at $SSE_URL"
  else
    echo "ℹ️  SSE endpoint not responsive at $SSE_URL"
  fi
  [[ "$running" == "yes" ]] && return 0 || return 1
}

# ── parse args
cmd="${1:-}"
shift || true

BACKGROUND=0
WAIT_READY=0
TIMEOUT_SECS=20
PIDFILE="$PIDFILE_DEFAULT"
LOGFILE="$LOGFILE_DEFAULT"

while (( $# )); do
  case "$1" in
    --background) BACKGROUND=1; shift ;;
    --wait)       WAIT_READY=1; shift ;;
    --timeout)    TIMEOUT_SECS="${2:-20}"; shift 2 ;;
    --pid)        PIDFILE="${2:-$PIDFILE}"; shift 2 ;;
    --log)        LOGFILE="${2:-$LOGFILE}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── prereqs
need python
need curl

# ── activate venv
if [[ -f "$VENV_DIR/bin/activate" ]]; then
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
else
  echo "✖ Virtualenv not found at $VENV_DIR/bin/activate"
  exit 1
fi

# ── ensure project dir
cd "$PROJECT_DIR" || { echo "✖ Could not cd to $PROJECT_DIR"; exit 1; }

# ── do command
case "$cmd" in
  start)
    if (( BACKGROUND )); then
      start_bg "$PIDFILE" "$LOGFILE" "$WAIT_READY" "$TIMEOUT_SECS"
    else
      # In foreground, optionally wait before printing “ready” (quick probe before handing over)
      if (( WAIT_READY )); then
        # Start in bg, wait, then bring to fg (not trivial), so just start fg and rely on caller SSE check later.
        echo "ℹ️  --wait is ignored in foreground mode (use --background for readiness blocking)."
      fi
      start_fg
    fi
    ;;
  stop)
    stop_server "$PIDFILE"
    ;;
  status)
    status_server "$PIDFILE"
    ;;
  restart)
    stop_server "$PIDFILE" || true
    if (( BACKGROUND )); then
      start_bg "$PIDFILE" "$LOGFILE" "$WAIT_READY" "$TIMEOUT_SECS"
    else
      start_fg
    fi
    ;;
  ""|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd"
    usage
    exit 1
    ;;
esac
