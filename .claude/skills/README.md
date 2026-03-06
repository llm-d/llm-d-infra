# llm-d-infra Skills

Claude Code skills for managing llm-d CI infrastructure and diagnosing nightly E2E failures.

## Skill Tree

```
nightly/                    # Smart router — entry point for all nightly failure analysis
  nightly:infra             # Infrastructure/auth failures (GCP, AWS, runners)
  nightly:gpu               # GPU contention and availability issues
  nightly:deploy            # Deployment failures (helmfile, helm, install.sh)
  nightly:pods              # Pod readiness timeout diagnosis
  nightly:test              # E2E test failures (e2e-validate.sh, Go tests)
  nightly:rca               # Full root cause analysis (deep investigation)
  nightly:report            # Weekly trend report with success rates
```

## Quick Start

Say any of these to Claude:
- "check nightlies" — runs the `nightly` router, triages all failures
- "why did wide-ep fail" — routes to the appropriate sub-skill
- "nightly report" — generates weekly trend report
- "triage GKE failures" — focuses on GKE platform failures

## Architecture

### Smart Router Pattern

The parent `nightly` skill gathers status from GitHub Actions, classifies failures by the step that failed, and routes to the appropriate sub-skill. This prevents wasting time on deep investigation when the fix is simple (e.g., rerunning a transient auth failure).

### Context-Safe Execution

All skills redirect CI logs and kubectl output to files under `/tmp/llm-d/nightly-rca/` and analyze them via subagents. This prevents large log output from polluting the conversation context.

### Failure Categories

| Category | Sub-Skill | Typical Fix |
|----------|-----------|-------------|
| Auth/infra | `nightly:infra` | Rerun or rotate secret |
| GPU contention | `nightly:gpu` | Wait/rerun or clean leaked namespaces |
| Deploy | `nightly:deploy` | Fix chart values or rerun |
| Pod readiness | `nightly:pods` | Check image tags, resource limits |
| Test | `nightly:test` | Find regression commit, file issue |
| Unknown | `nightly:rca` | Full investigation |

## Repos Monitored

| Repo | Nightly Workflows |
|------|-------------------|
| `llm-d/llm-d` | 6 OCP + 3 GKE + 3 CKS + EC2 + HPU + XPU |
| `llm-d/llm-d-workload-variant-autoscaler` | 1 OCP WVA |

## Reusable Workflows (in this repo)

| File | Platform |
|------|----------|
| `reusable-nightly-e2e-openshift.yaml` | OpenShift (WVA) |
| `reusable-nightly-e2e-openshift-helmfile.yaml` | OpenShift (helmfile) |
| `reusable-nightly-e2e-gke-helmfile.yaml` | GKE (helmfile) |
| `reusable-nightly-e2e-cks-helmfile.yaml` | CKS/CoreWeave (helmfile) |
