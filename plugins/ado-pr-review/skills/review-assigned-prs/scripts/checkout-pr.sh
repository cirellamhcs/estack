#!/usr/bin/env bash
# Clone/fetch the PR's repo into $REVIEW_REPOS_DIR/<repo>, check out the PR head (detached), write diffs.
# Usage: checkout-pr.sh <pullRequestId> [<previously-reviewed-sha>]   (or: <project> <repositoryId> <pullRequestId> [<sha>])  -> JSON
# Writes: <repoDir>/../<repo>.pr<id>.full.diff  (base...head)  and, with a 4th arg, <repo>.pr<id>.delta.diff (prev..head)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [[ $# -ge 3 ]]; then resolve_pr "$1" "$2" "$3"; prev="${4:-}"; else resolve_pr "$1"; prev="${2:-}"; fi
proj="$PROJ_ENC"; repo="$REPO"; pr="$PR"
PRJ=$(api GET "$proj/_apis/git/repositories/$repo/pullRequests/$pr")
read -r name remote src tgt head base < <(printf '%s' "$PRJ" | python3 -I -c '
import json,sys; p=json.load(sys.stdin)
print(p["repository"]["name"], p["repository"]["remoteUrl"], p["sourceRefName"], p["targetRefName"], p["lastMergeSourceCommit"]["commitId"], p["lastMergeTargetCommit"]["commitId"])')
remote="${remote/https:\/\/*@dev.azure.com/https://dev.azure.com}"   # strip user@ so the credential helper is used
mkdir -p "$REVIEW_REPOS_DIR"; dir="$REVIEW_REPOS_DIR/$name"
if [[ ! -d "$dir/.git" ]]; then git init -q "$dir"; git -C "$dir" remote add origin "$remote"; fi
if ! err=$(git_ado -C "$dir" fetch -q --depth=300 origin "$src:refs/remotes/origin/${src#refs/heads/}" "$tgt:refs/remotes/origin/${tgt#refs/heads/}" 2>&1); then
  python3 -I -c 'import json,sys; print(json.dumps({"error":"fetch failed (branch deleted or PR inactive?)","detail":sys.argv[1][:300]}))' "$err"; exit 1
fi
if ! git -C "$dir" merge-base "$base" "$head" >/dev/null 2>&1; then git_ado -C "$dir" fetch -q --unshallow origin "$src" "$tgt" || true; fi
mb=$(git -C "$dir" merge-base "$base" "$head" 2>/dev/null || echo "$base")
git -C "$dir" reset -q --hard && git -C "$dir" clean -qfd && git -C "$dir" checkout -q --detach "$head"
full="$REVIEW_REPOS_DIR/$name.pr$pr.full.diff"; git -C "$dir" diff "$mb" "$head" > "$full"
delta=""; rebased="null"
if [[ -n "$prev" ]] && git -C "$dir" cat-file -e "$prev^{commit}" 2>/dev/null; then
  delta="$REVIEW_REPOS_DIR/$name.pr$pr.delta.diff"; git -C "$dir" diff "$prev" "$head" > "$delta"
  if git -C "$dir" merge-base --is-ancestor "$prev" "$head"; then rebased=false; else rebased=true; fi   # rebased => delta diff is unreliable, review the full diff
fi
python3 -I - "$dir" "$mb" "$head" "$base" "$full" "$delta" "$(git -C "$dir" diff --stat "$mb" "$head" | tail -1)" "$(git -C "$dir" log --oneline "$mb..$head" | wc -l)" "$rebased" <<'PY'
import json,sys
d,mb,head,base,full,delta,stat,n,rebased=sys.argv[1:]
print(json.dumps({"repoDir":d,"mergeBase":mb,"head":head,"targetHead":base,"commitsInPr":int(n),
                  "fullDiff":full,"deltaDiff":delta or None,"rebasedSincePrev":json.loads(rebased),"diffStat":stat.strip()},indent=1))
PY
