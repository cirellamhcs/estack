# Deep review checklist

Work in `repoDir` at the PR head (detached), read-only: no builds, no tests. `fullDiff` is merge-base...head. Read the whole diff first, then the surrounding code of every changed function.

## Intent
- Read the linked work items (`bash <skillDir>/scripts/workitem.sh <id> ...`) and the PR description. Does the diff do what the work item asks, nothing less, nothing unrelated?
- Every claim in the description is a hypothesis: contract unchanged, tests passing, no model change, "only caller is X". Verify each one you can; list the ones you could not.

## Correctness (critical when wrong)
- Behaviour change vs. stated change. Null handling, boundaries, error paths, concurrency, time zones, ordering.
- Callers of every changed signature (`grep -rn` across the repo, including tests and gateway/mirror projects).
- Data: migrations, EF model changes, column nullability, backwards compatibility of persisted data.
- Contracts: API/OpenAPI, serialized DTOs, message formats, config keys. Undeclared breaking change is critical.
- Security: secrets in code or logs, auth checks on new endpoints, input validation, injection, PII in logs.
- Tests (by reading, not running): changed behaviour has a test that would fail without the change. Deleted or weakened assertions are critical unless justified.

## Pipeline (read, never run)
- Do not build, restore, install packages or run tests: the PR's build pipeline does that. Read `builds` from `pr-state.sh` instead.
- `status: rejected` on a blocking pipeline with `ranOnHead: true` is a critical finding: name the pipeline, quote the first errors from `errors`, link `url`.
- `queued`/`running`, `ranOnHead: false` or `expired: true`: no verdict on build and tests yet; say so in the summary. It does not block the vote by itself.
- `targetMovedSince: true` only means the target branch got new commits after the run; the result still holds for this PR's code. Mention it, nothing more.
- No Build policy on the PR: say "no build validation" in the summary.
- Description claims about tests or gates that the pipeline does not cover (e.g. "migrations checked", "OpenAPI unchanged"): check them by reading the code and `git diff` on the guarded files, and say which way.

## Quality (minor)
- Naming, duplication, dead code, comments that lie, log noise, inconsistent style with the surrounding file.
- Description or commit text that does not match the code (state the correct behaviour).

## Other reviewers
- Read existing threads (`otherOpenThreads` from `pr-state.sh`). Do not duplicate an open point; if the diff already addresses a Copilot or human finding, note it in the summary instead of opening a new thread.

## Output contract (what the subagent returns)
```json
{
  "verifiedOn": "<repo>@<sha>",
  "verified": ["pipeline <name>: succeeded on head", "migration matches model change (read)", "..."],
  "notVerified": ["claim X: not checkable from the code"],
  "findings": [
    {"severity": "critical|minor", "file": "/src/...", "line": 35, "comment": "..."}   // line = right side (new file) line
  ],
  "descriptionMismatches": ["..."]
}
```
