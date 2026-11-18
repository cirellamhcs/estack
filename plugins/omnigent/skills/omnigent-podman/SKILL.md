---
name: omnigent-podman
description: Use when installing, running or troubleshooting Omnigent (server, hosts, web UI on port 6767) in rootless Podman with gVisor, including starting, stopping, logs, sign-in problems, creating or removing per-project hosts, SSH keys for hosts, the egress router, network or sandboxing/isolation questions, or setting it up on a new machine.
---

# Omnigent in rootless Podman + gVisor

## Overview

Omnigent runs entirely in rootless Podman containers under gVisor (`runsc`), so
agents never touch the real kernel or the user's home directory. Each project gets
its own host container with only its own folder mounted, its own logins and its
own internal network. The scripts are bundled with this skill.

## Find the install directory first

The install directory is `$OMNIGENT_PODMAN_DIR` if that is set, else `~/omnigent-podman`.
If neither exists, search: `find ~ -maxdepth 4 -name omnigent-podman.sh -not -path '*/.claude*'`.

- **Found:** run every command below from there. Then check for a newer bundled version:
  `diff -rq "${CLAUDE_PLUGIN_ROOT}/skills/omnigent-podman/files" <dir>`. If it differs, show
  the user the diff and offer to copy the bundled files over with
  `cp -r "${CLAUDE_PLUGIN_ROOT}/skills/omnigent-podman/files/." <dir>/`. `settings.env` (the user's
  own settings) is not bundled and must be kept. Then run `./omnigent-podman.sh up`: it
  rebuilds changed images, replaces the router and hosts that run old images and
  upgrades old networks (hosts restart from their volumes, so logins are kept).
- **Not found (fresh install):** copy the files to `~/omnigent-podman`, or to a folder the user names:
  `cp -r "${CLAUDE_PLUGIN_ROOT}/skills/omnigent-podman/files" ~/omnigent-podman`.
  Never run the scripts from the plugin directory. It is replaced on every plugin
  update.
  Then follow the install steps in `reference.md`.

## Architecture

```
browser ──LAN──> :6767 omnigent-server ──net omnigent── omnigent-postgres
                        │ (joins every host network)
   omnigent-host     ── omnigent-hostnet-main (internal) ──┐  default route
   omnigent-host-<p> ── omnigent-p-<p>        (internal) ──┤  of every host
                                                           └─ omnigent-egress (router, NAT) ──> internet
```

- **Host networks:** every host network is `--internal` (subnet `10.90.N.0/24`), with only that host, the router (`.2`) and the server (`.3`) on it. The network's default route points at the router.
- **Egress router:** `egress/router.sh` (Alpine with nftables and dnsmasq, normal runtime because it needs the kernel's netfilter). It forwards and NATs any protocol and port to public addresses, drops private, Tailscale and loopback ranges, never forwards between host networks, and serves DNS while refusing private answers (DNS rebinding). Hosts need no proxy settings.
- **Host image:** hosts run `localhost/omnigent-host-ssh:<hash>`, built automatically from `host-image/`: the official image plus an SSH client.
- **Pinned images:** image digests are pinned in `lib.sh`, which both scripts use.

## Quick reference (run in the install directory)

| Goal | Command | Who runs it |
|---|---|---|
| One-time per-user setup | `./omnigent-podman.sh setup` | Claude |
| Start / stop everything | `./omnigent-podman.sh up` / `down` (volumes kept) | Claude |
| State, logs | `./omnigent-podman.sh status`, `logs server\|host\|postgres\|egress` | Claude |
| New project host | `./omnigent-project.sh create <name>` | **User** (prompts) |
| List / start / stop | `./omnigent-project.sh list`, `start\|stop <name>` | Claude |
| Sign in | `./omnigent-podman.sh host-login`, `login claude\|codex`; project: `./omnigent-project.sh login <name> [omnigent\|claude\|codex]` | **User** |
| SSH key | `./omnigent-podman.sh ssh-key`, `./omnigent-project.sh ssh-key <name>` | Claude; the user adds the key (per-repo deploy key) |
| Remove project | `./omnigent-project.sh rm <name>` (keeps the folder) | User confirms |

The commands marked **User** need a terminal. Give the user a line to type themselves:
`! cd <install dir> && ./omnigent-project.sh create <name>`. The same goes for every `sudo` step.

Folders: the main host uses `~/omnigent-workspace`, and projects use `~/omnigent-projects/<name>`. Both are mounted at `/workspace`.
Web UI: `up` prints the URL, which is this machine's first IP on port 6767. The login uses Omnigent's own accounts, and the first visitor creates the admin account.

## Isolation: say this when relevant

- **Tokens:** a host keeps a *full-authority* token of the account it signed in with, and its agents can use it against the API. Real separation between projects needs a separate **non-admin** Omnigent account per project.
- **No sandbox inside the host:** native Claude Code (`claude-native-ui`) runs unsandboxed inside its host. The YAML `os_env.sandbox` setting and the `enforce_sandbox` policy only affect Omnigent's `sys_os_*` tools. The container is the boundary.
- **Network:** everything goes out through the router transparently (TCP, UDP, DNS). Only ping fails, because gVisor doesn't give the unprivileged user ICMP sockets.
- **Credentials:** never mount `~/.ssh`, `~/.claude` or other host folders into hosts.

Install steps, every gotcha and troubleshooting: see `reference.md` in this skill directory.
