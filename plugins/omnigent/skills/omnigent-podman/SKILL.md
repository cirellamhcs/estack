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

## Commands

The plugin puts two commands on the `PATH` of Claude's Bash tool and of `!` commands:
`omnigent-podman` (the stack) and `omnigent-project` (per-project hosts). They run the
scripts in place from the plugin, so there is nothing to copy or update by hand. If a
command isn't found (plugin just installed), use `/reload-plugins`, or call
`${CLAUDE_PLUGIN_ROOT}/bin/omnigent-podman` directly.

- **Settings:** `~/.config/omnigent-podman/settings.env` (one `OMNIGENT_*=value` per line, optional).
- **After a plugin update:** run `omnigent-podman up`. It rebuilds changed images, replaces the router and hosts that run old images, and upgrades old networks. Hosts restart from their volumes, so logins are kept.
- **Old installs:** an earlier version copied the scripts to a folder (e.g. `~/omnigent-podman`). Move its `settings.env` to `~/.config/omnigent-podman/`, then offer to delete that folder.

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

## Quick reference

| Goal | Command | Who runs it |
|---|---|---|
| Install Podman + gVisor (once per machine) | `omnigent-podman prereqs` | **User** (sudo) |
| One-time per-user setup | `omnigent-podman setup` | Claude |
| Start / stop everything | `omnigent-podman up` / `down` (volumes kept) | Claude |
| State, logs | `omnigent-podman status`, `logs server\|host\|postgres\|egress` | Claude |
| New project host | `omnigent-project create <name>` | **User** (prompts) |
| List / start / stop | `omnigent-project list`, `start\|stop <name>` | Claude |
| Sign in | `omnigent-podman host-login`, `login claude\|codex`; project: `omnigent-project login <name> [omnigent\|claude\|codex]` | **User** |
| SSH key | `omnigent-podman ssh-key`, `omnigent-project ssh-key <name>` | Claude; the user adds the key (per-repo deploy key) |
| Remove project | `omnigent-project rm <name>` (keeps the folder) | User confirms |

The commands marked **User** need a terminal. Give the user a line to type themselves:
`! omnigent-project create <name>`. The same goes for `omnigent-podman prereqs` (sudo).

Folders: the main host uses `~/omnigent-workspace`, and projects use `~/omnigent-projects/<name>`. Both are mounted at `/workspace`.
Web UI: `up` prints the URL, which is this machine's first IP on port 6767. The login uses Omnigent's own accounts, and the first visitor creates the admin account.

## Isolation: say this when relevant

- **Tokens:** a host keeps a *full-authority* token of the account it signed in with, and its agents can use it against the API. Real separation between projects needs a separate **non-admin** Omnigent account per project.
- **No sandbox inside the host:** native Claude Code (`claude-native-ui`) runs unsandboxed inside its host. The YAML `os_env.sandbox` setting and the `enforce_sandbox` policy only affect Omnigent's `sys_os_*` tools. The container is the boundary.
- **Network:** everything goes out through the router transparently (TCP, UDP, DNS). Only ping fails, because gVisor doesn't give the unprivileged user ICMP sockets.
- **Credentials:** never mount `~/.ssh`, `~/.claude` or other host folders into hosts.

Install steps, every gotcha and troubleshooting: see `reference.md` in this skill directory.
