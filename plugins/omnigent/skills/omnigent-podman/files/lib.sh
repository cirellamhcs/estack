# Shared settings for omnigent-podman.sh and omnigent-project.sh (sourced, not run).
#
# Networks:
#   omnigent          server + Postgres (normal network; hosts are never on it)
#   omnigent-egress   the egress router's way out to the internet
#   host networks     one per host, --internal (no way out of their own). Only that
#                     host, the server (.3) and the egress router (.2) are on it, and
#                     the network's default route points at the router. Labelled
#                     $HOSTNET_LABEL, subnets 10.90.N.0/24.
# The router (egress/) forwards and NATs everything a host sends to the internet,
# any protocol, and drops anything to private, Tailscale or loopback addresses. It
# also answers DNS. Nothing inside a host has to know about it.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Command names as the user types them (bin/ wrappers on PATH while the plugin is enabled).
PODMAN_CMD=omnigent-podman
PROJECT_CMD=omnigent-project
# Machine-specific settings (any OMNIGENT_* variable, one NAME=value per line), kept
# outside the plugin so updates never touch them.
# Example line: OMNIGENT_EXTRA_ORIGINS=http://myhost.lan:6767
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omnigent-podman"
SETTINGS_FILE="$CONFIG_DIR/settings.env"
if [[ -f "$SETTINGS_FILE" ]]; then set -a; source "$SETTINGS_FILE"; set +a; fi

# Omnigent 0.22.0 ("latest" from 2026-11-12), pinned by digest: ghcr.io stopped
# publishing version tags after v0.2.0. To update, pull :latest and replace the digests.
SERVER_IMAGE="${OMNIGENT_SERVER_IMAGE:-ghcr.io/omnigent-ai/omnigent-server@sha256:00ab68c8a05301a16137fa8fb2b632328743cb75ec594ad84077761a104e02e0}"
OFFICIAL_HOST_IMAGE="${OMNIGENT_HOST_IMAGE:-ghcr.io/omnigent-ai/omnigent-host@sha256:28f9f126d2125bbb6ba6b4463d2f81a758badbaf94ff77c4e1bc7d4c8333bca5}"
PG_IMAGE="docker.io/library/postgres:16-alpine"
# Alpine 3.22.8, base of the egress router image.
ROUTER_BASE_IMAGE="docker.io/library/alpine@sha256:9db2934886712d877c932e07249c75a59e6ca27adfbccc05261987a17bef2d63"
# Locally built images; the tag changes whenever their base or files do.
img_hash() { cat "$LIB_DIR/$1/"* <(echo "$2") | sha256sum | cut -c1-12; }
HOST_IMAGE="localhost/omnigent-host-ssh:$(img_hash host-image "$OFFICIAL_HOST_IMAGE")"
EGRESS_IMAGE="localhost/omnigent-egress:$(img_hash egress "$ROUTER_BASE_IMAGE")"

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
# Fixed addresses on every host network.
ROUTER_OCTET=2
SERVER_OCTET=3

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { echo "$*" >&2; exit 1; }
running() { [[ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# net_ip <network> <last octet>  ->  e.g. 10.90.4.2
net_ip() {
  local sub
  sub="$(podman network inspect -f '{{range .Subnets}}{{.Subnet}}{{end}}' "$1")" || return 1
  echo "${sub%.*/*}.$2"
}

host_networks() { podman network ls -q --filter "label=$HOSTNET_LABEL"; }

# Create a host network (internal, default route via the router), or replace one
# made by an older version of these scripts (proxy era: no route). Replacing it
# removes the host container on it; the next start recreates it from its volume.
ensure_host_network() {
  local net="$1" labels=(--label "$HOSTNET_LABEL=1") n c
  [[ "$net" == omnigent-p-* ]] && labels+=(--label "$PROJECT_LABEL=${net#omnigent-p-}")
  if podman network exists "$net"; then
    [[ "$(podman network inspect -f '{{index .Labels "omnigent.routed"}}' "$net")" == 1 ]] && return
    log "Upgrading network $net to the egress router"
    for c in $(podman ps -a --filter "network=$net" --format '{{.Names}}'); do
      case "$c" in
        omnigent-server|"$EGRESS") podman network disconnect -f "$net" "$c" >/dev/null ;;
        *) podman rm -f -t 10 "$c" >/dev/null ;;
      esac
    done
    podman network rm "$net" >/dev/null
  fi
  local used; used="$(podman network ls --format '{{range .Subnets}}{{.Subnet}} {{end}}' | tr '\n' ' ')"
  for n in $(seq 1 254); do
    [[ " $used " == *" 10.90.$n.0/24 "* ]] && continue
    podman network create --internal --disable-dns --subnet "10.90.$n.0/24" \
      --route "0.0.0.0/0,10.90.$n.$ROUTER_OCTET" "${labels[@]}" --label omnigent.routed=1 \
      "$net" >/dev/null
    return
  done
  die "No free 10.90.N.0/24 subnet left"
}

# Options for anything that runs as a host's sandbox user (creates the network if
# needed). DNS comes from the router; the server is pinned in /etc/hosts.
#   host_opts <network> <home volume>  -> sets the array HOST_OPTS
host_opts() {
  ensure_host_network "$1"
  HOST_OPTS=(--runtime="$RUNTIME" --network "$1"
    --dns "$(net_ip "$1" $ROUTER_OCTET)" --add-host "omnigent-server:$(net_ip "$1" $SERVER_OCTET)"
    --userns "keep-id:uid=${SANDBOX_ID},gid=${SANDBOX_ID}" --user sandbox
    -e HOME=/home/sandbox -v "$2:/home/sandbox")
}

# --network options with the fixed address on each host network.
#   infra_networks <octet>  -> sets the array INFRA_NETS
infra_networks() {
  local n; INFRA_NETS=()
  for n in $(host_networks); do ensure_host_network "$n"; done  # upgrade old ones first
  for n in $(host_networks); do INFRA_NETS+=(--network "$n:ip=$(net_ip "$n" "$1")"); done
}

# Attach server and router to a host network at their fixed addresses.
connect_infra() {
  local net="$1" c ip
  for c in omnigent-server "$EGRESS"; do
    running "$c" || die "$c is not running; run: $PODMAN_CMD up"
    [[ "$c" == "$EGRESS" ]] && ip="$(net_ip "$net" $ROUTER_OCTET)" || ip="$(net_ip "$net" $SERVER_OCTET)"
    podman inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c" \
      | grep -qw -- "$net" || podman network connect --ip "$ip" "$net" "$c"
  done
}

build_image() {  # build_image <tag> <dir> <base> <what>
  podman image exists "$1" && return
  log "Building $4 image $1"
  podman build -q -t "$1" --build-arg "BASE=$3" "$LIB_DIR/$2" >/dev/null
}
ensure_host_image() { build_image "$HOST_IMAGE" host-image "$OFFICIAL_HOST_IMAGE" host; }

# Create this host's SSH key (once) and print its public key.
#   print_ssh_key <comment>   (uses HOST_OPTS)
print_ssh_key() {
  ensure_host_image
  podman run --rm "${HOST_OPTS[@]}" "$HOST_IMAGE" sh -c \
    "mkdir -p -m 700 ~/.ssh; test -f ~/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N '' -C '$1' -f ~/.ssh/id_ed25519; cat ~/.ssh/id_ed25519.pub"
}

# The egress router runs with the normal runtime (crun), not gVisor: it needs the
# real kernel's netfilter. It runs no agent code, only routes and filters packets.
start_egress() {
  if running "$EGRESS"; then
    [[ "$(podman inspect -f '{{.ImageName}}' "$EGRESS")" == "$EGRESS_IMAGE" ]] && return
    log "Egress router image changed; replacing it"
  fi
  build_image "$EGRESS_IMAGE" egress "$ROUTER_BASE_IMAGE" "egress router"
  podman rm -f -t 2 "$EGRESS" >/dev/null 2>&1 || true
  podman network exists "$EGRESS_NET" || podman network create "$EGRESS_NET" >/dev/null
  log "Starting egress router (internet only; LAN, Tailscale and this machine dropped)"
  infra_networks $ROUTER_OCTET
  # The egress network must come first: the router uses its first interface's
  # default route as the way out.
  podman run -d --name "$EGRESS" --network "$EGRESS_NET" "${INFRA_NETS[@]}" \
    --cap-add NET_ADMIN,NET_RAW --sysctl net.ipv4.ip_forward=1 \
    --restart unless-stopped "$EGRESS_IMAGE" >/dev/null
}
