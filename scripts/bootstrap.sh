#!/usr/bin/env bash
# Clone Playerbots AzerothCore + modules and apply this repo's Docker overlays.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/vendor"
AC_DIR="${VENDOR_DIR}/azerothcore-wotlk"
MODULES_DIR="${AC_DIR}/modules"

AC_REPO="${AC_REPO:-https://github.com/mod-playerbots/azerothcore-wotlk.git}"
AC_BRANCH="${AC_BRANCH:-Playerbot}"
PLAYERBOTS_REPO="${PLAYERBOTS_REPO:-https://github.com/mod-playerbots/mod-playerbots.git}"
PLAYERBOTS_BRANCH="${PLAYERBOTS_BRANCH:-master}"
OLLAMA_CHAT_REPO="${OLLAMA_CHAT_REPO:-https://github.com/DustinHendrickson/mod-ollama-chat.git}"
OLLAMA_CHAT_BRANCH="${OLLAMA_CHAT_BRANCH:-main}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need_cmd git
need_cmd docker

mkdir -p "${VENDOR_DIR}"

if [[ ! -d "${AC_DIR}/.git" ]]; then
  log "Cloning AzerothCore Playerbots fork (${AC_BRANCH})..."
  git clone --branch "${AC_BRANCH}" --single-branch "${AC_REPO}" "${AC_DIR}"
else
  log "AzerothCore already present at ${AC_DIR}"
fi

mkdir -p "${MODULES_DIR}"

if [[ ! -d "${MODULES_DIR}/mod-playerbots/.git" ]]; then
  log "Cloning mod-playerbots..."
  git clone --branch "${PLAYERBOTS_BRANCH}" --single-branch \
    "${PLAYERBOTS_REPO}" "${MODULES_DIR}/mod-playerbots"
else
  log "mod-playerbots already present"
fi

if [[ ! -d "${MODULES_DIR}/mod-ollama-chat/.git" ]]; then
  log "Cloning mod-ollama-chat..."
  git clone --branch "${OLLAMA_CHAT_BRANCH}" --single-branch \
    "${OLLAMA_CHAT_REPO}" "${MODULES_DIR}/mod-ollama-chat"
else
  log "mod-ollama-chat already present"
fi

# Ensure submodule-style deps inside mod-ollama-chat are present if any
if [[ -f "${MODULES_DIR}/mod-ollama-chat/.gitmodules" ]]; then
  log "Updating mod-ollama-chat git submodules..."
  git -C "${MODULES_DIR}/mod-ollama-chat" submodule update --init --recursive
fi

patch_dockerfile() {
  local dockerfile="${AC_DIR}/apps/docker/Dockerfile"
  [[ -f "${dockerfile}" ]] || die "Dockerfile not found: ${dockerfile}"

  if grep -q 'wow-ai-server: ollama-chat build deps' "${dockerfile}"; then
    log "Dockerfile already patched for mod-ollama-chat deps"
    return
  fi

  log "Patching Dockerfile build stage for mod-ollama-chat (curl/OpenSSL already present; ensure libcurl + fmt headers)..."
  # Insert after the build-stage apt-get install block's closing "&& rm -rf..."
  # Idempotent marker comment identifies our patch.
  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN { patched=0 }
    {
      print
      if (!patched && $0 ~ /liblzma-dev/ && prev ~ /apt-get install/) {
        # fall through — wait for the rm -rf line of that RUN
      }
      if (!patched && prev ~ /liblzma-dev/ && $0 ~ /rm -rf \/var\/lib\/apt\/lists/) {
        print ""
        print "# wow-ai-server: ollama-chat build deps"
        print "RUN apt-get update \\"
        print " && apt-get install -y --no-install-recommends \\"
        print "      libcurl4-openssl-dev libfmt-dev \\"
        print " && rm -rf /var/lib/apt/lists/*"
        patched=1
      }
      prev=$0
    }
    END {
      if (!patched) {
        print "error: failed to locate Dockerfile build apt block to patch" > "/dev/stderr"
        exit 1
      }
    }
  ' "${dockerfile}" > "${tmp}"
  mv "${tmp}" "${dockerfile}"
  log "Dockerfile patched"
}

patch_dockerfile

stage_sql() {
  local src_chars="${MODULES_DIR}/mod-playerbots/data/sql/characters/base"
  local src_world="${MODULES_DIR}/mod-playerbots/data/sql/world/base"
  local dst_chars="${AC_DIR}/data/sql/custom/db_characters"
  local dst_world="${AC_DIR}/data/sql/custom/db_world"

  mkdir -p "${dst_chars}" "${dst_world}"

  shopt -s nullglob
  local char_sql=( "${src_chars}"/*.sql )
  local world_sql=( "${src_world}"/*.sql )
  shopt -u nullglob

  if ((${#char_sql[@]})); then
    log "Staging playerbots characters SQL into data/sql/custom/db_characters/"
    cp -n "${char_sql[@]}" "${dst_chars}/" 2>/dev/null || true
  else
    log "No characters base SQL files to stage (ok)"
  fi

  if ((${#world_sql[@]})); then
    log "Staging playerbots world SQL into data/sql/custom/db_world/"
    cp -n "${world_sql[@]}" "${dst_world}/" 2>/dev/null || true
  else
    log "No world base SQL files to stage (ok)"
  fi
}

stage_sql

log "Installing docker-compose.override.yml"
cp "${ROOT_DIR}/docker/docker-compose.override.yml" "${AC_DIR}/docker-compose.override.yml"

if [[ ! -f "${AC_DIR}/.env" ]]; then
  log "Creating .env from docker/.env.example"
  cp "${ROOT_DIR}/docker/.env.example" "${AC_DIR}/.env"
  if id -u >/dev/null 2>&1; then
    sed -i.bak \
      -e "s/^DOCKER_USER_ID=.*/DOCKER_USER_ID=$(id -u)/" \
      -e "s/^DOCKER_GROUP_ID=.*/DOCKER_GROUP_ID=$(id -g)/" \
      "${AC_DIR}/.env" && rm -f "${AC_DIR}/.env.bak"
  fi
else
  log ".env already exists — leaving it unchanged"
fi

# Ensure custom SQL dirs exist even if empty (git keeps them via .gitkeep upstream sometimes)
mkdir -p \
  "${AC_DIR}/data/sql/custom/db_auth" \
  "${AC_DIR}/data/sql/custom/db_characters" \
  "${AC_DIR}/data/sql/custom/db_world" \
  "${AC_DIR}/env/dist/etc" \
  "${AC_DIR}/env/dist/logs" \
  "${AC_DIR}/env/dist/data"

log "Bootstrap complete."
echo
echo "Next steps:"
echo "  1. Optional maps:  ./scripts/pull-client-data.sh"
echo "     (or let ac-client-data-init download on first up)"
echo "  2. Build & start:  ./scripts/up.sh"
echo "  3. Pull LLM:       docker exec -it ac-ollama ollama pull qwen2.5:3b"
echo "  4. Create account: docker attach ac-worldserver"
echo "       then: account create <user> <pass>"
echo "             account set gmlevel <user> 3 -1"
echo "       detach: Ctrl-p Ctrl-q"
