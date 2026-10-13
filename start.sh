#!/usr/bin/env bash
# ============================================================
#  RAG Agent — start.sh
#  Оркестрация: stop → cache clean → venv + deps → start
# ============================================================

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

VENV_DIR="${PROJECT_DIR}/.venv"
PYTHON_EXE="${VENV_DIR}/bin/python"
PIP_EXE="${VENV_DIR}/bin/pip"
MAIN_MODULE="rag_agent.py"
REQUIREMENTS="requirements.txt"
PID_FILE="${PROJECT_DIR}/.rag_agent.pid"

echo
echo "============================================================"
echo "  RAG Agent — Deploy & Start"
echo "============================================================"
echo "  Directory: ${PROJECT_DIR}"
echo

# ----------------------------------------------------------
#  1. STOP old processes
# ----------------------------------------------------------
echo "[1/4] Stopping old processes..."

if [[ -f "$PID_FILE" ]]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "${OLD_PID:-}" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        kill -TERM "$OLD_PID" 2>/dev/null || true
        sleep 1
        if kill -0 "$OLD_PID" 2>/dev/null; then
            kill -KILL "$OLD_PID" 2>/dev/null || true
        fi
        echo "  Killed process PID=${OLD_PID}"
    else
        echo "  PID file present but process already stopped"
    fi
    rm -f "$PID_FILE"
fi

# Kill any leftover processes running rag_agent.py
PIDS=$(pgrep -f "python.*${MAIN_MODULE}" 2>/dev/null || true)
if [[ -n "${PIDS}" ]]; then
    for p in $PIDS; do
        kill -TERM "$p" 2>/dev/null || true
        echo "  Killed leftover python PID=${p}"
    done
    sleep 1
    # force kill if still alive
    for p in $PIDS; do
        kill -KILL "$p" 2>/dev/null || true
    done
fi

echo "  Done."
echo

# ----------------------------------------------------------
#  2. CLEAN cache
# ----------------------------------------------------------
echo "[2/4] Cleaning cache..."

# __pycache__ directories
find "$PROJECT_DIR" -type d -name "__pycache__" -print0 2>/dev/null \
    | while IFS= read -r -d '' d; do
        rm -rf "$d"
        echo "  Removed: $d"
    done

# *.pyc / *.pyo
find "$PROJECT_DIR" -type f \( -name "*.pyc" -o -name "*.pyo" \) -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        rm -f "$f"
        echo "  Removed: $f"
    done

# common tool caches
rm -rf \
    "${PROJECT_DIR}/.pytest_cache" \
    "${PROJECT_DIR}/.mypy_cache" \
    "${PROJECT_DIR}/.ruff_cache" \
    "${PROJECT_DIR}/htmlcov" \
    2>/dev/null || true
rm -f "${PROJECT_DIR}/.coverage" 2>/dev/null || true

echo "  Done."
echo

# ----------------------------------------------------------
#  3. BUILD environment + install dependencies
# ----------------------------------------------------------
echo "[3/4] Building environment and installing dependencies..."

# Detect system python
if command -v python3 &>/dev/null; then
    SYS_PYTHON="python3"
elif command -v python &>/dev/null; then
    SYS_PYTHON="python"
else
    echo "  [ERROR] Python not found. Install Python 3.10+ and retry."
    exit 1
fi

# Create venv if missing
if [[ ! -x "$PYTHON_EXE" ]]; then
    echo "  Creating virtual environment: ${VENV_DIR}"
    "$SYS_PYTHON" -m venv "$VENV_DIR"
else
    echo "  Virtual environment already exists."
fi

# Upgrade pip / setuptools / wheel
echo "  Upgrading pip..."
"$PYTHON_EXE" -m pip install --upgrade pip setuptools wheel -q || {
    echo "  [WARN] pip upgrade failed, continuing..."
}

# Install / update dependencies
if [[ -f "${PROJECT_DIR}/${REQUIREMENTS}" ]]; then
    echo "  Installing from ${REQUIREMENTS} ..."
    "$PIP_EXE" install -r "${PROJECT_DIR}/${REQUIREMENTS}"
else
    echo "  [WARN] ${REQUIREMENTS} not found — skipping install."
fi

# Ensure .env exists
if [[ ! -f "${PROJECT_DIR}/.env" ]]; then
    if [[ -f "${PROJECT_DIR}/.env.example" ]]; then
        cp "${PROJECT_DIR}/.env.example" "${PROJECT_DIR}/.env"
        echo "  Created .env from .env.example — fill in your API keys!"
    else
        echo "  [WARN] No .env and no .env.example found."
    fi
fi

echo "  Done."
echo

# ----------------------------------------------------------
#  4. START project
# ----------------------------------------------------------
echo "[4/4] Starting RAG Agent..."
echo "------------------------------------------------------------"

if [[ ! -f "${PROJECT_DIR}/${MAIN_MODULE}" ]]; then
    echo "  [ERROR] ${MAIN_MODULE} not found."
    exit 1
fi

# Write PID and run in foreground
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

"$PYTHON_EXE" "${PROJECT_DIR}/${MAIN_MODULE}"
EXIT_CODE=$?

echo
echo "------------------------------------------------------------"
echo "  Process finished with exit code: ${EXIT_CODE}"
echo "============================================================"

exit "$EXIT_CODE"
