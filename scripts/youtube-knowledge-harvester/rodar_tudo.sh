#!/usr/bin/env bash
cd "$(dirname "$0")" || exit 1
export PYTHONUTF8=1
PY=$(command -v python3 || command -v python) || { echo "Python 3 não encontrado. Instale e rode de novo."; exit 1; }
if command -v caffeinate >/dev/null 2>&1; then exec caffeinate -i "$PY" bootstrap.py; fi
exec "$PY" bootstrap.py
