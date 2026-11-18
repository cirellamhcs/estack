# omnigent-podman reference

## Install on a new machine (Ubuntu/Debian)

1. The **user** runs `omnigent-podman prereqs`. It installs podman, passt, uidmap and runsc (from the gVisor apt repository) with sudo.
2. Run `omnigent-podman setup`. It creates `~/.local/bin/runsc-rootless`, registers it in `~/.config/containers/containers.conf` and checks the subordinate UID range. If the range is too small, it prints a `sudo usermod --add-subuids ...` command for the **user** to run.
3. Run `omnigent-podman up`. The user opens the printed URL and creates the admin account.
4. The **user** runs `omnigent-podman host-login`, then `omnigent-podman login claude`.

Tested with Podman 5.7.0, runsc release-20261116.0, Omnigent 0.22.0 and Alpine 3.22.8 (nftables, dnsmasq) for the router.

Settings: environment variables, or `~/.config/omnigent-podman/settings.env`
(one `NAME=value` per line; outside the plugin, so updates never touch it): `OMNIGENT_PORT` (6767), `OMNIGENT_BIND` (0.0.0.0),
`OMNIGENT_BASE_URL`, `OMNIGENT_EXTRA_ORIGINS` (comma-separated browser origins, e.g. a
DNS or Tailscale name), `OMNIGENT_WORKSPACE`, `OMNIGENT_PROJECTS_DIR`,
`OMNIGENT_GRANT_MAX_LIFETIME_DAYS` (365).

## Gotchas (and how the scripts handle them)

| Symptom | Cause | Fix in place |
|---|---|---|
| runsc: "Access denied ... interactive authentication" | no systemd cgroup delegation in rootless mode | `--ignore-cgroups` wrapper (`setup`) |
| "insufficient UIDs ... 1000660000" when pulling | host image UID out of range | larger subuid range (`setup` checks it) |
| `-p` port: connection reset | rootless port forwarder can't reach the gVisor netstack | server uses `--runtime-flag=network=host`; hosts keep netstack |
| Upload: "requires a trusted Origin header" | single-user mode trusts only loopback | `OMNIGENT_WS_ALLOWED_ORIGINS`, built by `allowed_origins()`; extra entries via `OMNIGENT_EXTRA_ORIGINS` |
| No version tags newer than v0.2.0 on ghcr | upstream only publishes `:latest` | pin `:latest` by digest in `lib.sh` |
| Host restarts in a loop, no host in the UI | not signed in | `host-login`, which runs in a one-off container with the host stopped |
| Host signed out after a while | grant lifetime | `OMNIGENT_GRANT_MAX_LIFETIME_DAYS=365` |
| Claude login: "getaddrinfo ENOTFOUND platform.claude.com" | old proxy setup: Claude Code's OAuth login ignores `HTTP(S)_PROXY` | replaced by the transparent egress router; run `up` to upgrade |
| ssh: "Bad owner or permissions" on its config | COPY kept mode 664 | `COPY --chmod=644` |
| No internet, router logs show the wrong egress interface | each host network's default route (via the router) is installed in the router too | `router.sh` deletes self-pointing default routes every 2 s |
| Claude in a host: "Auto-update failed: no write permission to npm prefix" | the CLIs are root-owned in the image; hosts run as `sandbox` | `DISABLE_AUTOUPDATER=1` in `host_opts`; CLIs update with the pinned host image |
| A file the agent created is missing from the project folder | the session ran in the default workspace `~` = `/home/sandbox` (home volume), not `/workspace` | start sessions with folder `/workspace`; find stray files with `podman exec <host> find /home/sandbox -newer /etc/hostname -type f -not -path "*/.*"` |
| "Netlink error: No such process" when a host stops | Podman removing the custom route after gVisor took the interface | harmless |
| Host can't reach the server | server not on the host network, or not at `.3` | `connect_infra` in `start` / `up`; hosts get `--add-host omnigent-server:<.3>` because host networks have no Podman DNS |

bubblewrap works inside gVisor without changes. There is no Podman provider for
Omnigent "managed hosts" (per-session sandboxes); this setup uses one long-running
host per project instead.

## Troubleshooting

- **Host network check:** `podman exec omnigent-host curl -s -o /dev/null -m5 -w '%{http_code}' https://github.com` should print 200; a LAN address should time out (dropped).
- **Router state:** `podman exec omnigent-egress ip -4 route` (one default route, via the egress network) and `podman exec omnigent-egress nft list ruleset`.
- **Router rules changed:** run `omnigent-podman up`, which rebuilds and replaces the router.
- **Files in `host-image/` or the base digest changed:** the image tag changes. `omnigent-podman up` replaces the hosts that run an old image.
- **After `rm`:** the host stays listed as offline in the web UI. Delete it there.
