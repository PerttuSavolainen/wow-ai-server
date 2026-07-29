#!/usr/bin/env bash
# Stop the AzerothCore + Ollama stack.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AC_DIR="${ROOT_DIR}/vendor/azerothcore-wotlk"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -d "${AC_DIR}" ]] || die "AzerothCore not found. Run ./scripts/bootstrap.sh first."

cd "${AC_DIR}"
docker compose down "$@"
printf '==> Stack stopped.\n'
