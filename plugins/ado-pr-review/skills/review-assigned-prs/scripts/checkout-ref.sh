#!/usr/bin/env bash
# Check out any repo at any ref into its own worktree (for submodule pins, docs PRs that describe another repo, comparing with master).
# Usage: checkout-ref.sh <project> <repositoryName> <ref-or-sha>   -> JSON {worktree, sha}
# Worktree: $REVIEW_REPOS_DIR/<repo>@<ref>  (reset and cleaned on every call)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
proj=$(urlenc "$1"); name="$2"; ref="$3"
remote="$BASE_URL/$proj/_git/$(urlenc "$name")"
mkdir -p "$REVIEW_REPOS_DIR"; dir="$REVIEW_REPOS_DIR/$name"
if [[ ! -d "$dir/.git" ]]; then git init -q "$dir"; git -C "$dir" remote add origin "$remote"; fi
if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
  git -C "$dir" cat-file -e "$ref^{commit}" 2>/dev/null || git_ado -C "$dir" fetch -q --depth=300 origin "$ref"
  sha=$(git -C "$dir" rev-parse "$ref^{commit}")
else
  git_ado -C "$dir" fetch -q --depth=300 origin "refs/heads/$ref:refs/remotes/origin/$ref"
  sha=$(git -C "$dir" rev-parse "refs/remotes/origin/$ref")
fi
wt="$REVIEW_REPOS_DIR/$name@$(printf '%s' "$ref" | tr '/' '_' | cut -c1-40)"
if [[ -d "$wt" ]]; then git -C "$wt" checkout -q --detach "$sha" && git -C "$wt" reset -q --hard && git -C "$wt" clean -qfd
else git -C "$dir" worktree add -q --detach "$wt" "$sha"; fi
printf '{"worktree": "%s", "sha": "%s"}\n' "$wt" "$sha"
