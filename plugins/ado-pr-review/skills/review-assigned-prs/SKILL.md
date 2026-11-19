---
name: review-assigned-prs
description: Use when asked to review, check, approve or re-check the Azure DevOps pull requests assigned to the user as reviewer ("review my PRs", "check my assigned PRs", "re-check PR 14501", /review-assigned-prs), including loop ticks that re-check PRs waiting on their author.
argument-hint: "[pr-id ...] [--dry-run] [--every <minutes>]"
---

# Review Assigned PRs (Azure DevOps)

One pass = triage every active PR where I am a reviewer, deep-review the ones that need it, post the verdict, and keep PRs that are waiting for the author under watch. The pass is idempotent: all state lives in Azure DevOps (my vote, my threads, the `Reviewed <sha>` marker), never in local files.

Arguments: PR ids restrict the pass to those PRs. `--dry-run` does everything except posting and starting the loop (print what would be posted instead). `--every <minutes>` sets the re-check interval for this watch (section 5).

Scripts live in `${CLAUDE_SKILL_DIR}/scripts/`; every Azure DevOps read and write goes through them with the user's PAT. They find the organization and token themselves. If they say "Not signed in" or the token is rejected, stop and give the user this line to run in their own terminal (it prompts for the token, so never run it yourself): `ado-pr-review login`. `ado-pr-review status` checks the sign-in without showing the token. Never print, read, copy or persist the token. Checkouts persist in `${CLAUDE_PROJECT_DIR}/repos/<repo>` (override with `REVIEW_REPOS_DIR`); each checkout resets and cleans the tree. The checkout is for reading code only: never build, restore, install or run tests. The PR's build pipeline does that, and `pr-state.sh` reports its result as `builds`.

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

Dispatch one subagent per PR (general-purpose) with the prompt in `templates.md` → "Review subagent prompt". It reads code in `repoDir` (no builds, no tests); it never writes to Azure DevOps. It returns the JSON from the checklist's output contract: findings with `severity: critical|minor`, `file`, `line`, `comment`, plus what was verified and not verified, with numbers. If the Agent tool is unavailable (this skill is itself running inside a subagent), do the checklist inline instead.

Superproject or docs-only PR (the diff touches submodule pins or `docs/` and the claims are about code in another repo): get that code with
`bash ${CLAUDE_SKILL_DIR}/scripts/checkout-ref.sh "<project>" <repoName> <branch-or-sha>` (a separate worktree) and verify the statements against it; name that repo and sha in the summary.

Severity rule (decides the vote, nothing else does):
- **critical**: wrong behaviour, data loss, security/secret exposure, breaking API or contract change not declared, missing tests for changed behaviour, a failed blocking pipeline on the current head (`builds[].status` `rejected` with `ranOnHead`), unresolved critical threads from other reviewers that the diff does not address.
- **minor**: style, naming, description inaccuracies, missing comments, improvements that do not change correctness.
- docs-only PR: a statement about runtime behaviour that the referenced code contradicts is critical; staleness, omissions and wording are minor.

## 3. Re-check (after the author pushed or replied)

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/checkout-pr.sh <prId> <myReviewedHead>   # adds deltaDiff, rebasedSincePrev
```

- `rebasedSincePrev: true` → treat as a full review of `fullDiff`; otherwise review `deltaDiff` for new issues and read `myInlineThreads`.
- For every thread of mine (`pr-write.sh reply <prId> <threadId> <<<'text'`, then `pr-write.sh status <prId> <threadId> fixed|byDesign|closed`): if the delta fixes it → reply `Fixed in <short-sha>.` and set status `fixed`. If the author replied and the argument holds → reply briefly and set `ByDesign` or `Closed`. If it is not fixed → reply what is still missing, keep `Active`.
- Threads I never opened are not mine to resolve. `openedByBot: true` marks Copilot/system threads; mention them in the summary only when the diff addresses or ignores them.

## 4. Post (skip when `--dry-run`)

Order matters, because the summary marker is what the next pass reads:

All writes go through `pr-write.sh`; comment text comes on stdin (use a quoted heredoc, `<<'EOF'`, so backticks and `$` survive):

1. Inline threads, one per finding: `bash ${CLAUDE_SKILL_DIR}/scripts/pr-write.sh thread <prId> --file <path> --line <n> <<'EOF'` … `EOF` (status `active`; `line` is the right side, new file). Minor findings start with `nit:`. Do not repeat a point another reviewer already has open.
2. Summary thread: `bash ${CLAUDE_SKILL_DIR}/scripts/pr-write.sh thread <prId> --status closed <<'EOF'` … `EOF`, first line exactly `Reviewed <head-sha> (<verdict>).` (see `templates.md`). It states what was verified with numbers, and lists critical findings by file.
3. Vote: `bash ${CLAUDE_SKILL_DIR}/scripts/pr-write.sh vote <prId> <vote>`:
   - no findings → `approved`
   - only minor → `approved-with-suggestions`
   - any critical → `waiting-for-author`
   Never reject, never change the PR (title, description, auto-complete, reviewers, abandon); the script offers none of that.

Approving may complete the PR immediately when the author set auto-complete; `pr-state.sh` shows `autoComplete`. That is intended.

## 5. Wait and re-check

Interval: `--every <minutes>` if given, otherwise the plugin setting `${user_config.loop_minutes}` minutes (changeable in `/config`; if that value is not a number, use 30). Clamp to 1–60.

After posting, list PRs in `waiting-for-author`, `changed-since-review` not yet handled, or just voted `waiting-for-author`. If that list is not empty and this run is not already a `/loop` tick, start the watch, passing on the same arguments (PR ids, `--every`) so every tick sees them:

```
/loop /ado-pr-review:review-assigned-prs [same arguments]
```

Inside the loop, schedule the next tick after the interval (ScheduleWakeup `delaySeconds` = minutes × 60) while something is pending, and stop the loop (ScheduleWakeup `stop: true`) when nothing is pending. Each tick is a normal pass of this skill.

## 6. Report

End with a table: PR id, repository, state before, action taken, vote. Then one line each for PRs skipped and why (stale, draft, own, out of scope because of the id argument) and for verification that could not run. Refer to authors by role ("the author"), not by name.

## Common mistakes

- Reviewing from a changed-files list alone: it has no diff. Always `checkout-pr.sh`.
- Building or running tests locally: the pipeline does that. Report its result from `builds` and link it.
- Calling a pipeline result current when `ranOnHead` is false or it is `expired`: say it ran on an older commit (or is still `queued`/`running`) instead.
- Blocking on minor findings: minor never changes the vote.
- Posting the summary before the inline threads, or without the `Reviewed <sha>` first line: the next pass will re-review from scratch.
- Resolving other reviewers' threads, or replying to Copilot threads as if they were mine.
