# estack

Claude Code plugins and skills.

## Install

In Claude Code:

```
/plugin marketplace add cirellamhcs/estack
/plugin install omnigent@estack
```

To get updates automatically, open `/plugin`, go to **Marketplaces**, select
`estack` and choose **Enable auto-update**. Otherwise update with
`/plugin marketplace update estack`.

If you have no GitHub SSH key, set `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` before
adding the marketplace.

## Plugins

| Plugin | Skills | What it's for |
|---|---|---|
| `omnigent` | `omnigent-podman` | Run [Omnigent](https://github.com/omnigent-ai) entirely in rootless Podman under gVisor. One isolated host per project (own folder, own logins, own internal network), internet through a transparent egress router that drops anything to your LAN, Tailscale or the machine itself. No proxy settings inside the hosts. Ask Claude e.g. "set up Omnigent" or "create a new Omnigent project called foo". |

### omnigent requirements

- Ubuntu/Debian with sudo access (the skill's `install-prereqs.sh` installs Podman, passt and gVisor)
- A larger subordinate UID range for your user (the setup checks it and prints the command)

## Adding a plugin to this repo

1. Create `plugins/<name>/.claude-plugin/plugin.json` with `{"name": "<name>", ...}`.
2. Put skills in `plugins/<name>/skills/<skill>/SKILL.md`.
3. Add an entry to `.claude-plugin/marketplace.json` (same `name`, `source: "./plugins/<name>"`).
4. Run `claude plugin validate .` before pushing.

Plugins have no `version` field, so every pushed commit counts as a new version.

## License

MIT
