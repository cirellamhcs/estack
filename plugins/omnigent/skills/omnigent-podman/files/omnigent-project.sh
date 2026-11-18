#!/usr/bin/env bash
# One extra Omnigent host per project, each in its own gVisor container.
#
#   omnigent-project create <name>   new folder + host, then sign it in
#   omnigent-project login <name> [omnigent|claude|codex]   (re)do a sign-in
#   omnigent-project start|stop <name>   (omnigent-podman.sh up starts all again)
#   omnigent-project rm <name>       remove container, network and home volume
#                                         (the project folder is kept)
#   omnigent-project ssh-key <name>  show the host's SSH public key (created once)
#   omnigent-project list
#
# Per project <name>:
#   folder     $PROJECTS_DIR/<name>  (mounted at /workspace; nothing else from your disk)
#   container  omnigent-host-<name>  (shows up as host "<name>" in the web UI)
#   volume     omnigent-host-<name>-home  (its own Claude/Codex/Omnigent logins)
#   network    omnigent-p-<name>, internal: only this host, the server and the
#              egress router (its default gateway). Internet yes, any protocol,
#              no proxy settings needed; no LAN, Tailscale, Postgres or other hosts.
#
# The stack from omnigent-podman must be up.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECTS_DIR="${OMNIGENT_PROJECTS_DIR:-$HOME/omnigent-projects}"

set_names() {
  name="${1:-}"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] \
    || die "Project name must be lowercase letters, digits and dashes (max 31 chars)"
  ctr="omnigent-host-$name"; vol="$ctr-home"; net="omnigent-p-$name"; dir="$PROJECTS_DIR/$name"
}

# Creates/upgrades the project network and sets HOST_OPTS.
opts() { host_opts "$net" "$vol"; }

need_project() { podman volume exists "$vol" || die "No project '$name' (see: $PROJECT_CMD list)"; }

start_host() {
  ensure_host_image
  mkdir -p "$dir"
  opts
  connect_infra "$net"
  running "$ctr" && [[ "$(podman inspect -f '{{.ImageName}}' "$ctr")" == "$HOST_IMAGE" ]] && return
  podman rm -f -t 10 "$ctr" >/dev/null 2>&1 || true
  podman run -d --name "$ctr" --hostname "$name" --label "$PROJECT_LABEL=$name" "${HOST_OPTS[@]}" \
    --restart unless-stopped \
    -v "$dir:/workspace" -w /workspace \
    "$HOST_IMAGE" \
    omnigent host --server "$INTERNAL_URL" --no-open --non-interactive >/dev/null
}

signed_in() {
  ensure_host_image
  opts
  podman run --rm "${HOST_OPTS[@]}" "$HOST_IMAGE" sh -c \
    "grep -qs 'omnigent-server' ~/.omnigent/auth_tokens.json" 2>/dev/null
}

do_login() {
  case "${1:-omnigent}" in
    omnigent)
      # The host stays signed in as this account and holds its token, so the
      # agents in this project can act as that account. Use a separate, non-admin
      # account per project if they must not reach your other projects.
      podman rm -f -t 5 "$ctr" >/dev/null 2>&1 || true
      ensure_host_image
      opts
      connect_infra "$net"
      log "Sign in the host for '$name' with an Omnigent account"
      podman run --rm -it "${HOST_OPTS[@]}" "$HOST_IMAGE" omnigent login "$INTERNAL_URL" || true
      start_host
      signed_in && log "Host '$name' signed in and started" \
        || die "Sign-in did not complete; run: $PROJECT_CMD login $name"
      ;;
    claude) ensure_host_image; opts; podman run --rm -it "${HOST_OPTS[@]}" "$HOST_IMAGE" claude auth login ;;
    codex)  ensure_host_image; opts; podman run --rm -it "${HOST_OPTS[@]}" "$HOST_IMAGE" codex login --device-auth ;;
    *) die "usage: $PROJECT_CMD login <name> [omnigent|claude|codex]" ;;
  esac
}

cmd="${1:-help}"
case "$cmd" in
  create)
    set_names "${2:-}"
    podman volume exists "$vol" && die "Project '$name' already exists"
    podman volume create --label "$PROJECT_LABEL=$name" "$vol" >/dev/null
    mkdir -p "$dir"
    log "Project '$name': folder $dir"
    do_login omnigent
    read -rp "Log Claude Code in for this project now? [Y/n] " a
    [[ "${a,,}" == n* ]] || do_login claude
    log "Done. In the web UI pick host '$name'; its files are in $dir"
    ;;
  login)
    set_names "${2:-}"; need_project; do_login "${3:-omnigent}"
    ;;
  ssh-key)
    set_names "${2:-}"; need_project; opts
    print_ssh_key "omnigent-$name"
    ;;
  start)
    set_names "${2:-}"; need_project; start_host; log "Started $ctr"
    ;;
  stop)
    set_names "${2:-}"; podman rm -f -t 10 "$ctr" >/dev/null 2>&1 || true; log "Stopped $ctr"
    ;;
  rm)
    set_names "${2:-}"; need_project
    read -rp "Remove host '$name' with its logins (folder $dir is kept)? [y/N] " a
    [[ "${a,,}" == y* ]] || exit 0
    podman rm -f -t 10 "$ctr" >/dev/null 2>&1 || true
    for c in omnigent-server "$EGRESS"; do
      podman network disconnect -f "$net" "$c" >/dev/null 2>&1 || true
    done
    podman network rm "$net" >/dev/null 2>&1 || true
    podman volume rm "$vol" >/dev/null 2>&1 || true
    log "Removed '$name'. It still appears offline in the web UI until you delete it there."
    ;;
  list)
    podman volume ls --filter "label=$PROJECT_LABEL" --format "{{index .Labels \"$PROJECT_LABEL\"}}" \
      | sort | while read -r n; do
        state="$(podman inspect -f '{{.State.Status}}' "omnigent-host-$n" 2>/dev/null || echo stopped)"
        printf '%-20s %-10s %s\n' "$n" "$state" "$PROJECTS_DIR/$n"
      done
    ;;
  *)
    sed -n '2,20p' "$LIB_DIR/omnigent-project.sh" | sed 's/^# \{0,1\}//'
    ;;
esac
