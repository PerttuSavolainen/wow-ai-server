#!/usr/bin/env bash
# Build and start the AzerothCore + Ollama stack.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AC_DIR="${ROOT_DIR}/vendor/azerothcore-wotlk"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -d "${AC_DIR}" ]] || die "AzerothCore not found. Run ./scripts/bootstrap.sh first."
[[ -f "${AC_DIR}/docker-compose.override.yml" ]] || die "Missing override. Run ./scripts/bootstrap.sh first."
[[ -f "${AC_DIR}/.env" ]] || die "Missing .env. Run ./scripts/bootstrap.sh first."

command -v docker >/dev/null 2>&1 || die "docker is required"
docker compose version >/dev/null 2>&1 || die "docker compose plugin is required"

cd "${AC_DIR}"

NO_CACHE="${NO_CACHE:-0}"
PULL_MODEL="${PULL_MODEL:-1}"
MODEL="$(grep -E '^AC_OLLAMA_CHAT_MODEL=' .env 2>/dev/null | cut -d= -f2- || true)"
MODEL="${MODEL:-qwen2.5:3b}"

log "Building and starting containers (first build can take a long time)..."
if [[ "${NO_CACHE}" == "1" ]]; then
  docker compose build --no-cache
  docker compose up -d
else
  docker compose up -d --build
fi

log "Waiting for ac-ollama..."
for _ in $(seq 1 60); do
  if docker exec ac-ollama ollama list >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if [[ "${PULL_MODEL}" == "1" ]]; then
  # Only pull into the compose Ollama service when URL points at it
  URL="$(grep -E '^AC_OLLAMA_CHAT_URL=' .env 2>/dev/null | cut -d= -f2- || true)"
  if [[ -z "${URL}" || "${URL}" == *ac-ollama* ]]; then
    log "Pulling Ollama model: ${MODEL}"
    docker exec ac-ollama ollama pull "${MODEL}"
  else
    log "AC_OLLAMA_CHAT_URL does not use ac-ollama — skip container model pull."
    log "Pull on the host instead: ollama pull ${MODEL}"
  fi
fi

log "Stack is up. Useful commands:"
echo "  Status:   docker compose -f ${AC_DIR}/docker-compose.yml -f ${AC_DIR}/docker-compose.override.yml --project-directory ${AC_DIR} ps"
echo "            (or: cd ${AC_DIR} && docker compose ps)"
echo "  Logs:     cd ${AC_DIR} && docker compose logs -f ac-worldserver"
echo "  Account:  docker attach ac-worldserver"
echo "              account create <user> <pass>"
echo "              account set gmlevel <user> 3 -1"
echo "            Detach with Ctrl-p then Ctrl-q"
echo "  Client:   set realmlist.wtf -> set realmlist 127.0.0.1"
echo "            Use a WotLK 3.3.5a (build 12340) client"
