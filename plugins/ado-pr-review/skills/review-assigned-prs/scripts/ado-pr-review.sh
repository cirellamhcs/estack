#!/usr/bin/env bash
# ado-pr-review login         ask for organization and PAT, verify them, store the PAT
# ado-pr-review logout        remove the stored PAT
# ado-pr-review status        show organization, where the token comes from, and whether it works
# ado-pr-review install-cli   also make this command work in a normal terminal (~/.local/bin)
ADO_NO_AUTH=1 source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# check <base64 auth> <org>  -> prints the account's display name, fails on a bad token or org
check() {
  curl -sS --fail -H @<(printf 'Authorization: Basic %s\n' "$1") \
    "https://dev.azure.com/$2/_apis/connectionData?api-version=7.1-preview" 2>/dev/null \
    | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["authenticatedUser"]["providerDisplayName"])' 2>/dev/null
}

set_org() {
  mkdir -p -m 700 "$CONFIG_DIR"
  local tmp; tmp="$(mktemp "$CONFIG_DIR/.settings.XXXXXX")"
  { [[ -f "$SETTINGS_FILE" ]] && grep -v '^AZDO_ORG=' "$SETTINGS_FILE" || echo "# Machine-specific settings for the ado-pr-review plugin."
    echo "AZDO_ORG=$1"; } > "$tmp"
  mv "$tmp" "$SETTINGS_FILE"
}

forget() {
  have_keyring && secret-tool clear "${KEYRING_ATTRS[@]}" 2>/dev/null || true
  rm -f "$TOKEN_FILE"
}

login() {
  [[ -t 0 ]] || die "Run this in a terminal: $CLI login (it asks for the token without echoing it)"
  local org pat auth name
  read -r -p "Azure DevOps organization${AZDO_ORG:+ [$AZDO_ORG]}: " org
  org="${org:-${AZDO_ORG:-}}"; org="${org#https://dev.azure.com/}"; org="${org%%/*}"
  [[ -n "$org" ]] || die "No organization given"
  cat <<EOF
Create a personal access token at https://dev.azure.com/$org/_usersSettings/tokens
with the scopes Code (Read & write) and Work Items (Read).
EOF
  read -r -s -p "Personal access token (hidden): " pat; echo
  [[ -n "$pat" ]] || die "No token given"
  auth="$(printf ':%s' "$pat" | base64 -w0)"
  name="$(check "$auth" "$org")" || die "Azure DevOps rejected this token for organization '$org'"
  forget
  if have_keyring && printf %s "$pat" | secret-tool store --label "ado-pr-review ($org)" "${KEYRING_ATTRS[@]}"; then
    where="the system keyring"
  else
    mkdir -p -m 700 "$CONFIG_DIR"
    (umask 077; printf %s "$pat" > "$TOKEN_FILE")
    where="$TOKEN_FILE (readable only by you)"
  fi
  set_org "$org"
  echo "Signed in to $org as $name. Token stored in $where."
}

status() {
  local src auth
  if have_keyring && [[ -n "$(secret-tool lookup "${KEYRING_ATTRS[@]}" 2>/dev/null)" ]]; then src="system keyring"
  elif [[ -r "$TOKEN_FILE" ]]; then src="$TOKEN_FILE"
  else echo "Not signed in. Run in a terminal: $CLI login"; exit 1; fi
  echo "Organization: ${AZDO_ORG:-(not set)}"
  echo "Token from:   $src"
  auth="$(auth_b64)"
  if [[ -n "${AZDO_ORG:-}" ]] && check "$auth" "$AZDO_ORG" >/dev/null; then echo "Token works:  yes"
  else echo "Token works:  NO (expired, revoked or wrong organization). Run: $CLI login"; exit 1; fi
}

install_cli() {
  local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" bin="$HOME/.local/bin"
  mkdir -p "$bin"
  cat > "$bin/$CLI" <<LAUNCHER
#!/bin/sh
# Installed by "$CLI install-cli": runs the current ado-pr-review plugin version.
f="\${CLAUDE_CONFIG_DIR:-$cfg}/plugins/installed_plugins.json"
p=\$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["plugins"]["ado-pr-review@estack"][0]["installPath"])' "\$f" 2>/dev/null) \\
  || { echo "$CLI: ado-pr-review plugin not found in \$f" >&2; exit 1; }
exec "\$p/bin/$CLI" "\$@"
LAUNCHER
  chmod +x "$bin/$CLI"
  echo "Installed $bin/$CLI"
  [[ ":$PATH:" == *":$bin:"* ]] || echo "Add $bin to your PATH to use it"
}

case "${1:-}" in
  login) login ;;
  logout) forget; echo "Stored token removed." ;;
  status) status ;;
  install-cli) install_cli ;;
  *) sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# //'; exit 2 ;;
esac
