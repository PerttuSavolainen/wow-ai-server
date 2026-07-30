#!/usr/bin/env bash
# Set the realmlist address clients use to reach the worldserver (port 8085).
# Auth can work with 127.0.0.1 while world login fails if the client runs in a
# VM / another PC — they get redirected to the wrong "localhost".
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AC_DIR="${ROOT_DIR}/vendor/azerothcore-wotlk"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ -d "${AC_DIR}" ]] || die "Run ./scripts/bootstrap.sh first."
[[ -f "${AC_DIR}/.env" ]] || die "Missing ${AC_DIR}/.env"

ADDRESS="${1:-}"
if [[ -z "${ADDRESS}" ]]; then
  ADDRESS="$(ipconfig getifaddr en0 2>/dev/null || true)"
  ADDRESS="${ADDRESS:-$(ipconfig getifaddr en1 2>/dev/null || true)}"
  ADDRESS="${ADDRESS:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
fi
[[ -n "${ADDRESS}" ]] || die "Usage: $0 <ip-or-hostname>  (could not auto-detect)"

PASS="$(grep -E '^DOCKER_DB_ROOT_PASSWORD=' "${AC_DIR}/.env" | cut -d= -f2-)"
[[ -n "${PASS}" ]] || die "DOCKER_DB_ROOT_PASSWORD missing in .env"

printf '==> Setting realmlist address/localAddress to %s (and clearing offline flag)\n' "${ADDRESS}"
docker exec ac-database mysql -uroot -p"${PASS}" -e \
  "UPDATE acore_auth.realmlist
     SET address='${ADDRESS}', localAddress='${ADDRESS}', flag = (flag & ~2)
   WHERE id=1;
   SELECT id,name,address,localAddress,port,flag FROM acore_auth.realmlist;"

cd "${AC_DIR}"
# Worldserver re-registers the realm as online; auth reloads the address.
docker compose restart ac-authserver ac-worldserver
printf '==> Done. In realmlist.wtf use: set realmlist %s\n' "${ADDRESS}"
printf '    Wait for worldserver to finish loading, then restart the WoW client.\n'
printf '    If the realm still shows Offline, wait ~1–2 minutes and refresh.\n'
