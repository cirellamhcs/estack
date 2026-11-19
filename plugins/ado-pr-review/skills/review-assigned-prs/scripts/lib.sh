#!/usr/bin/env bash
# Shared helpers (sourced). Nothing here ever prints the token.
#
# Token, first match wins:
#   1. $AZDO_PAT_B64 = base64(":<pat>")           (environment, e.g. CI)
#   2. system keyring via secret-tool               (written by "ado-pr-review login")
#   3. $CONFIG_DIR/pat, mode 0600                   (written by "ado-pr-review login")
# Sourcing with ADO_NO_AUTH=1 skips the token and org checks (used by login itself).
set -euo pipefail
CLI=ado-pr-review
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ado-pr-review"
# Machine-specific settings (AZDO_ORG=<organization>, optionally REVIEW_REPOS_DIR), kept
# outside the plugin so updates never touch them. The PAT never goes in this file.
SETTINGS_FILE="$CONFIG_DIR/settings.env"
TOKEN_FILE="$CONFIG_DIR/pat"
KEYRING_ATTRS=(service ado-pr-review)
if [[ -f "$SETTINGS_FILE" ]]; then set -a; source "$SETTINGS_FILE"; set +a; fi
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Never inside the plugin directory: it is replaced on every plugin update.
: "${REVIEW_REPOS_DIR:=${CLAUDE_PROJECT_DIR:-$PWD}/repos}"

die() { echo "$*" >&2; exit 1; }
have_keyring() { command -v secret-tool >/dev/null 2>&1; }

# Prints base64(":<pat>") from the first source that has a token, or fails.
auth_b64() {
  if [[ -n "${AZDO_PAT_B64:-}" ]]; then printf %s "$AZDO_PAT_B64"; return; fi
  local pat=""
  have_keyring && pat="$(secret-tool lookup "${KEYRING_ATTRS[@]}" 2>/dev/null || true)"
  [[ -z "$pat" && -r "$TOKEN_FILE" ]] && pat="$(<"$TOKEN_FILE")"
  [[ -n "$pat" ]] || return 1
  printf ':%s' "$pat" | base64 -w0
}

if [[ "${ADO_NO_AUTH:-}" != 1 ]]; then
  [[ -n "${AZDO_ORG:-}" ]] || die "Not signed in to Azure DevOps (no organization set). Run in a terminal: $CLI login"
  # Exported only for git's credential helper below; environments are private to this user.
  _ADO_AUTH_B64="$(auth_b64)" || die "Not signed in to Azure DevOps (no token). Run in a terminal: $CLI login"
  export _ADO_AUTH_B64
fi
BASE_URL="https://dev.azure.com/${AZDO_ORG:-}"

# The auth header is handed to curl through a pipe, so it never appears in the process list.
curl_ado() { curl -sS --fail-with-body -H @<(printf 'Authorization: Basic %s\n' "$_ADO_AUTH_B64") "$@"; }

# api METHOD PATH [JSON_BODY]  — PATH is relative to the org, e.g. "Proj/_apis/git/..." (api-version added if absent)
api() {
  local method="$1" path="$2" body="${3:-}"
  case "$path" in *api-version=*) ;; *) if [[ "$path" == *\?* ]]; then path="$path&api-version=7.1"; else path="$path?api-version=7.1"; fi;; esac
  if [[ -n "$body" ]]; then
    curl_ado -X "$method" -H 'Content-Type: application/json' -H 'Accept: application/json' --data-binary @- "$BASE_URL/$path" <<<"$body"
  else
    curl_ado -X "$method" -H 'Accept: application/json' "$BASE_URL/$path"
  fi
}

# git_ado ARGS... — git with a credential helper that reads the token from the environment (never stored by git)
git_ado() {
  git -c credential.helper= \
      -c 'credential.helper=!f() { echo username=pat; echo "password=$(printf %s "$_ADO_AUTH_B64" | base64 -d | cut -d: -f2-)"; }; f' \
      "$@"
}

urlenc() { python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

my_id() { api GET "_apis/connectionData?api-version=7.1-preview" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["authenticatedUser"]["id"])'; }

# resolve_pr ARGS... — accepts "<prId>" or "<project> <repositoryId> <prId>"; sets PROJ_ENC, REPO, PR
resolve_pr() {
  if [[ $# -ge 3 ]]; then PROJ_ENC=$(urlenc "$1"); REPO="$2"; PR="$3"; return; fi
  PR="$1"
  read -r PROJ_ENC REPO < <(api GET "_apis/git/pullrequests/$PR" | python3 -I -c '
import json,sys,urllib.parse; p=json.load(sys.stdin)["repository"]
print(urllib.parse.quote(p["project"]["name"],safe=""), p["id"])')
}
