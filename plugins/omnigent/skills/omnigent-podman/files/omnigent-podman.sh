#!/usr/bin/env bash
# Omnigent (server + host) in rootless Podman containers under gVisor.
#
#   ./omnigent-podman.sh setup     one-time per-user setup (gVisor runtime, UID check)
#   ./omnigent-podman.sh up        start everything (idempotent)
#   ./omnigent-podman.sh down      stop and remove containers (keeps volumes + data)
#   ./omnigent-podman.sh status    show container state
#   ./omnigent-podman.sh logs [server|host|postgres|egress]
#   ./omnigent-podman.sh password  show the admin login, if Omnigent generated one
#   ./omnigent-podman.sh host-login   sign the main host in to the server (needed once)
#   ./omnigent-podman.sh login [claude|codex]   log an agent CLI in, inside the main host
#   ./omnigent-podman.sh ssh-key   show the main host's SSH public key (created once)
#   ./omnigent-podman.sh shell     open a shell in the main host
#
# Web UI: http://<this machine>:6767, from the LAN too, with Omnigent's built-in
# accounts login. Each host sits on its own internal network with the server and
# the egress router, its default gateway: the internet yes, LAN/Tailscale/this
# machine no, without any proxy settings inside the host.
# The main host sees only $WORKSPACE; per-project hosts: ./omnigent-project.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKSPACE="${OMNIGENT_WORKSPACE:-$HOME/omnigent-workspace}"
PORT="${OMNIGENT_PORT:-6767}"
BIND="${OMNIGENT_BIND:-0.0.0.0}"
# The URL people open in the browser; used for login redirects and links.
BASE_URL="${OMNIGENT_BASE_URL:-http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT}}"
# How long a host's sign-in stays valid before it must sign in again.
# Omnigent's default is 30 days; extended because hosts run unattended.
GRANT_DAYS="${OMNIGENT_GRANT_MAX_LIFETIME_DAYS:-365}"
MAIN_NET=omnigent-hostnet-main
MAIN_VOL=omnigent-host-home
main_opts() { host_opts "$MAIN_NET" "$MAIN_VOL"; }

RUNSC_WRAPPER="$HOME/.local/bin/runsc-rootless"
CONTAINERS_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/containers/containers.conf"

# Rootless gVisor needs --ignore-cgroups (no systemd cgroup delegation), so Podman
# gets a small wrapper registered as the runtime "runsc".
setup_runtime() {
  command -v runsc >/dev/null || die "runsc not found; first run: sudo bash install-prereqs.sh"
  if [[ ! -x "$RUNSC_WRAPPER" ]]; then
    mkdir -p "$(dirname "$RUNSC_WRAPPER")"
    printf '#!/bin/sh\n# gVisor for rootless Podman: no systemd cgroup delegation, so skip cgroups.\nexec %s --ignore-cgroups "$@"\n' \
      "$(command -v runsc)" > "$RUNSC_WRAPPER"
    chmod +x "$RUNSC_WRAPPER"
    log "Created $RUNSC_WRAPPER"
  fi
  if ! grep -qs '^runsc *=' "$CONTAINERS_CONF"; then
    mkdir -p "$(dirname "$CONTAINERS_CONF")"
    if grep -qs '^\[engine.runtimes\]' "$CONTAINERS_CONF"; then
      die "Add this line under [engine.runtimes] in $CONTAINERS_CONF: runsc = [\"$RUNSC_WRAPPER\"]"
    fi
    printf '\n[engine.runtimes]\nrunsc = ["%s"]\n' "$RUNSC_WRAPPER" >> "$CONTAINERS_CONF"
    log "Registered runtime runsc in $CONTAINERS_CONF"
  fi
  # The host image's user has UID $SANDBOX_ID, far above the usual 65536 subordinate
  # UIDs, so rootless Podman needs a much larger range.
  local need=$((SANDBOX_ID + 65536)) have
  have=$(awk -F: -v u="$(id -un)" '$1==u {s+=$3} END {print s+0}' /etc/subuid)
  if (( have < need )); then
    echo "Your user needs more subordinate UIDs/GIDs (has $have, needs $need). Run:" >&2
    echo "  sudo usermod --add-subuids 165536-1000865535 --add-subgids 165536-1000865535 $(id -un) && podman system migrate" >&2
    echo "(pick another start if 165536.. is already used by another user in /etc/subuid)" >&2
    exit 1
  fi
  log "Runtime ready"
}

runtime_ready() {
  [[ -x "$RUNSC_WRAPPER" ]] && grep -qs '^runsc *=' "$CONTAINERS_CONF"
}

ensure_basics() {
  runtime_ready || die "gVisor runtime not set up yet; run: $0 setup"
  podman network exists "$NET" || podman network create "$NET" >/dev/null
  ensure_host_network "$MAIN_NET"
  for v in omnigent-pg omnigent-data "$MAIN_VOL"; do
    podman volume exists "$v" || podman volume create "$v" >/dev/null
  done
  mkdir -p "$WORKSPACE"
  if ! podman secret exists omnigent-pg-password; then
    local pw; pw="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
    printf '%s' "$pw" | podman secret create omnigent-pg-password - >/dev/null
    printf 'postgresql+psycopg://omnigent:%s@omnigent-postgres:5432/omnigent' "$pw" \
      | podman secret create omnigent-database-url - >/dev/null
    log "Created Postgres password (Podman secrets omnigent-pg-password, omnigent-database-url)"
  fi
}

# Browser Origins the server should trust: loopback, this machine's IPs and names,
# plus anything in $OMNIGENT_EXTRA_ORIGINS (comma-separated, e.g. a DNS name).
allowed_origins() {
  local hosts=(localhost 127.0.0.1 "$(hostname)") h ts
  hosts+=($(ip -4 -o addr show scope global 2>/dev/null \
    | awk '$2 !~ /^(docker|br-|veth|podman|cni)/ {split($4,a,"/"); print a[1]}'))
  hosts+=("$(hostname).local")
  if ts="$(tailscale status --self --json 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null)" \
      && [[ -n "$ts" ]]; then
    hosts+=("$ts")
  fi
  local out=()
  for h in "${hosts[@]}"; do out+=("http://${h}:${PORT}"); done
  [[ -n "${OMNIGENT_EXTRA_ORIGINS:-}" ]] && out+=("$OMNIGENT_EXTRA_ORIGINS")
  (IFS=,; echo "${out[*]}")
}

start_postgres() {
  running omnigent-postgres && return
  podman rm -f omnigent-postgres >/dev/null 2>&1 || true
  log "Starting Postgres"
  podman run -d --name omnigent-postgres --runtime="$RUNTIME" --network "$NET" \
    --restart unless-stopped \
    -e POSTGRES_DB=omnigent -e POSTGRES_USER=omnigent \
    --secret omnigent-pg-password -e POSTGRES_PASSWORD_FILE=/run/secrets/omnigent-pg-password \
    -v omnigent-pg:/var/lib/postgresql/data \
    "$PG_IMAGE" >/dev/null
  for _ in $(seq 60); do
    podman exec omnigent-postgres pg_isready -q -U omnigent -d omnigent 2>/dev/null && return
    sleep 1
  done
  die "Postgres did not become ready"
}

start_server() {
  running omnigent-server && return
  podman rm -f omnigent-server >/dev/null 2>&1 || true
  log "Starting Omnigent server on ${BIND}:${PORT} (accounts login, base URL ${BASE_URL})"
  # Also join every host network at its fixed address, so the hosts can reach us.
  infra_networks $SERVER_OCTET
  # network=host: gVisor uses the container's own netns via the kernel stack instead
  # of netstack, because rootless Podman's port forwarder (-p) can't reach a netstack
  # sandbox. The server runs no agent code; hosts keep netstack.
  podman run -d --name omnigent-server --runtime="$RUNTIME" --runtime-flag=network=host \
    --network "$NET" "${INFRA_NETS[@]}" --restart unless-stopped \
    --secret omnigent-database-url,type=env,target=DATABASE_URL \
    -e ARTIFACT_DIR=/data/artifacts \
    -e OMNIGENT_AUTH_ENABLED=1 \
    -e OMNIGENT_AUTH_PROVIDER=accounts \
    -e OMNIGENT_ACCOUNTS_BASE_URL="$BASE_URL" \
    -e OMNIGENT_ADMIN_CREDENTIALS_PATH=/data/admin-credentials \
    -e OMNIGENT_ACCOUNTS_AUTO_OPEN=0 \
    -e OMNIGENT_GRANT_MAX_LIFETIME_DAYS="$GRANT_DAYS" \
    -e OMNIGENT_WS_ALLOWED_ORIGINS="$(allowed_origins)" \
    -v omnigent-data:/data \
    -p "${BIND}:${PORT}:8000" \
    "$SERVER_IMAGE" >/dev/null
  for _ in $(seq 90); do
    curl -sf -m3 "http://127.0.0.1:${PORT}/health" >/dev/null && return
    running omnigent-server || break
    sleep 1
  done
  die "Server did not become healthy; see: $0 logs server"
}

start_host() {
  ensure_host_image
  main_opts
  connect_infra "$MAIN_NET"
  running omnigent-host \
    && [[ "$(podman inspect -f '{{.ImageName}}' omnigent-host)" == "$HOST_IMAGE" ]] && return
  podman rm -f -t 10 omnigent-host >/dev/null 2>&1 || true
  log "Starting main Omnigent host (sees only $WORKSPACE as /workspace)"
  podman run -d --name omnigent-host --hostname omnigent-host "${HOST_OPTS[@]}" \
    --restart unless-stopped \
    -v "$WORKSPACE:/workspace" -w /workspace \
    "$HOST_IMAGE" \
    omnigent host --server "$INTERNAL_URL" --no-open --non-interactive >/dev/null
}

# Checked in a throwaway container: an unsigned host keeps exiting and restarting.
host_signed_in() {
  ensure_host_image
  main_opts
  podman run --rm "${HOST_OPTS[@]}" "$HOST_IMAGE" sh -c \
    "grep -qs 'omnigent-server' ~/.omnigent/auth_tokens.json" 2>/dev/null
}

cmd="${1:-help}"
case "$cmd" in
  setup)
    setup_runtime
    log "Next: $0 up"
    ;;
  up)
    ensure_basics; start_postgres; start_server; start_egress; start_host
    # Every project (found by its home volume) gets its host back.
    for p in $(podman volume ls --filter "label=$PROJECT_LABEL" --format "{{index .Labels \"$PROJECT_LABEL\"}}"); do
      "$LIB_DIR/omnigent-project.sh" start "$p" >/dev/null && log "Started project host '$p'"
    done
    log "Up. Web UI: ${BASE_URL}"
    log "First start? Open it and create the admin account (the first visitor becomes admin)."
    host_signed_in || log "Main host is not signed in yet; run: $0 host-login"
    ;;
  down)
    podman rm -f -t 10 $(podman ps -a -q --filter "label=$PROJECT_LABEL") \
      omnigent-host "$EGRESS" omnigent-server omnigent-postgres >/dev/null 2>&1 || true
    log "Stopped all containers (volumes, data and project folders kept)"
    ;;
  status)
    podman ps -a --filter "name=^omnigent-" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    ;;
  logs)
    podman logs --tail "${TAIL:-100}" "omnigent-${2:-host}"
    ;;
  password)
    podman exec omnigent-server cat /data/admin-credentials 2>/dev/null \
      || echo "No generated admin password: create the first admin account at ${BASE_URL}"
    ;;
  host-login)
    # Stop the host first: without a sign-in it restarts every few seconds, which
    # would kill a login running inside it. Sign in from a one-off container that
    # shares the host's home volume, then start the host again.
    podman rm -f -t 5 omnigent-host >/dev/null 2>&1 || true
    ensure_host_image; main_opts
    connect_infra "$MAIN_NET"
    log "Sign in with your Omnigent account (the one you created in the web UI)"
    podman run --rm -it "${HOST_OPTS[@]}" "$HOST_IMAGE" omnigent login "$INTERNAL_URL" || true
    start_host
    host_signed_in && log "Host signed in and started" \
      || die "Sign-in did not complete; run $0 host-login again"
    ;;
  login)
    ensure_host_image; main_opts
    case "${2:-claude}" in
      claude) podman run --rm -it "${HOST_OPTS[@]}" "$HOST_IMAGE" claude auth login ;;
      codex)  podman run --rm -it "${HOST_OPTS[@]}" "$HOST_IMAGE" codex login --device-auth ;;
      *) die "usage: $0 login [claude|codex]" ;;
    esac
    ;;
  ssh-key)
    main_opts; print_ssh_key omnigent-host
    ;;
  shell)
    podman exec -it omnigent-host bash
    ;;
  *)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
