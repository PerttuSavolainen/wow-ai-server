# WotLK 3.3.5a + LLM Playerbots (Docker Compose)

Local private realm for **World of Warcraft: Wrath of the Lich King (3.3.5a)**. Random **Playerbots** quest and play autonomously; **Ollama** powers in-character chat via [`mod-ollama-chat`](https://github.com/DustinHendrickson/mod-ollama-chat).

This repo is a thin orchestration layer. It clones the required Playerbots AzerothCore fork and modules into `vendor/` (gitignored) and applies Docker Compose overlays.

```text
WotLK client  →  ac-authserver / ac-worldserver
                      ↓                ↓
                 MariaDB/MySQL    mod-playerbots (gameplay AI)
                                       ↓
                                 mod-ollama-chat → Ollama (LLM chat)
```

## Prerequisites

- **Docker** with the **Compose** plugin (Docker Engine or Docker Desktop)
- **Git**, **curl**, **unzip**
- Roughly **40+ GB** free disk (source build, maps ~1 GB+, LLM weights)
- A **WotLK 3.3.5a (build 12340)** game client (bring your own — not redistributed here)

Optional:

- **NVIDIA Container Toolkit** on Linux if you want GPU acceleration inside the `ac-ollama` container
- **Host Ollama** (recommended on macOS for Metal) — point the module at `host.docker.internal`

## Quick start

```bash
./scripts/bootstrap.sh          # clone core + modules, write override + .env
./scripts/pull-client-data.sh   # optional; otherwise ac-client-data-init downloads maps
./scripts/up.sh                 # build + start (first build is slow)
```

Pull the chat model (also attempted by `up.sh` when using in-compose Ollama):

```bash
docker exec -it ac-ollama ollama pull qwen2.5:3b
```

Create a game account:

```bash
docker attach ac-worldserver
account create myuser mypassword
account set gmlevel myuser 3 -1
```

Detach without stopping the server: **Ctrl-p**, then **Ctrl-q**.

Point your client `realmlist.wtf` at this host:

```text
set realmlist 127.0.0.1
```

If the client runs in a **VM**, on another PC, or still bounces back to the realm list after "Okay", the auth DB must advertise your LAN IP (not `127.0.0.1`) for the worldserver:

```bash
./scripts/set-realm-address.sh          # auto-detect
# or: ./scripts/set-realm-address.sh 192.168.0.82
```

Then use the same IP in `realmlist.wtf`, restart the client, and try again.

Stop the stack:

```bash
./scripts/down.sh
```

## What gets installed

| Component | Source |
|-----------|--------|
| Core | [mod-playerbots/azerothcore-wotlk](https://github.com/mod-playerbots/azerothcore-wotlk) `Playerbot` branch |
| Bots | [mod-playerbots/mod-playerbots](https://github.com/mod-playerbots/mod-playerbots) |
| LLM chat | [DustinHendrickson/mod-ollama-chat](https://github.com/DustinHendrickson/mod-ollama-chat) |
| Maps | [wowgaming/client-data](https://github.com/wowgaming/client-data) (via `pull-client-data.sh` or AC init) |
| LLM runtime | `ollama/ollama` Compose service |

Stock AzerothCore **cannot** build `mod-playerbots`. The Playerbots fork is required.

## Configuration

After bootstrap, edit `vendor/azerothcore-wotlk/.env` (seeded from [`docker/.env.example`](docker/.env.example)).

Important variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `DOCKER_DB_ROOT_PASSWORD` | `changeme` | MySQL root password |
| `AC_AI_PLAYERBOT_MIN_RANDOM_BOTS` | `20` | Minimum random bots |
| `AC_AI_PLAYERBOT_MAX_RANDOM_BOTS` | `50` | Maximum random bots |
| `AC_AI_PLAYERBOT_RANDOM_BOT_ALLIANCE_RATIO` | `100` | % Alliance random bots |
| `AC_AI_PLAYERBOT_RANDOM_BOT_HORDE_RATIO` | `0` | % Horde random bots |
| `AC_AI_PLAYERBOT_SYNC_LEVEL_WITH_PLAYERS` | `1` | Cap bot max level to highest online player + 3 |
| `AC_MAP_UPDATE_THREADS` | `4` | World map update threads |
| `AC_OLLAMA_CHAT_MODEL` | `qwen2.5:3b` | Ollama model name |
| `AC_OLLAMA_CHAT_URL` | `http://ac-ollama:11434/api/generate` | Ollama generate API |
| `DOCKER_VOL_DATA` | `ac-client-data` or `./env/dist/data` | Client maps volume |

Compose override lives at [`docker/docker-compose.override.yml`](docker/docker-compose.override.yml) and is copied into the vendor tree by bootstrap.

Module env notes: [`config/modules/`](config/modules/).

### Host Ollama (macOS Metal / host GPU)

1. Install and run [Ollama](https://ollama.com) on the host.
2. `ollama pull qwen2.5:3b`
3. In `.env` set:

```bash
AC_OLLAMA_CHAT_URL=http://host.docker.internal:11434/api/generate
```

4. Restart worldserver: `cd vendor/azerothcore-wotlk && docker compose up -d ac-worldserver`

You can leave the `ac-ollama` container running unused, or remove/disable it later if you prefer.

### NVIDIA GPU inside Docker (Linux)

In `vendor/azerothcore-wotlk/docker-compose.override.yml`, uncomment the `deploy.resources.reservations.devices` block under `ac-ollama`, then:

```bash
cd vendor/azerothcore-wotlk
docker compose up -d ac-ollama
```

Requires a working NVIDIA driver + NVIDIA Container Toolkit.

## Tuning for ~16 GB RAM

Defaults target a **16 GB** machine with a small bot population:

| Setting | Guidance |
|---------|----------|
| Random bots | **20–50** |
| LLM | **3B-class** models (`qwen2.5:3b`, `llama3.2:3b`). Avoid 8B+ until you have headroom |
| `MapUpdate.Threads` | **4** (`AC_MAP_UPDATE_THREADS`) |
| MySQL | Prefer enough InnoDB buffer for your host; for a dedicated server box, ~25–50% of RAM is a common starting point. For a laptop also running the client + Ollama, keep the DB modest and lower bot counts first |
| Concurrent chat | Keep Ollama concurrency low; chat is the LLM bottleneck |

Rough memory picture with defaults: DB + auth/world ~several GB, bots scale with count, LLM weights in RAM/VRAM depending on backend.

Rebuild after changing modules:

```bash
NO_CACHE=1 ./scripts/up.sh
```

## Client notes

- Server build: **3.3.5a / 12340**
- Server DBC language should be **enUS** (playerbots spell names). Client locale can differ.
- `pull-client-data.sh` installs **server** maps/dbc/vmaps/mmaps. You still need a playable client binary + `Data` folder to log in.
- The **server stack** runs via Docker on Linux or macOS. The **game client** is typically Windows (or Wine/Proton).

## Scripts

| Script | Purpose |
|--------|---------|
| [`scripts/bootstrap.sh`](scripts/bootstrap.sh) | Clone fork + modules, patch Dockerfile, install override + `.env` |
| [`scripts/pull-client-data.sh`](scripts/pull-client-data.sh) | Download/extract wowgaming `Data.zip`, bind-mount via `DOCKER_VOL_DATA` |
| [`scripts/up.sh`](scripts/up.sh) | `docker compose up -d --build`, optional model pull |
| [`scripts/set-realm-address.sh`](scripts/set-realm-address.sh) | Set `realmlist.address` to a LAN IP (fixes realm-list bounce) |

## Troubleshooting

```bash
cd vendor/azerothcore-wotlk
docker compose ps
docker compose logs -f ac-worldserver
docker compose logs -f ac-ollama
docker exec ac-worldserver bash -lc 'curl -sS -m 3 http://ac-ollama:11434/api/tags'
```

- **Realm list loops after Okay (“Logging into game server” then back):** `realmlist.address` is probably `127.0.0.1` while the client is not on the Docker host’s localhost (VM / other PC). Run `./scripts/set-realm-address.sh` and put that IP in `realmlist.wtf`.
- **Realm shows Offline:** worldserver was down or the realm `flag` still has the offline bit after a restart. Ensure `ac-worldserver` is running, then `./scripts/set-realm-address.sh` (clears offline + restarts auth/world) or wait until world finishes loading bots.
- **Unknown database `acore_playerbots` / missing bot tables:** rebuild/re-run `ac-db-import` so module SQL under `modules/mod-playerbots` is applied; check worldserver logs on first boot.
- **`Duplicate filename ... playerbots_*.sql`:** do not copy module SQL into `data/sql/custom/` — db-import already loads modules and requires unique basenames. Remove those copies, rebuild `ac-db-import`, re-run import.
- **Bots online but silent:** confirm model is pulled, `AC_OLLAMA_CHAT_URL` is reachable from `ac-worldserver`, and `AC_OLLAMA_CHAT_ENABLE=1`.
- **Permission errors on etc/logs:** on Linux Docker Engine, set `DOCKER_USER_ID` / `DOCKER_GROUP_ID` in `.env` to your host uid/gid (both ≥ 1000) and recreate containers. On macOS keep `1000:1000`.
- **Rootless Podman permission denied on etc/logs/data:** host uid maps to container root, so `acore` cannot write bind mounts. This repo’s override sets `userns_mode: keep-id` for AC services. Prefer `./scripts/up.sh` (handles Podman startup quirks) over bare `docker compose up -d`.
- **Podman: `ac-authserver` / `ac-worldserver` stuck in Created / `--requires` errors:** known podman-compose nested-dependency bug. Use `./scripts/up.sh`, which starts auth/world without `--requires` after db-import succeeds.
- **Podman starts `ac-dev-server` and steals ports 3724/8085/7878:** podman-compose ignores Compose profiles. `./scripts/up.sh` starts only the production services; stop extras with `docker rm -f azerothcore-wotlk_ac-dev-server_1`.
- **`DOCKER_USER=root` did nothing:** that build arg only applies on image rebuild. Runtime user comes from the existing image (`acore`) unless you rebuild or use `userns_mode: keep-id` / a compose `user:` override.
- **`The GID '20' is already in use` (macOS build):** your `.env` mapped host `staff` (gid 20). Set `DOCKER_USER_ID=1000` and `DOCKER_GROUP_ID=1000` in `vendor/azerothcore-wotlk/.env`, then re-run `./scripts/up.sh`.
- **Out of memory:** lower `AC_AI_PLAYERBOT_MAX_RANDOM_BOTS` and use a smaller model.

## Non-goals (v1)

- Fine-tuned `wow-chat` models / QLoRA training
- [`mod-ollama-bot-buddy`](https://github.com/DustinHendrickson/mod-ollama-bot-buddy) (LLM controlling bot *actions*)
- Large 500-bot populated realms on modest hardware
- Shipping WoW client binaries or retail assets

## License

Orchestration scripts in this repository are provided as-is. Upstream AzerothCore, modules, and client-data retain their own licenses. You are responsible for owning a legitimate game client.
