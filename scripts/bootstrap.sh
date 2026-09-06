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

# Rootless Podman fails if VOLUME is declared before a RUN that chowns that path.
patch_dockerfile_podman_volume() {
  local dockerfile="${AC_DIR}/apps/docker/Dockerfile"
  [[ -f "${dockerfile}" ]] || die "Dockerfile not found: ${dockerfile}"

  if grep -q 'wow-ai-server: podman VOLUME after chown' "${dockerfile}"; then
    log "Dockerfile already patched for Podman VOLUME ordering"
    return
  fi

  # Only rewrite the runtime-stage ordering (VOLUME before userdel).
  if grep -q 'VOLUME /azerothcore/env/dist/etc' "${dockerfile}" \
    && awk '/COPY --from=build \/azerothcore\/env\/dist\/etc/{f=1} f && /VOLUME \/azerothcore\/env\/dist\/etc/{v=1} f && /userdel --remove ubuntu/{u=1; if(v) exit 0; exit 1}' "${dockerfile}"; then
    log "Reordering runtime VOLUME after userdel (Podman compatibility)..."
    local tmp
    tmp="$(mktemp)"
    python3 - "${dockerfile}" "${tmp}" <<'PY'
import pathlib, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = src.read_text()
old = '''COPY --from=build /azerothcore/env/dist/etc/ /azerothcore/env/ref/etc

VOLUME /azerothcore/env/dist/etc

ENV PATH="/azerothcore/env/dist/bin:$PATH"

# To use GID/UID 1000 in ubuntu > 23.04 the existing user must be deleted
# See https://bugs.launchpad.net/cloud-images/+bug/2005129
RUN userdel --remove ubuntu \\
  && addgroup --gid "$GROUP_ID" "$DOCKER_USER" \\
  && adduser --disabled-password --gecos '' --uid "$USER_ID" --gid "$GROUP_ID" "$DOCKER_USER" \\
  && passwd -d "$DOCKER_USER" \\
  && chown -R "$DOCKER_USER:$DOCKER_USER" /azerothcore

COPY --chown=$USER_ID:$GROUP_ID \\
     --chmod=755 \\
     apps/docker/entrypoint.sh /azerothcore/entrypoint.sh

USER $DOCKER_USER

ENTRYPOINT ["/usr/bin/env", "bash", "/azerothcore/entrypoint.sh"]
'''
new = '''COPY --from=build /azerothcore/env/dist/etc/ /azerothcore/env/ref/etc

ENV PATH="/azerothcore/env/dist/bin:$PATH"

# To use GID/UID 1000 in ubuntu > 23.04 the existing user must be deleted
# See https://bugs.launchpad.net/cloud-images/+bug/2005129
# wow-ai-server: podman VOLUME after chown
RUN userdel --remove ubuntu \\
  && addgroup --gid "$GROUP_ID" "$DOCKER_USER" \\
  && adduser --disabled-password --gecos '' --uid "$USER_ID" --gid "$GROUP_ID" "$DOCKER_USER" \\
  && passwd -d "$DOCKER_USER" \\
  && chown -R "$DOCKER_USER:$DOCKER_USER" /azerothcore

COPY --chown=$USER_ID:$GROUP_ID \\
     --chmod=755 \\
     apps/docker/entrypoint.sh /azerothcore/entrypoint.sh

USER $DOCKER_USER

VOLUME /azerothcore/env/dist/etc

ENTRYPOINT ["/usr/bin/env", "bash", "/azerothcore/entrypoint.sh"]
'''
if old not in text:
    print('error: expected Dockerfile runtime block not found', file=sys.stderr)
    sys.exit(1)
dst.write_text(text.replace(old, new, 1))
PY
    mv "${tmp}" "${dockerfile}"
    log "Dockerfile Podman VOLUME order patched"
  else
    # Already reordered manually — stamp the marker if missing
    if grep -q 'VOLUME /azerothcore/env/dist/etc' "${dockerfile}"; then
      sed -i '/userdel --remove ubuntu/i# wow-ai-server: podman VOLUME after chown' "${dockerfile}"
      # Only first occurrence in runtime stage — sed inserts before every userdel; fix by ensuring single marker near runtime
      log "Stamped Podman VOLUME marker (verify Dockerfile if bootstrap re-run looks wrong)"
    fi
  fi
}

patch_dockerfile
patch_dockerfile_podman_volume

# Do NOT copy module SQL into data/sql/custom/ — db-import already loads
# modules/mod-playerbots/data/sql/* and rejects duplicate basenames.
mkdir -p \
  "${AC_DIR}/data/sql/custom/db_auth" \
  "${AC_DIR}/data/sql/custom/db_characters" \
  "${AC_DIR}/data/sql/custom/db_world"

log "Installing docker-compose.override.yml"
cp "${ROOT_DIR}/docker/docker-compose.override.yml" "${AC_DIR}/docker-compose.override.yml"

# Pick container UID/GID that do not collide with Ubuntu system accounts.
# macOS users are often uid 501 / gid 20 (staff); GID 20 is already "dialout" in Ubuntu,
# which makes Dockerfile `addgroup --gid 20` fail during image build.
resolve_docker_ids() {
  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"
  if [[ "$(uname -s)" == "Darwin" ]] || (( uid < 1000 )); then
    uid=1000
  fi
  if [[ "$(uname -s)" == "Darwin" ]] || (( gid < 1000 )); then
    gid=1000
  fi
  printf '%s %s' "${uid}" "${gid}"
}

if [[ ! -f "${AC_DIR}/.env" ]]; then
  log "Creating .env from docker/.env.example"
  cp "${ROOT_DIR}/docker/.env.example" "${AC_DIR}/.env"
  read -r _docker_uid _docker_gid < <(resolve_docker_ids)
  sed -i.bak \
    -e "s/^DOCKER_USER_ID=.*/DOCKER_USER_ID=${_docker_uid}/" \
    -e "s/^DOCKER_GROUP_ID=.*/DOCKER_GROUP_ID=${_docker_gid}/" \
    "${AC_DIR}/.env" && rm -f "${AC_DIR}/.env.bak"
  log "Set DOCKER_USER_ID=${_docker_uid} DOCKER_GROUP_ID=${_docker_gid}"
else
  log ".env already exists — leaving it unchanged"
  # Warn if existing .env would break the Ubuntu image build (common on macOS).
  _existing_gid="$(grep -E '^DOCKER_GROUP_ID=' "${AC_DIR}/.env" | cut -d= -f2- || true)"
  if [[ -n "${_existing_gid}" ]] && (( _existing_gid < 1000 )); then
    log "WARNING: DOCKER_GROUP_ID=${_existing_gid} may collide with Ubuntu system groups."
    log "         Set DOCKER_GROUP_ID=1000 (and usually DOCKER_USER_ID=1000) in ${AC_DIR}/.env"
  fi
fi

# Ensure custom SQL dirs exist even if empty (do not copy module SQL here —
# that duplicates filenames and makes ac-db-import fail).
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
