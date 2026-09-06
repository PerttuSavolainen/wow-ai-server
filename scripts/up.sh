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

# Detect rootless Podman (docker CLI shim or native).
is_podman() {
  docker version 2>/dev/null | grep -qi podman && return 0
  [[ "$(docker info -f '{{.Name}}' 2>/dev/null || true)" == *podman* ]] && return 0
  return 1
}

wait_healthy() {
  local name="$1" tries="${2:-40}"
  local i st
  for i in $(seq 1 "${tries}"); do
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${name}" 2>/dev/null || echo missing)"
    [[ "${st}" == "healthy" ]] && return 0
    # Services without a healthcheck report Status only
    if [[ "${st}" == "running" ]]; then
      local has_health
      has_health="$(docker inspect -f '{{if .State.Health}}yes{{else}}no{{end}}' "${name}" 2>/dev/null || echo no)"
      [[ "${has_health}" == "no" ]] && return 0
    fi
    sleep 3
  done
  die "${name} did not become healthy/running (last=${st})"
}

wait_exited_ok() {
  local name="$1" tries="${2:-90}"
  local i st code
  for i in $(seq 1 "${tries}"); do
    st="$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo missing)"
    if [[ "${st}" == "exited" ]]; then
      code="$(docker inspect -f '{{.State.ExitCode}}' "${name}")"
      [[ "${code}" == "0" ]] || {
        docker logs "${name}" 2>&1 | tail -40 >&2 || true
        die "${name} exited with code ${code}"
      }
      return 0
    fi
    sleep 3
  done
  die "${name} did not finish in time (status=${st})"
}

# podman-compose + Podman --requires often fails nested dependency graphs.
# Start auth/world without --requires after one-shot deps have already succeeded.
start_game_servers_podman() {
  local db_pass
  db_pass="$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' .env 2>/dev/null | cut -d= -f2- || true)"
  db_pass="${db_pass:-changeme}"

  local min_bots max_bots map_threads model url chat_dbg
  min_bots="$(grep -E '^AC_AI_PLAYERBOT_MIN_RANDOM_BOTS=' .env 2>/dev/null | cut -d= -f2- || true)"
  max_bots="$(grep -E '^AC_AI_PLAYERBOT_MAX_RANDOM_BOTS=' .env 2>/dev/null | cut -d= -f2- || true)"
  map_threads="$(grep -E '^AC_MAP_UPDATE_THREADS=' .env 2>/dev/null | cut -d= -f2- || true)"
  model="$(grep -E '^AC_OLLAMA_CHAT_MODEL=' .env 2>/dev/null | cut -d= -f2- || true)"
  url="$(grep -E '^AC_OLLAMA_CHAT_URL=' .env 2>/dev/null | cut -d= -f2- || true)"
  chat_dbg="$(grep -E '^AC_OLLAMA_CHAT_DEBUG_ENABLED=' .env 2>/dev/null | cut -d= -f2- || true)"
  min_bots="${min_bots:-20}"
  max_bots="${max_bots:-50}"
  map_threads="${map_threads:-4}"
  model="${model:-qwen2.5:3b}"
  url="${url:-http://ac-ollama:11434/api/generate}"
  chat_dbg="${chat_dbg:-0}"

  docker rm -f ac-authserver ac-worldserver >/dev/null 2>&1 || true

  # Prefer podman binary when docker is a shim (avoids "Emulate Docker CLI" noise).
  local run=(podman)
  command -v podman >/dev/null 2>&1 || run=(docker)

  "${run[@]}" run -d --name=ac-authserver \
    --label io.podman.compose.project=azerothcore-wotlk \
    --label com.docker.compose.project=azerothcore-wotlk \
    --label com.docker.compose.service=ac-authserver \
    --env-file conf/dist/env.ac \
    -e AC_LOGS_DIR=/azerothcore/env/dist/logs \
    -e AC_TEMP_DIR=/azerothcore/env/dist/temp \
    -e "AC_LOGIN_DATABASE_INFO=ac-database;3306;root;${db_pass};acore_auth" \
    -v "${AC_DIR}/env/dist/etc:/azerothcore/env/dist/etc" \
    -v "${AC_DIR}/env/dist/logs:/azerothcore/env/dist/logs" \
    --net azerothcore-wotlk_ac-network --network-alias ac-authserver \
    -p 3724:3724 --userns keep-id --tty --restart unless-stopped \
    acore/ac-wotlk-authserver:master

  "${run[@]}" run -d --name=ac-worldserver \
    --label io.podman.compose.project=azerothcore-wotlk \
    --label com.docker.compose.project=azerothcore-wotlk \
    --label com.docker.compose.service=ac-worldserver \
    --env-file conf/dist/env.ac \
    -e AC_DATA_DIR=/azerothcore/env/dist/data \
    -e AC_LOGS_DIR=/azerothcore/env/dist/logs \
    -e "AC_LOGIN_DATABASE_INFO=ac-database;3306;root;${db_pass};acore_auth" \
    -e "AC_WORLD_DATABASE_INFO=ac-database;3306;root;${db_pass};acore_world" \
    -e "AC_CHARACTER_DATABASE_INFO=ac-database;3306;root;${db_pass};acore_characters" \
    -e "AC_PLAYERBOTS_DATABASE_INFO=ac-database;3306;root;${db_pass};acore_playerbots" \
    -e AC_AI_PLAYERBOT_ENABLED=1 \
    -e AC_AI_PLAYERBOT_ENABLE_BROADCASTS=0 \
    -e AC_AI_PLAYERBOT_RANDOM_BOT_AUTOLOGIN=1 \
    -e "AC_AI_PLAYERBOT_MIN_RANDOM_BOTS=${min_bots}" \
    -e "AC_AI_PLAYERBOT_MAX_RANDOM_BOTS=${max_bots}" \
    -e "AC_MAP_UPDATE_THREADS=${map_threads}" \
    -e AC_OLLAMA_CHAT_ENABLE=1 \
    -e "AC_OLLAMA_CHAT_DEBUG_ENABLED=${chat_dbg}" \
    -e "AC_OLLAMA_CHAT_MODEL=${model}" \
    -e "AC_OLLAMA_CHAT_URL=${url}" \
    -v "${AC_DIR}/env/dist/etc:/azerothcore/env/dist/etc" \
    -v "${AC_DIR}/env/dist/logs:/azerothcore/env/dist/logs" \
    -v "${AC_DIR}/env/dist/data:/azerothcore/env/dist/data/:ro" \
    -v "${AC_DIR}/modules:/azerothcore/modules:ro" \
    --net azerothcore-wotlk_ac-network --network-alias ac-worldserver \
    --add-host host.docker.internal:host-gateway \
    -p 8085:8085 -p 7878:7878 --userns keep-id -i --tty --restart unless-stopped \
    acore/ac-wotlk-worldserver:master
}

# Skip re-download when maps are already present (pull-client-data.sh / prior init).
if [[ -d env/dist/data/maps && ! -f env/dist/data/data-version ]]; then
  log "Marking existing client data as installed (data-version=v19)"
  echo 'INSTALLED_VERSION=v19' > env/dist/data/data-version
fi

log "Building images (first build can take a long time)..."
if [[ "${NO_CACHE}" == "1" ]]; then
  docker compose build --no-cache
else
  docker compose build
fi

# Always start named services only — podman-compose ignores Compose profiles and
# would otherwise bring up ac-dev-server (port clash on 3724/8085/7878).
if is_podman; then
  log "Podman detected — starting services in dependency order"
  docker rm -f azerothcore-wotlk_ac-dev-server_1 ac-tools >/dev/null 2>&1 || true
  docker compose up -d ac-database ac-ollama
  wait_healthy ac-database
  docker compose up -d ac-client-data-init
  wait_exited_ok ac-client-data-init
  docker compose up -d ac-db-import
  wait_exited_ok ac-db-import 120
  log "Starting authserver + worldserver (Podman --requires workaround)"
  start_game_servers_podman
else
  log "Starting containers..."
  docker compose up -d ac-database ac-ollama ac-client-data-init ac-db-import ac-authserver ac-worldserver
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
    # Skip pull when the model is already local (avoids flaky Podman DNS to registry.ollama.ai).
    if docker exec ac-ollama ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "${MODEL}"; then
      log "Ollama model already present, skip pull: ${MODEL}"
    else
      log "Pulling Ollama model: ${MODEL}"
      if ! docker exec ac-ollama ollama pull "${MODEL}"; then
        log "WARNING: ollama pull failed (often DNS). Retry later:"
        log "  docker exec -it ac-ollama ollama pull ${MODEL}"
        log "  Or skip on next up: PULL_MODEL=0 ./scripts/up.sh"
      fi
    fi
  else
    log "AC_OLLAMA_CHAT_URL does not use ac-ollama — skip container model pull."
    log "Pull on the host instead: ollama pull ${MODEL}"
  fi
fi

log "Stack is up. Useful commands:"
echo "  Status:   docker ps --filter name=ac-"
echo "            (or: cd ${AC_DIR} && docker compose ps)"
echo "  Logs:     docker logs -f ac-worldserver"
echo "  Account:  docker attach ac-worldserver"
echo "              account create <user> <pass>"
echo "              account set gmlevel <user> 3 -1"
echo "            Detach with Ctrl-p then Ctrl-q"
echo "  Client:   set realmlist.wtf -> set realmlist 127.0.0.1"
echo "            Use a WotLK 3.3.5a (build 12340) client"
