#!/usr/bin/env bash
# Shared helpers. Auth comes from $AZDO_PAT_B64 = base64(":<pat>") (ready-to-use Basic header).
# Nothing here ever prints the token.
set -euo pipefail
# Machine-specific settings (AZDO_ORG=<organization>, optionally REVIEW_REPOS_DIR), kept
# outside the plugin so updates never touch them. Do not put the PAT there.
SETTINGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/ado-pr-review/settings.env"
if [[ -f "$SETTINGS_FILE" ]]; then set -a; source "$SETTINGS_FILE"; set +a; fi
: "${AZDO_ORG:?AZDO_ORG is not set (your Azure DevOps organization; put AZDO_ORG=<org> in $SETTINGS_FILE)}"
: "${AZDO_PAT_B64:?AZDO_PAT_B64 is not set (base64 of ':<pat>')}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Never inside the plugin directory: it is replaced on every plugin update.
: "${REVIEW_REPOS_DIR:=${CLAUDE_PROJECT_DIR:-$PWD}/repos}"
BASE_URL="https://dev.azure.com/$AZDO_ORG"

# api METHOD PATH [JSON_BODY]  — PATH is relative to the org, e.g. "Proj/_apis/git/..." (api-version added if absent)
api() {
  local method="$1" path="$2" body="${3:-}"
  case "$path" in *api-version=*) ;; *) if [[ "$path" == *\?* ]]; then path="$path&api-version=7.1"; else path="$path?api-version=7.1"; fi;; esac
  if [[ -n "$body" ]]; then
    curl -sS --fail-with-body -X "$method" -H "Authorization: Basic $AZDO_PAT_B64" -H 'Content-Type: application/json' -H 'Accept: application/json' --data "$body" "$BASE_URL/$path"
  else
    curl -sS --fail-with-body -X "$method" -H "Authorization: Basic $AZDO_PAT_B64" -H 'Accept: application/json' "$BASE_URL/$path"
  fi
}

# git_ado ARGS... — git with a credential helper that reads the PAT from the environment (never stored on disk)
git_ado() {
  git -c credential.helper= \
      -c 'credential.helper=!f() { echo username=pat; echo "password=$(printf %s "$AZDO_PAT_B64" | base64 -d | cut -d: -f2-)"; }; f' \
      "$@"
}

urlenc() { python3 -I -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# resolve_pr ARGS... — accepts "<prId>" or "<project> <repositoryId> <prId>"; sets PROJ_ENC, REPO, PR
resolve_pr() {
  if [[ $# -ge 3 ]]; then PROJ_ENC=$(urlenc "$1"); REPO="$2"; PR="$3"; return; fi
  PR="$1"
  read -r PROJ_ENC REPO < <(api GET "_apis/git/pullrequests/$PR" | python3 -I -c '
import json,sys,urllib.parse; p=json.load(sys.stdin)["repository"]
print(urllib.parse.quote(p["project"]["name"],safe=""), p["id"])')
}
