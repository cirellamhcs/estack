# Shared settings for omnigent-podman.sh and omnigent-project.sh (sourced, not run).
#
# Networks:
#   omnigent          server + Postgres (normal network; hosts are never on it)
#   omnigent-egress   proxy's way out to the internet
#   host networks     one per host, --internal (no route out). Only that host, the
#                     server and the egress proxy are on it. Labelled $HOSTNET_LABEL.
# Hosts reach the internet only through the proxy, which refuses LAN, Tailscale
# and this machine (see egress/squid.conf). SSH goes through it too (ports 22/443).

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Machine-specific settings (any OMNIGENT_* variable), kept out of the bundled files
# so updates never overwrite them. Example line: OMNIGENT_EXTRA_ORIGINS=http://myhost.lan:6767
if [[ -f "$LIB_DIR/settings.env" ]]; then set -a; source "$LIB_DIR/settings.env"; set +a; fi

# Omnigent 0.22.0 ("latest" from 2026-11-12), pinned by digest: ghcr.io stopped
# publishing version tags after v0.2.0. To update, pull :latest and replace the digests.
SERVER_IMAGE="${OMNIGENT_SERVER_IMAGE:-ghcr.io/omnigent-ai/omnigent-server@sha256:00ab68c8a05301a16137fa8fb2b632328743cb75ec594ad84077761a104e02e0}"
OFFICIAL_HOST_IMAGE="${OMNIGENT_HOST_IMAGE:-ghcr.io/omnigent-ai/omnigent-host@sha256:28f9f126d2125bbb6ba6b4463d2f81a758badbaf94ff77c4e1bc7d4c8333bca5}"
# What hosts actually run: the official image plus an SSH client routed through the
# egress proxy (host-image/). The tag changes whenever the base or those files do.
HOST_IMAGE="localhost/omnigent-host-ssh:$(cat "$LIB_DIR/host-image/"* <(echo "$OFFICIAL_HOST_IMAGE") | sha256sum | cut -c1-12)"
PG_IMAGE="docker.io/library/postgres:16-alpine"
# Squid 6.13 (ubuntu/squid:latest, 2025-11-24)
EGRESS_IMAGE="${OMNIGENT_EGRESS_IMAGE:-docker.io/ubuntu/squid@sha256:8fafd41d6ddceb295d26eea9938321d825ac5351c7e46cf6a8aa5d093b8ed1ce}"

INTERNAL_URL=http://omnigent-server:8000
NET=omnigent
EGRESS_NET=omnigent-egress
EGRESS=omnigent-egress
HOSTNET_LABEL=omnigent.hostnet
PROJECT_LABEL=omnigent.project
RUNTIME=runsc
# The host image's "sandbox" user; keep-id maps it to your own UID so files in
# mounted folders stay owned by you.
SANDBOX_ID=1000660000

PROXY_URL="http://${EGRESS}:3128"
NO_PROXY_LIST="omnigent-server,localhost,127.0.0.1"
# Both spellings: curl only reads lowercase http_proxy, some tools only uppercase.
PROXY_ENV=(-e "HTTPS_PROXY=$PROXY_URL" -e "HTTP_PROXY=$PROXY_URL"
  -e "https_proxy=$PROXY_URL" -e "http_proxy=$PROXY_URL"
  -e "NO_PROXY=$NO_PROXY_LIST" -e "no_proxy=$NO_PROXY_LIST")

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }
running() { [[ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# Options for anything that runs as a host's sandbox user.
#   host_opts <network> <home volume>  -> sets the array HOST_OPTS
host_opts() {
  HOST_OPTS=(--runtime="$RUNTIME" --network "$1"
    --userns "keep-id:uid=${SANDBOX_ID},gid=${SANDBOX_ID}" --user sandbox
    -e HOME=/home/sandbox -v "$2:/home/sandbox" "${PROXY_ENV[@]}")
}

# Build the host image if this version of it doesn't exist yet.
ensure_host_image() {
  podman image exists "$HOST_IMAGE" && return
  log "Building host image $HOST_IMAGE (official image + SSH via egress proxy)"
  podman build -q -t "$HOST_IMAGE" --build-arg "BASE=$OFFICIAL_HOST_IMAGE" "$LIB_DIR/host-image" >/dev/null
}

# Create this host's SSH key (once) and print its public key.
#   print_ssh_key <comment>   (uses HOST_OPTS)
print_ssh_key() {
  ensure_host_image
  podman run --rm "${HOST_OPTS[@]}" "$HOST_IMAGE" sh -c \
    "mkdir -p -m 700 ~/.ssh; test -f ~/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N '' -C '$1' -f ~/.ssh/id_ed25519; cat ~/.ssh/id_ed25519.pub"
}

host_networks() { podman network ls -q --filter "label=$HOSTNET_LABEL"; }

# Create an internal host network (extra args: more --label options).
ensure_host_network() {
  local net="$1"; shift
  podman network exists "$net" \
    || podman network create --internal --label "$HOSTNET_LABEL=1" "$@" "$net" >/dev/null
}

# Attach server and egress proxy to a host network (no-op if already attached).
connect_infra() {
  local net="$1" c
  for c in omnigent-server "$EGRESS"; do
    running "$c" || die "$c is not running; run ./omnigent-podman.sh up"
    podman inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c" \
      | grep -qw -- "$net" || podman network connect "$net" "$c"
  done
}

start_egress() {
  running "$EGRESS" && return
  podman rm -f "$EGRESS" >/dev/null 2>&1 || true
  podman network exists "$EGRESS_NET" || podman network create "$EGRESS_NET" >/dev/null
  log "Starting egress proxy (internet only; LAN, Tailscale and this machine refused)"
  local nets=(--network "$EGRESS_NET") n
  for n in $(host_networks); do nets+=(--network "$n"); done
  podman run -d --name "$EGRESS" --runtime="$RUNTIME" "${nets[@]}" --restart unless-stopped \
    -v "$LIB_DIR/egress/squid.conf:/etc/squid/squid.conf:ro" \
    "$EGRESS_IMAGE" >/dev/null
}
