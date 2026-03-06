---
name: nightly:rca
description: Full root cause analysis for nightly E2E failures that don't fit simple categories
---

# Nightly Full Root Cause Analysis

Deep investigation for nightly failures that don't clearly fit infra/gpu/deploy/pods/test categories, or when simpler analysis didn't find the root cause.

## Context-Safe Execution (MANDATORY)

```bash
export LOG_DIR=/tmp/llm-d/nightly-rca
mkdir -p $LOG_DIR
```

## When to Use

- Failure doesn't match any known pattern
- Multiple failures across platforms (systemic issue)
- Simpler sub-skill didn't find root cause
- User wants a deep investigation

## Phase 1: Gather All Evidence

```bash
RUN_ID=<run-id>
REPO=llm-d/llm-d
GUIDE=<guide-name>
PLATFORM=<platform>

# 1. Run metadata
unset GITHUB_TOKEN && gh run view "$RUN_ID" --repo "$REPO" --json \
  jobs,conclusion,createdAt,updatedAt,headSha,headBranch,event,workflowName \
  > $LOG_DIR/meta-$RUN_ID.json

# 2. All step results
unset GITHUB_TOKEN && gh run view "$RUN_ID" --repo "$REPO" --json jobs \
  | jq '.jobs[0].steps[] | {number, name, conclusion, startedAt, completedAt}' \
  > $LOG_DIR/steps-$RUN_ID.json

# 3. Full run logs
unset GITHUB_TOKEN && gh api "repos/$REPO/actions/runs/$RUN_ID/logs" \
  > $LOG_DIR/run-$RUN_ID.zip 2>/dev/null
cd $LOG_DIR && unzip -o "run-$RUN_ID.zip" -d "run-$RUN_ID" 2>/dev/null; cd -

# 4. Pod logs artifact
unset GITHUB_TOKEN && gh run download "$RUN_ID" --repo "$REPO" \
  -n "nightly-pod-logs-${GUIDE}-${PLATFORM}" \
  -D $LOG_DIR/pod-logs-$RUN_ID/ 2>/dev/null

# 5. Image metadata artifact
unset GITHUB_TOKEN && gh run download "$RUN_ID" --repo "$REPO" \
  -n "image-metadata" \
  -D $LOG_DIR/image-meta-$RUN_ID/ 2>/dev/null

# 6. Helm values artifact (if available)
unset GITHUB_TOKEN && gh run download "$RUN_ID" --repo "$REPO" \
  -n "helm-values-*" \
  -D $LOG_DIR/helm-$RUN_ID/ 2>/dev/null
```

## Phase 2: Error Extraction

Use a subagent to search through the downloaded logs:

```
Agent(subagent_type='Explore'):
  Search through $LOG_DIR/run-$RUN_ID/ and $LOG_DIR/pod-logs-$RUN_ID/ for:
  1. All lines containing: error, Error, ERROR, FAIL, panic, fatal, timeout, refused
  2. Exit codes != 0
  3. Kubernetes events (Warning, FailedScheduling, BackOff)
  4. HTTP status codes 4xx/5xx
  Report: file, line number, error message, timestamp
```

## Phase 3: Timeline Reconstruction

Build a timeline of events:

1. **Run started**: from meta JSON
2. **Each step start/end**: from steps JSON
3. **First error**: from log grep
4. **Pod events**: from describe logs (Events section)
5. **Cascading failures**: errors that follow the first error

## Phase 4: Cross-Run Correlation

Compare this failure with recent history:

```bash
# Same workflow, last 10 runs
unset GITHUB_TOKEN && gh run list --repo "$REPO" --limit 50 \
  --json workflowName,conclusion,startedAt,databaseId \
  | jq "[.[] | select(.workflowName | test(\"$GUIDE\"))][:10]" \
  > $LOG_DIR/history-$GUIDE.json

# Check if failure correlates with a commit
HEAD_SHA=$(jq -r '.headSha' $LOG_DIR/meta-$RUN_ID.json)
unset GITHUB_TOKEN && gh api "repos/llm-d/llm-d/commits?sha=$HEAD_SHA&per_page=10" \
  | jq -r '.[] | "\(.sha[:8]) \(.commit.author.date) \(.commit.message | split("\n")[0])"' \
  > $LOG_DIR/commits-$RUN_ID.txt

# Check if other platforms also failed (systemic vs platform-specific)
jq -r '.[] | "\(.workflowName) | \(.conclusion) | \(.startedAt)"' $LOG_DIR/*-runs.json \
  | grep "$GUIDE" | sort -t'|' -k3
```

## Phase 5: Root Cause Classification

After gathering evidence, classify:

| Pattern | Root Cause | Action |
|---------|-----------|--------|
| Same failure across all platforms | Code/chart regression | Find breaking commit, file issue |
| Single platform failure | Platform-specific infra issue | `nightly:infra` or platform team |
| Intermittent (passes on rerun) | Flaky test or timing issue | Add retry logic or increase timeout |
| Started after specific commit | Regression | `git bisect` or review commit diff |
| GPU/memory related | Resource constraint | `nightly:gpu` or reduce model size |
| New workflow/caller issue | Workflow bug | Fix in llm-d-infra or caller |

## Phase 6: Report

Generate a structured RCA:

```markdown
## RCA: <Workflow Name> — <Date>

**Run**: <url>
**Status**: failure
**Failed Step**: <step-name>
**Platform**: <OCP/GKE/CKS>

### Root Cause
<1-2 sentence description>

### Evidence
- <key log line 1>
- <key log line 2>

### Correlation
- First failure: <date>
- Affected platforms: <list>
- Candidate commit: <sha> <message>

### Recommended Fix
<specific action>

### Immediate Action
- [ ] Rerun / File issue / Fix PR
```

## Related Skills

- `nightly` — Parent router (start here)
- `nightly:report` — Weekly trend report
