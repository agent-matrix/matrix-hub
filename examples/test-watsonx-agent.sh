#!/usr/bin/env bash
# A simple script to start the watsonx-agent client.

# --- Determine directories ---
# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Assume .venv is at the repo root (one level above SCRIPT_DIR if SCRIPT_DIR is in examples/)
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Where the agent project itself lives
PROJECT_DIR="$REPO_ROOT/examples/agents/watsonx-agent"
# Virtualenv location
VENV_DIR="$REPO_ROOT/.venv"

# --- Script Execution ---
echo "Navigating to the project directory..."
cd "$PROJECT_DIR" || {
  echo "Error: Could not change to directory $PROJECT_DIR. Please check the path."
  exit 1
}

echo "Activating Python virtual environment from $VENV_DIR..."
if [ -f "$VENV_DIR/bin/activate" ]; then
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
else
  echo "Error: Virtualenv not found at $VENV_DIR/bin/activate"
  exit 1
fi

echo "Starting the watsonx-agent client..."
python client.py

echo "client has been stopped."
