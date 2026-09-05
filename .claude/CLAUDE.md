# llm-d-infra — Claude Code Project Instructions

## Repository Purpose

Shared CI infrastructure for the llm-d org. Contains:
- **Reusable GitHub Actions workflows** — governance (Prow, stale, DCO) and nightly E2E testing
- **Repo templates** — standard files for new llm-d repos
- **Nightly E2E workflows** — reusable workflows for OpenShift, GKE, GKE TPU, CKS and XPU
- **Claude Code skills** — for diagnosing nightly failures (`.claude/skills/`)

## Key Files

| File | Purpose |
|------|---------|
| `.github/workflows/reusable-nightly-e2e-openshift.yaml` | Nightly E2E on OpenShift |
| `.github/workflows/reusable-nightly-e2e-gke.yaml` | Nightly E2E on GKE |
| `.github/workflows/reusable-nightly-e2e-gke-tpu.yaml` | Nightly E2E on GKE TPU |
| `.github/workflows/reusable-nightly-e2e-cks.yaml` | Nightly E2E on CKS (CoreWeave) |
| `.github/workflows/reusable-nightly-e2e-xpu.yaml` | Nightly E2E on Intel XPU |
| `.github/workflows/reusable-ci-nightly-benchmark.yaml` | Benchmark harness (also runs on its own cron) |
| `.github/workflows/reusable-prow-commands.yaml` | Prow-style /lgtm, /approve commands |
| `templates/repo-template/` | Standard repo scaffolding |

## Context-Safe Execution (MANDATORY)

CI logs and kubectl output can be hundreds of lines. ALWAYS redirect to files, then analyze via
`Agent(subagent_type='Explore')` with Grep:

```bash
export LOG_DIR=/tmp/llm-d/nightly/$(date -u +%F)   # date-scoped; $LOG_DIR accumulates
export NS="$(git rev-parse --show-toplevel)/.claude/skills/nightly/scripts"
mkdir -p "$LOG_DIR"
```

`gh run view --log` renders every step as the literal string `UNKNOWN STEP` and re-echoes the
env block ahead of each one, so it cannot be grepped for a named step. To get one step's real
output, run `sh $NS/errtext.sh <repo> <run_id>`, which windows the job log on the failing step's
timestamps from the jobs API. `.claude/skills/nightly/scripts/README.md` indexes the rest.
`.claude/skills/nightly/report/SKILL.md` (Phase 3a) explains what each filter in `errtext.sh`
removes and what breaks when it is dropped.

## Nightly Schedule

Nightly E2E tests run across 5 platforms. `.claude/skills/nightly/SKILL.md` derives the schedule
matrix from the crons rather than carrying a checked-in copy — run the query there.

## GitHub CLI

Always prefix with `unset GITHUB_TOKEN &&` to use stored credentials:
```bash
unset GITHUB_TOKEN && gh run list --repo llm-d/llm-d --limit 20
```

## Skills

`nightly` is the only registered skill here — skill discovery scans `.claude/skills/*/SKILL.md`
one level deep, so the sub-skills nested under it are files, not invocable skills. Use
`/nightly` to triage; it Reads these by path as needed:

| File under `.claude/skills/` | Covers |
|---|---|
| `nightly/scripts/` | the shell and jq both documents run; `README.md` there is the index |
| `nightly/report/SKILL.md` | multi-day windows, real error text, streaks, weekly trend |
| `nightly/infra/SKILL.md` | auth/runner issues |
| `nightly/gpu/SKILL.md` | accelerator contention |
| `nightly/deploy/SKILL.md` | helmfile/helm/kustomize failures |
| `nightly/pods/SKILL.md` | pod readiness timeouts |
| `nightly/test/SKILL.md` | E2E test failures |
| `nightly/rca/SKILL.md` | deep investigation |
