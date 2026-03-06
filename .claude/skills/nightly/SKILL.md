---
name: nightly
description: Analyze nightly E2E job failures across llm-d repos. Smart router to sub-skills based on failure type.
---

# Nightly E2E Failure Analysis

Analyze and triage nightly E2E job failures across the llm-d org. This is the entry point — it routes to the appropriate sub-skill based on what happened.

## Context-Safe Execution (MANDATORY)

**CI logs and kubectl output can be hundreds of lines.** Always redirect to files:

```bash
export LOG_DIR=/tmp/llm-d/nightly-rca
mkdir -p $LOG_DIR

# Pattern: download CI logs to file, never into context
unset GITHUB_TOKEN && gh run view <run-id> --repo <repo> --log > $LOG_DIR/<run-id>.log 2>&1; echo "EXIT:$?"
# On failure: use Agent(subagent_type='Explore') with Grep to find errors
```

## When to Use

- Nightly cron job failed
- User says "check nightlies", "why did nightly fail", "triage failures"
- Proactive morning review of overnight runs

## Decision Tree

Follow this diagram as the workflow:

```
START
  |
  v
[1] Gather nightly run status (all repos)
  |
  v
[2] Any failures? ───No──> Report "All green" + exit
  |
  Yes
  v
[3] Classify each failure:
  |
  ├── Infra failure (auth, gcloud, AWS creds, runner) ──> nightly:infra
  ├── GPU contention (insufficient GPUs)               ──> nightly:gpu
  ├── Deploy failure (helmfile, helm, install.sh)       ──> nightly:deploy
  ├── Pod readiness timeout                             ──> nightly:pods
  ├── Test failure (e2e-validate, make test-e2e)        ──> nightly:test
  └── Unknown                                           ──> nightly:rca (full RCA)
```

## Step 1: Gather Status

```bash
export LOG_DIR=/tmp/llm-d/nightly-rca
mkdir -p $LOG_DIR

# Get all nightly/e2e runs from last 24h across key repos
for repo in llm-d/llm-d llm-d/llm-d-workload-variant-autoscaler; do
  unset GITHUB_TOKEN && gh run list --repo "$repo" --limit 50 \
    --json workflowName,status,conclusion,startedAt,databaseId,url \
    | jq '[.[] | select(
        (.workflowName | test("[Nn]ightly|[Ee]2[Ee]")) and
        (.startedAt > (now - 86400 | strftime("%Y-%m-%dT%H:%M:%SZ")))
      )]' > "$LOG_DIR/${repo##*/}-runs.json"
done
```

## Step 2: Identify Failures

```bash
# Extract failures
for f in $LOG_DIR/*-runs.json; do
  jq -r '.[] | select(.conclusion == "failure" or .conclusion == "startup_failure") |
    "\(.workflowName) | \(.conclusion) | \(.startedAt) | \(.databaseId)"' "$f"
done > $LOG_DIR/failures.txt
```

If `failures.txt` is empty, report all green and stop.

## Step 3: Classify Each Failure

For each failed run, get the failed step:

```bash
RUN_ID=<from failures.txt>
REPO=<repo>

unset GITHUB_TOKEN && gh run view "$RUN_ID" --repo "$REPO" --json jobs \
  | jq -r '.jobs[] | .steps[] | select(.conclusion == "failure") | .name' \
  > $LOG_DIR/failed-steps-$RUN_ID.txt
```

### Classification Rules

| Failed Step Pattern | Category | Sub-Skill |
|---|---|---|
| `Authenticate to Google Cloud`, `Set up gcloud`, `Configure AWS Credentials` | Infra auth | `nightly:infra` |
| `Set up runner`, `Set up job` (startup_failure) | Runner issue | `nightly:infra` |
| `Check GPU availability` | GPU contention | `nightly:gpu` |
| `Deploy guide via helmfile`, `Deploy guide via custom script`, `Deploy infrastructure` | Deploy failure | `nightly:deploy` |
| `Wait for pods to be ready`, `Wait for infrastructure` | Pod timeout | `nightly:pods` |
| `Run E2E validation`, `Run E2E tests`, `Run WVA E2E tests` | Test failure | `nightly:test` |
| Anything else | Unknown | `nightly:rca` |

## Step 4: Report

Create a summary table:

```markdown
## Nightly Status — YYYY-MM-DD

| Workflow | Platform | Status | Failed Step | Category |
|----------|----------|--------|-------------|----------|
| Inference Scheduling | OCP | pass | — | — |
| Wide EP LWS | OCP | FAIL | Wait for pods | pods |
| Inference Scheduling | GKE | FAIL | Set up gcloud | infra |
```

Then follow the appropriate sub-skill for each failure.

## Repos to Monitor

| Repo | Nightly Workflows |
|------|-------------------|
| `llm-d/llm-d` | 6 OCP + 3 GKE + 3 CKS + EC2 + HPU + XPU callers |
| `llm-d/llm-d-workload-variant-autoscaler` | 1 OCP WVA caller |

## Reusable Workflows (in this repo)

| Workflow | Platform | Type |
|----------|----------|------|
| `reusable-nightly-e2e-openshift.yaml` | OpenShift | WVA-specific |
| `reusable-nightly-e2e-openshift-helmfile.yaml` | OpenShift | Helmfile guides |
| `reusable-nightly-e2e-gke-helmfile.yaml` | GKE | Helmfile guides |
| `reusable-nightly-e2e-cks-helmfile.yaml` | CKS (CoreWeave) | Helmfile guides |

## Schedule Matrix

| Time (UTC) | OCP | GKE | CKS | EC2 | HPU | XPU |
|------------|-----|-----|-----|-----|-----|-----|
| 00:00 | inference-sched | | | | | |
| 00:30 | pd-disagg | | | | | |
| 01:00 | precise-prefix | | | | | |
| 01:30 | sim-accel | | | | | |
| 02:00 | tiered-prefix | | | | | |
| 02:30 | wide-ep-lws | | | | | |
| 03:00 | | | inference-sched | | | |
| 03:30 | | | pd-disagg | | | |
| 04:00 | | | wide-ep-lws | | inference-sched | |
| 04:30 | | | | | pd-gaudi | |
| 05:00 | | | wva | | | |
| 05:30 | | | benchmark | | | |
| 06:00 | | | | accel-test | | |
| 06:30 | | | | pd-accel | | |
| 07:00 | | | | wide-ep-accel | | |
| 10:00 | | inference-sched | | | | |
| 10:30 | | pd-disagg | | | | |
| 11:00 | | wide-ep-lws | | | | inference+pd+prefix |

## Related Skills

- `nightly:infra` — Infrastructure/auth failures
- `nightly:gpu` — GPU contention analysis
- `nightly:deploy` — Deployment failures
- `nightly:pods` — Pod readiness timeouts
- `nightly:test` — E2E test failures
- `nightly:rca` — Full root cause analysis
- `nightly:report` — Weekly trend report
