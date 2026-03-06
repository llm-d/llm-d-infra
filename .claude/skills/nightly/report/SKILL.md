---
name: nightly:report
description: Generate weekly nightly E2E trend report with failure patterns and success rates
---

# Nightly Weekly Trend Report

Generate a comprehensive weekly report of nightly E2E job health across all platforms and guides.

## Context-Safe Execution (MANDATORY)

```bash
export LOG_DIR=/tmp/llm-d/nightly-report
mkdir -p $LOG_DIR
```

## When to Use

- Weekly review of nightly health
- User says "nightly report", "weekly summary", "how are nightlies doing"
- Before a release to verify stability

## Phase 0: Gather All Data

```bash
# Get last 7 days of runs from all repos
SINCE=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "7 days ago" +%Y-%m-%dT%H:%M:%SZ)

for repo in llm-d/llm-d llm-d/llm-d-workload-variant-autoscaler; do
  unset GITHUB_TOKEN && gh run list --repo "$repo" --limit 500 \
    --json workflowName,status,conclusion,startedAt,databaseId,url,updatedAt \
    | jq "[.[] | select(
        (.workflowName | test(\"[Nn]ightly|[Ee]2[Ee]\")) and
        (.startedAt > \"$SINCE\")
      )]" > "$LOG_DIR/${repo##*/}-runs.json"
done
```

## Phase 1: Success Rate by Workflow

```bash
# Calculate success rate per workflow
for f in $LOG_DIR/*-runs.json; do
  jq -r 'group_by(.workflowName) | .[] | {
    workflow: .[0].workflowName,
    total: length,
    success: [.[] | select(.conclusion == "success")] | length,
    failure: [.[] | select(.conclusion == "failure")] | length,
    other: [.[] | select(.conclusion != "success" and .conclusion != "failure")] | length
  } | "\(.workflow) | \(.success)/\(.total) (\(.success * 100 / .total)%) | \(.failure) failures"' "$f"
done > $LOG_DIR/success-rates.txt
```

## Phase 2: Failure Timeline

```bash
# List all failures with dates
for f in $LOG_DIR/*-runs.json; do
  jq -r '.[] | select(.conclusion == "failure") |
    "\(.startedAt | split("T")[0]) | \(.workflowName) | \(.databaseId)"' "$f"
done | sort > $LOG_DIR/failure-timeline.txt
```

## Phase 3: Failure Categorization

For each failure, get the failed step:

```bash
while IFS='|' read -r date workflow run_id; do
  run_id=$(echo "$run_id" | tr -d ' ')
  workflow=$(echo "$workflow" | tr -d ' ')
  REPO="llm-d/llm-d"
  FAILED_STEP=$(unset GITHUB_TOKEN && gh run view "$run_id" --repo "$REPO" --json jobs \
    | jq -r '.jobs[0].steps[] | select(.conclusion == "failure") | .name' 2>/dev/null | head -1)
  echo "$date | $workflow | $FAILED_STEP | $run_id"
done < $LOG_DIR/failure-timeline.txt > $LOG_DIR/categorized-failures.txt
```

## Phase 4: Generate Report

### Template

```markdown
## Nightly E2E Report — Week of YYYY-MM-DD

### Summary
- **Total runs**: N
- **Pass rate**: X% (Y/N)
- **Unique failures**: Z

### Success Rate by Workflow

| Workflow | Pass Rate | Failures | Trend |
|----------|-----------|----------|-------|
| Inference Scheduling (OCP) | 7/7 (100%) | 0 | stable |
| Wide EP LWS (OCP) | 3/7 (43%) | 4 | degraded |
| PD Disaggregation (GKE) | 5/7 (71%) | 2 | flaky |

### Failure Breakdown by Category

| Category | Count | % of Failures |
|----------|-------|---------------|
| Infra/Auth | N | X% |
| GPU Contention | N | X% |
| Deploy | N | X% |
| Pod Readiness | N | X% |
| Test | N | X% |

### Notable Patterns
- <pattern 1: e.g., "All GKE failures are gcloud auth — likely secret rotation needed">
- <pattern 2: e.g., "Wide EP consistently fails pod readiness — LWS scaling issue">

### Action Items
- [ ] <action 1>
- [ ] <action 2>

### Daily Heatmap

| Day | OCP | GKE | CKS | EC2 | HPU |
|-----|-----|-----|-----|-----|-----|
| Mon | 6/6 | 2/3 | — | 1/1 | 2/2 |
| Tue | 5/6 | 3/3 | — | 0/1 | 2/2 |
| ... | ... | ... | ... | ... | ... |
```

## Phase 5: Trend Analysis

Compare this week vs previous:

```bash
# Get previous week's data
PREV_SINCE=$(date -u -v-14d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "14 days ago" +%Y-%m-%dT%H:%M:%SZ)
PREV_UNTIL=$SINCE

for repo in llm-d/llm-d llm-d/llm-d-workload-variant-autoscaler; do
  unset GITHUB_TOKEN && gh run list --repo "$repo" --limit 500 \
    --json workflowName,conclusion,startedAt \
    | jq "[.[] | select(
        (.workflowName | test(\"[Nn]ightly|[Ee]2[Ee]\")) and
        (.startedAt > \"$PREV_SINCE\") and
        (.startedAt < \"$PREV_UNTIL\")
      )]" > "$LOG_DIR/${repo##*/}-prev-week.json"
done
```

Trends: improving, stable, degraded, new failure

## Related Skills

- `nightly` — Parent router (for individual failure triage)
- `nightly:rca` — Deep dive on specific failures flagged in report
