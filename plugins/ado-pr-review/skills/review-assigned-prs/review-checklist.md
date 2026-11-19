# Deep review checklist

Work in `repoDir` at the PR head (detached). `fullDiff` is merge-base...head. Read the whole diff first, then the surrounding code of every changed function, then run things.

## Intent
- Read the linked work item (`mcp__azure-devops__wit_work_item get`) and the PR description. Does the diff do what the work item asks, nothing less, nothing unrelated?
- Every claim in the description is a hypothesis: contract unchanged, tests passing, no model change, "only caller is X". Verify each one you can; list the ones you could not.

## Correctness (critical when wrong)
- Behaviour change vs. stated change. Null handling, boundaries, error paths, concurrency, time zones, ordering.
- Callers of every changed signature (`grep -rn` across the repo, including tests and gateway/mirror projects).
- Data: migrations, EF model changes, column nullability, backwards compatibility of persisted data.
- Contracts: API/OpenAPI, serialized DTOs, message formats, config keys. Undeclared breaking change is critical.
- Security: secrets in code or logs, auth checks on new endpoints, input validation, injection, PII in logs.
- Tests: changed behaviour has a test that fails without the change. Deleted or weakened assertions are critical unless justified.

## Build and tests (always run; report numbers)
- .NET: `dotnet build <sln>` (repos set TreatWarningsAsErrors; a warning is a finding). Then per test project: `dotnet test --project <csproj> --no-build` when `global.json` enables Microsoft.Testing.Platform (its summary reads `total/failed/succeeded/skipped`), otherwise `dotnet test <csproj> --no-build`. The error "should be via '--project'" means the first form is required. NU1900 warnings (vulnerability feed unreachable) are not a failed restore; only if restore itself fails, retry with a scratch `nuget.config` listing nuget.org alone (`--configfile`) and say so.
- Node: `npm ci` then `npx tsc -b` / `npm test` as configured.
- Integration tests needing Docker (Testcontainers): run if Docker is available; otherwise report "not run" with the reason. Never fake numbers.
- Run every gate the PR description or the pipeline YAML (`.azuredevops/*.yml`, `azure-pipelines.yml`) names, e.g. `dotnet ef migrations has-pending-model-changes`, OpenAPI export scripts, baseline guards. If a gate needs inputs you do not have, verify its claim another way (e.g. `git diff` on the files it guards) and say which way.
- Compare your numbers with the description. A mismatch is a finding.

## Quality (minor)
- Naming, duplication, dead code, comments that lie, log noise, inconsistent style with the surrounding file.
- Description or commit text that does not match the code (state the correct behaviour).

## Other reviewers
- Read existing threads (`repo_pull_request_thread list`). Do not duplicate an open point; if the diff already addresses a Copilot or human finding, note it in the summary instead of opening a new thread.

## Output contract (what the subagent returns)
```json
{
  "verifiedOn": "<repo>@<sha>",
  "verified": ["dotnet build: 0 warnings 0 errors", "DomainTests 4036/4036", "..."],
  "notVerified": ["frontend tsc (other repo)"],
  "findings": [
    {"severity": "critical|minor", "file": "/src/...", "line": 35, "comment": "..."}   // line = right side (new file) line
  ],
  "descriptionMismatches": ["..."]
}
```
