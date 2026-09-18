# llm-d-infra Skills

Claude Code skills for managing llm-d CI infrastructure and diagnosing nightly E2E failures.

## Layout

`nightly` is the only registered skill here. Skill discovery scans `.claude/skills/*/SKILL.md`
one level deep, so everything nested below that is a file to Read, not a skill to invoke — the
`name: nightly:<x>` in their frontmatter declares an identity the loader never reads.

```
nightly/SKILL.md            # Registered skill — entry point for all nightly failure analysis
  scripts/                  # The shell and jq both documents run; README.md there is the index
  report/SKILL.md           # Multi-day windows, real error text, streaks, weekly trend
  infra/SKILL.md            # Infrastructure/auth failures (GCP, AWS, runners)
  gpu/SKILL.md              # Accelerator contention and availability issues
  deploy/SKILL.md           # Deployment failures (helmfile, helm, kustomize)
  pods/SKILL.md             # Pod readiness timeout diagnosis
  test/SKILL.md             # E2E test failures (e2e-validate.sh, Go tests)
  rca/SKILL.md              # Full root cause analysis (deep investigation)
```

Six of the seven sub-skill files were last touched 2026-03-06 and predate the `-acc-` lane
naming, the TPU DWS step and the XPU lanes; treat their specifics as unverified.
`nightly/report/SKILL.md` is the current one.

## Quick Start

- `/nightly` — triage the last 24 hours across the fleet
- "why did wide-ep fail" — `/nightly`, then follow its routing to a sub-skill file
- "nightly report" — `/nightly`, which reads `nightly/report/SKILL.md` for the weekly pass

## Architecture

### Smart Router Pattern

The `nightly` skill gathers scheduled runs and the workflow registry from GitHub Actions,
attributes each failure to its failed step, pulls the step's actual error text, and routes on
that text to a sub-skill file. Routing on the step name alone is not enough: `Standup` and `Run`
each cover several unrelated causes.

### Context-Safe Execution

All skills redirect CI logs and kubectl output to files under `/tmp/llm-d/nightly/<date>/` and
analyze them via subagents. This prevents large log output from polluting the conversation
context. The directory is date-scoped because every file in it is named after a run or job id
and so accumulates rather than being overwritten; a stale one once padded a report with lanes
that had not failed.

### Shared Scripts

`nightly/SKILL.md` and `nightly/report/SKILL.md` need most of the same shell and jq — the gap
scan, the streak query, step attribution, the error-text extraction. Those live once in
`nightly/scripts/` and are called as `sh $NS/<name>.sh`, rather than being copied into both
documents as heredocs. Every copy that existed drifted: the gap scan grew a `TOO NEW` guard in
one document and not the other, so the weekly report turned every lane added yesterday into a
coverage gap.

### Failure Categories

| Category | File to Read | Typical Fix |
|----------|--------------|-------------|
| Auth/infra | `nightly/infra/SKILL.md` | Rerun or rotate secret |
| Accelerator contention | `nightly/gpu/SKILL.md` | Wait/rerun or clean leaked namespaces |
| Deploy | `nightly/deploy/SKILL.md` | Fix chart values or rerun |
| Pod readiness | `nightly/pods/SKILL.md` | Check image tags, resource limits |
| Test | `nightly/test/SKILL.md` | Find regression commit, file issue |
| Unknown | `nightly/rca/SKILL.md` | Full investigation |

## Repos and Workflows

Not duplicated here — these lists go stale as lanes are added and retired. See
`nightly/SKILL.md`, which carries the monitored-repo table, the reusable-workflow table, and a
query that derives the schedule matrix from the crons rather than from a checked-in copy.
