# Templates

## Review subagent prompt

Fill the placeholders from `pr-state.sh` and `checkout-pr.sh` output (`description` comes from `pr-state.sh`); an empty JSON list is written as `none`. Keep the subagent read-only on Azure DevOps.

```
You are reviewing Azure DevOps PR <prId> "<title>" in <repository> (project "<project>") as a senior engineer.
STRICTLY READ-ONLY on Azure DevOps: never run pr-write.sh, never vote, never comment. You may run workitem.sh and pr-state.sh from <skillDir>/scripts. Local commands only inside <repoDir>.

Checked-out head: <head> (detached) in <repoDir>. Full diff: <fullDiff>. <If delta: Delta since my last review: <deltaDiff>; my open threads: <myInlineThreads JSON>.>
PR description (verify every claim you can):
<description>
Linked work items: <workItems>. Pipeline results: <builds JSON>. Existing open threads by others (openedByBot marks Copilot/system): <otherOpenThreads JSON>.

Follow the checklist in <skillDir>/review-checklist.md completely: read the diff and surrounding code and verify every description claim you can by reading. Do NOT build, restore, install or run tests; the pipeline does that, use its results above.
Return ONLY the JSON object described in "Output contract" of that file. Severity: critical = wrong behaviour, data loss, security, undeclared contract break, missing tests for changed behaviour, a failed blocking pipeline on the current head. Everything else is minor.
```

## Summary thread (status Closed, posted after inline threads)

First line is parsed by the next pass; keep its form exactly.

```
Reviewed <short-sha> (approved | approved with suggestions | waiting for author).

Pipeline: <name>: <succeeded | failed | running | not run on this head | no build validation> (<url>).
Verified by reading <this head | repo@sha when the code lives elsewhere>: <what you checked>.
Not verified: <claim and why, or "nothing">.
Checked: <description claims you confirmed, one line each>.
Description mismatches: <one line each, or "none">.

Critical (blocking): <file:line – one line each, or "none">.
Minor: <count> inline, non-blocking.
```

Re-check variant, first line `Reviewed <short-sha> (<verdict>) after <n> new commit(s) since <prev-short-sha>.`

## Inline finding

```
<critical: "" | minor: "nit: "><what is wrong in one sentence>. <why it matters / what breaks>. <concrete fix>.
```

## Thread replies on re-check

- fixed: `Fixed in <short-sha>.` then status `fixed`
- accepted argument: `Agreed, <one-line reason>.` then status `byDesign` (or `closed` for nits)
- not fixed: `Still open: <what is missing>.` keep `active`
