# llm-d-infra — Claude Code Project Instructions

## Repository Purpose

Shared CI infrastructure for the llm-d org. Contains:
- **Reusable GitHub Actions workflows** — governance (Prow, stale, DCO) and nightly E2E testing
- **Repo templates** — standard files for new llm-d repos
- **Nightly E2E workflows** — reusable workflows for OpenShift, GKE, CKS platforms
- **Claude Code skills** — for diagnosing nightly failures (`.claude/skills/`)

## Key Files

| File | Purpose |
|------|---------|
| `.github/workflows/reusable-nightly-e2e-openshift.yaml` | WVA nightly on OpenShift |
| `.github/workflows/reusable-nightly-e2e-openshift-helmfile.yaml` | Helmfile guides on OpenShift |
| `.github/workflows/reusable-nightly-e2e-gke-helmfile.yaml` | Helmfile guides on GKE |
| `.github/workflows/reusable-nightly-e2e-cks-helmfile.yaml` | Helmfile guides on CKS (CoreWeave) |
| `.github/workflows/reusable-prow-commands.yml` | Prow-style /lgtm, /approve commands |
| `templates/repo-template/` | Standard repo scaffolding |

## Context-Safe Execution (MANDATORY)

CI logs and kubectl output can be hundreds of lines. ALWAYS redirect to files:

```bash
export LOG_DIR=/tmp/llm-d/nightly-rca
mkdir -p $LOG_DIR

# CI logs to file, never into conversation context
gh run view <id> --repo <repo> --log > $LOG_DIR/<id>.log 2>&1
# Analyze via Agent(subagent_type='Explore') with Grep
```

## Nightly Schedule

Nightly E2E tests run across 4 platforms. See `.claude/skills/nightly/SKILL.md` for the full schedule matrix.

## GitHub CLI

Always prefix with `unset GITHUB_TOKEN &&` to use stored credentials:
```bash
unset GITHUB_TOKEN && gh run list --repo llm-d/llm-d --limit 20
```

## Skills

Use `/nightly` to triage nightly failures. It auto-routes to:
- `nightly:infra` — auth/runner issues
- `nightly:gpu` — GPU contention
- `nightly:deploy` — helmfile/helm failures
- `nightly:pods` — pod readiness timeouts
- `nightly:test` — E2E test failures
- `nightly:rca` — deep investigation
- `nightly:report` — weekly trend report
