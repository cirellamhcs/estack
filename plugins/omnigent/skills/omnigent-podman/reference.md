# omnigent-podman reference

## Install on a new machine (Ubuntu/Debian)

1. Copy the bundled `files/` to the install directory (see SKILL.md).
2. The **user** runs `sudo bash install-prereqs.sh`. It installs podman, passt, uidmap and runsc (from the gVisor apt repository).
3. Run `./omnigent-podman.sh setup`. It creates `~/.local/bin/runsc-rootless`, registers it in `~/.config/containers/containers.conf` and checks the subordinate UID range. If the range is too small, it prints a `sudo usermod --add-subuids ...` command for the **user** to run.
4. Run `./omnigent-podman.sh up`. The user opens the printed URL and creates the admin account.
5. The **user** runs `./omnigent-podman.sh host-login`, then `./omnigent-podman.sh login claude`.

Tested with Podman 5.7.0, runsc release-20261116.0, Omnigent 0.22.0 and Squid 6.13.

Settings: environment variables, or put them in `settings.env` in the install directory
(one `NAME=value` per line; never overwritten by updates): `OMNIGENT_PORT` (6767), `OMNIGENT_BIND` (0.0.0.0),
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
| curl ignores the proxy for http:// | curl reads only lowercase `http_proxy` | both spellings set in `PROXY_ENV` |
| ssh: "Bad owner or permissions" on its config | COPY kept mode 664 | `COPY --chmod=644` |
| Host can't reach the server | `NO_PROXY` missing, or server not on the host network | `NO_PROXY=omnigent-server,...`; `connect_infra` in `start` / `up` |

bubblewrap works inside gVisor without changes. There is no Podman provider for
Omnigent "managed hosts" (per-session sandboxes); this setup uses one long-running
host per project instead.

## Troubleshooting

- **Refused requests:** `./omnigent-podman.sh logs egress | grep TCP_DENIED`.
- **Host network check:** `podman exec omnigent-host curl -s -o /dev/null -w '%{http_code}' https://github.com` should print 200; a LAN address should print 403.
- **SSH to a LAN address:** "Connection closed by UNKNOWN port 65535" means the proxy refused it, as intended.
- **Proxy rules changed:** run `podman restart omnigent-egress`.
- **Files in `host-image/` or the base digest changed:** the image tag changes. Then run `stop` + `start` for each project, and `podman rm -f omnigent-host && ./omnigent-podman.sh up`.
- **After `rm`:** the host stays listed as offline in the web UI. Delete it there.
