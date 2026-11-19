---
name: review-assigned-prs
description: Use when asked to review, check, approve or re-check the Azure DevOps pull requests assigned to the user as reviewer ("review my PRs", "check my assigned PRs", "re-check PR 14501", /review-assigned-prs), including loop ticks that re-check PRs waiting on their author.
argument-hint: "[pr-id ...] [--dry-run]"
---

# Review Assigned PRs (Azure DevOps)

One pass = triage every active PR where I am a reviewer, deep-review the ones that need it, post the verdict, and keep PRs that are waiting for the author under watch. The pass is idempotent: all state lives in Azure DevOps (my vote, my threads, the `Reviewed <sha>` marker), never in local files.

Arguments: PR ids restrict the pass to those PRs. `--dry-run` does everything except posting and starting the loop (print what would be posted instead).

Scripts live in `${CLAUDE_SKILL_DIR}/scripts/` and read the PAT from `$AZDO_PAT_B64` (base64 of `:<pat>`). Never print, copy or persist that value. The organization comes from `$AZDO_ORG` or `~/.config/ado-pr-review/settings.env` (`AZDO_ORG=<org>`). Posting and voting use the `azure-devops` MCP server (`mcp__azure-devops__*`). If any of these is missing, the scripts say so: tell the user what to set and stop. Checkouts persist in `${CLAUDE_PROJECT_DIR}/repos/<repo>` (override with `REVIEW_REPOS_DIR`); each checkout resets and cleans the tree, so building and running tools there is expected.

## 1. Triage

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/list-prs.sh          # all active PRs where I am reviewer, with triage hint
bash ${CLAUDE_SKILL_DIR}/scripts/pr-state.sh <prId>    # my review state, description, threads, policies for one PR
```

With PR ids as arguments skip `list-prs.sh` and run `pr-state.sh` for those ids only; otherwise run it for every PR whose triage hint is `review`. Act per `state`:

| state | action |
|---|---|
| `skip-draft`, `skip-own`, `skip-inactive`, triage `stale` (>90 days) | list in the report, do nothing |
| `new` | full review (section 2) |
| `changed-since-review` | re-check (section 3) |
| `needs-recheck` | re-check (section 3), head unchanged: only read replies / resolved threads |
| `waiting-for-author` | nothing; counts as "pending" for section 5 |
| `up-to-date` | nothing |

## 2. Full review

Checkout the PR and diff locally, then review against `review-checklist.md` (in this skill dir):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/checkout-pr.sh <prId>   # -> repoDir, fullDiff, mergeBase, head
```

Dispatch one subagent per PR (general-purpose) with the prompt in `templates.md` → "Review subagent prompt". It reads code and runs builds/tests in `repoDir`; it never writes to Azure DevOps. It returns the JSON from the checklist's output contract: findings with `severity: critical|minor`, `file`, `line`, `comment`, plus what was verified and not verified, with numbers. If the Agent tool is unavailable (this skill is itself running inside a subagent), do the checklist inline instead.

Superproject or docs-only PR (the diff touches submodule pins or `docs/` and the claims are about code in another repo): get that code with
`bash ${CLAUDE_SKILL_DIR}/scripts/checkout-ref.sh "<project>" <repoName> <branch-or-sha>` (a separate worktree) and verify the statements against it; name that repo and sha in the summary.

Severity rule (decides the vote, nothing else does):
- **critical**: wrong behaviour, data loss, security/secret exposure, breaking API or contract change not declared, failing or missing tests for changed behaviour, build warnings/errors, unresolved critical threads from other reviewers that the diff does not address.
- **minor**: style, naming, description inaccuracies, missing comments, improvements that do not change correctness.
- docs-only PR: a statement about runtime behaviour that the referenced code contradicts is critical; staleness, omissions and wording are minor.

## 3. Re-check (after the author pushed or replied)

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/checkout-pr.sh <prId> <myReviewedHead>   # adds deltaDiff, rebasedSincePrev
```

- `rebasedSincePrev: true` → treat as a full review of `fullDiff`; otherwise review `deltaDiff` for new issues and read `myInlineThreads`.
- For every thread of mine: if the delta fixes it → reply `Fixed in <short-sha>.` and set status `Fixed`. If the author replied and the argument holds → reply briefly and set `ByDesign` or `Closed`. If it is not fixed → reply what is still missing, keep `Active`.
- Threads I never opened are not mine to resolve. `openedByBot: true` marks Copilot/system threads; mention them in the summary only when the diff addresses or ignores them.

## 4. Post (skip when `--dry-run`)

Order matters, because the summary marker is what the next pass reads:

1. Inline threads with `mcp__azure-devops__repo_pull_request_thread_write` `create` (`filePath`, `rightFileStartLine`, status `Active`). Minor findings start with `nit:`. One thread per finding; do not repeat a point another reviewer already has open.
2. Summary thread, status `Closed`, first line exactly `Reviewed <head-sha> (<verdict>).` (see `templates.md`). It states what was verified with numbers, and lists critical findings by file.
3. Vote with `mcp__azure-devops__repo_pull_request_write` `vote`:
   - no findings → `Approved`
   - only minor → `ApprovedWithSuggestions`
   - any critical → `WaitingForAuthor`
   Never `Rejected`, never change the PR (title, description, auto-complete, reviewers, abandon).

Approving may complete the PR immediately when the author set auto-complete; `pr-state.sh` shows `autoComplete`. That is intended.

## 5. Wait and re-check

After posting, list PRs in `waiting-for-author`, `changed-since-review` not yet handled, or just voted `WaitingForAuthor`. If that list is not empty and this run is not already a `/loop` tick, start the watch:

```
/loop /review-assigned-prs
```

Inside the loop, pace with 30 min between ticks while something is pending, and stop the loop (ScheduleWakeup `stop: true`) when nothing is pending. Each tick is a normal pass of this skill.

## 6. Report

End with a table: PR id, repository, state before, action taken, vote. Then one line each for PRs skipped and why (stale, draft, own, out of scope because of the id argument) and for verification that could not run. Refer to authors by role ("the author"), not by name.

## Common mistakes

- Reviewing from the MCP `includeChangedFiles` list alone: it has no diff. Always `checkout-pr.sh`.
- Trusting the PR description's test numbers: run the suites yourself and state what you ran. A test command that prints no pass/fail summary did not run, whatever its exit code.
- Blocking on minor findings: minor never changes the vote.
- Posting the summary before the inline threads, or without the `Reviewed <sha>` first line: the next pass will re-review from scratch.
- Resolving other reviewers' threads, or replying to Copilot threads as if they were mine.
