#!/usr/bin/env bash
# Download wowgaming enUS client-data (maps/dbc/vmaps/mmaps) into the AC data path.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AC_DIR="${ROOT_DIR}/vendor/azerothcore-wotlk"
DATA_DIR="${AC_DIR}/env/dist/data"
CACHE_DIR="${ROOT_DIR}/data/cache"

# Pin to mmap generator version matching this AC/Playerbots build (MMAP_VERSION 19).
# Override with CLIENT_DATA_TAG=v20.0 only if the core expects MMAP_VERSION 20.
CLIENT_DATA_TAG="${CLIENT_DATA_TAG:-v19}"
CLIENT_DATA_URL="${CLIENT_DATA_URL:-https://github.com/wowgaming/client-data/releases/download/${CLIENT_DATA_TAG}/Data.zip}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need_cmd curl
need_cmd unzip

[[ -d "${AC_DIR}" ]] || die "AzerothCore not found. Run ./scripts/bootstrap.sh first."

mkdir -p "${CACHE_DIR}" "${DATA_DIR}"

ZIP_PATH="${CACHE_DIR}/Data-${CLIENT_DATA_TAG}.zip"

if [[ ! -f "${ZIP_PATH}" ]]; then
  log "Downloading client-data ${CLIENT_DATA_TAG} (~1.1 GB)..."
  curl -fL --progress-bar -o "${ZIP_PATH}.partial" "${CLIENT_DATA_URL}"
  mv "${ZIP_PATH}.partial" "${ZIP_PATH}"
else
  log "Using cached archive: ${ZIP_PATH}"
fi

# Detect if data already looks populated
if [[ -d "${DATA_DIR}/maps" && -d "${DATA_DIR}/dbc" ]]; then
  if [[ "${FORCE_CLIENT_DATA:-0}" != "1" ]]; then
    log "Data already present under ${DATA_DIR} (maps + dbc)."
    log "Set FORCE_CLIENT_DATA=1 to re-extract."
  else
    log "FORCE_CLIENT_DATA=1 — re-extracting into ${DATA_DIR}"
    unzip -o "${ZIP_PATH}" -d "${DATA_DIR}"
  fi
else
  log "Extracting into ${DATA_DIR}..."
  # Archive layout is usually Data/dbc, Data/maps, ... or flat dbc/maps
  TMP_EXTRACT="${CACHE_DIR}/extract-${CLIENT_DATA_TAG}"
  rm -rf "${TMP_EXTRACT}"
  mkdir -p "${TMP_EXTRACT}"
  unzip -q "${ZIP_PATH}" -d "${TMP_EXTRACT}"

  if [[ -d "${TMP_EXTRACT}/Data" ]]; then
    # Move contents of Data/ into env/dist/data/
    shopt -s dotglob nullglob
    mv "${TMP_EXTRACT}/Data"/* "${DATA_DIR}/"
    shopt -u dotglob nullglob
  elif [[ -d "${TMP_EXTRACT}/dbc" || -d "${TMP_EXTRACT}/maps" ]]; then
    shopt -s dotglob nullglob
    mv "${TMP_EXTRACT}"/* "${DATA_DIR}/"
    shopt -u dotglob nullglob
  else
    # Nested single top-level folder
    top="$(find "${TMP_EXTRACT}" -mindepth 1 -maxdepth 1 -type d | head -1 || true)"
    if [[ -n "${top}" ]]; then
      shopt -s dotglob nullglob
      mv "${top}"/* "${DATA_DIR}/"
      shopt -u dotglob nullglob
    else
      die "Unexpected archive layout under ${TMP_EXTRACT}"
    fi
  fi
  rm -rf "${TMP_EXTRACT}"
fi

# Point compose at the bind-mounted host data directory
ENV_FILE="${AC_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  if grep -q '^DOCKER_VOL_DATA=' "${ENV_FILE}"; then
    sed -i.bak 's|^DOCKER_VOL_DATA=.*|DOCKER_VOL_DATA=./env/dist/data|' "${ENV_FILE}"
    rm -f "${ENV_FILE}.bak"
  else
    printf '\nDOCKER_VOL_DATA=./env/dist/data\n' >> "${ENV_FILE}"
  fi
  log "Set DOCKER_VOL_DATA=./env/dist/data in ${ENV_FILE}"
else
  die ".env missing in ${AC_DIR}. Run ./scripts/bootstrap.sh first."
fi

log "Client data ready."
echo "Expected folders under ${DATA_DIR}: Cameras dbc maps mmaps vmaps"
ls -la "${DATA_DIR}" || true
