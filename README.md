# estack

Claude Code plugins and skills.

## Install

In Claude Code:

```
/plugin marketplace add cirellamhcs/estack
/plugin install omnigent@estack
/plugin install ado-pr-review@estack
```

To get updates automatically, open `/plugin`, go to **Marketplaces**, select
`estack` and choose **Enable auto-update**. Otherwise update with
`/plugin marketplace update estack`.

If you have no GitHub SSH key, set `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` before
adding the marketplace.

## Plugins

| Plugin | Skills | What it's for |
|---|---|---|
| `omnigent` | `omnigent-podman` | Run [Omnigent](https://github.com/omnigent-ai) entirely in rootless Podman under gVisor. One isolated host per project (own folder, own logins, own internal network), internet through a transparent egress router that drops anything to your LAN, Tailscale or the machine itself. No proxy settings inside the hosts. Ask Claude e.g. "set up Omnigent" or "create a new Omnigent project called foo", or use the commands `omnigent-podman` and `omnigent-project` it adds. |
| `ado-pr-review` | `review-assigned-prs` | Review the Azure DevOps pull requests where you are a reviewer: triage, check out each PR, build and run its tests, post inline findings and a summary, vote, and re-check on a `/loop` while waiting for the author. All state lives in Azure DevOps. Say "review my PRs" or run `/review-assigned-prs [pr-id ...] [--dry-run]`. |

### omnigent requirements

- Ubuntu/Debian with sudo access (`omnigent-podman prereqs` installs Podman, passt and gVisor)
- A larger subordinate UID range for your user (the setup checks it and prints the command)

### ado-pr-review requirements

- A personal access token with the scopes Code (Read & write) and Work Items (Read). Sign in once in a terminal with `ado-pr-review login`: it asks for the organization and the token, checks them, and stores the token in the system keyring (`secret-tool`) or, without one, in `~/.config/ado-pr-review/pat` (mode 0600). `ado-pr-review status` checks it; `ado-pr-review logout` removes it.
- While PRs wait for their author it re-checks on a `/loop`, every 30 minutes by default. Change it in `/config` (plugin setting "Re-check interval") or per run with `--every <minutes>` (1–60).
- The command exists only inside Claude Code; `ado-pr-review install-cli` adds it to `~/.local/bin` for a normal terminal.
- `git`, `curl`, `python3`; whatever the reviewed repos need to build (e.g. .NET SDK, Node)
- Checkouts go to `<project dir>/repos` (override with `REVIEW_REPOS_DIR`)

## Adding a plugin to this repo

1. Create `plugins/<name>/.claude-plugin/plugin.json` with `{"name": "<name>", ...}`.
2. Put skills in `plugins/<name>/skills/<skill>/SKILL.md`.
3. Add an entry to `.claude-plugin/marketplace.json` (same `name`, `source: "./plugins/<name>"`).
4. Run `claude plugin validate .` before pushing.

Plugins have no `version` field, so every pushed commit counts as a new version.

## License

MIT
