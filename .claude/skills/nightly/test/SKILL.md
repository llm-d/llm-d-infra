---
name: nightly:test
description: Diagnose E2E test failures in nightly runs (e2e-validate.sh, make test-e2e)
---

# Nightly E2E Test Failure Analysis

Diagnose failures in the actual E2E test execution phase — deployment succeeded, pods are ready, but tests failed.

## Context-Safe Execution (MANDATORY)

```bash
export LOG_DIR=/tmp/llm-d/nightly-rca
mkdir -p $LOG_DIR
```

## Symptom

`Run E2E validation` or `Run E2E tests` / `Run WVA E2E tests` step fails.

## Test Frameworks

| Platform/Guide | Test Method | Details |
|---|---|---|
| Helmfile guides (all platforms) | `e2e-validate.sh` | Shell-based smoke test: health, inference, routing |
| WVA (OpenShift) | `make test-e2e-openshift` | Go test suite: scale-up, scale-to-zero, scale-from-zero |

## Diagnosis

### 1. Download Logs

```bash
RUN_ID=<run-id>
REPO=llm-d/llm-d
GUIDE=<guide-name>
PLATFORM=<ocp|gke|cks>

# Pod logs (always uploaded)
unset GITHUB_TOKEN && gh run download "$RUN_ID" --repo "$REPO" \
  -n "nightly-pod-logs-${GUIDE}-${PLATFORM}" \
  -D $LOG_DIR/pod-logs-$RUN_ID/ 2>/dev/null

# Full run logs
unset GITHUB_TOKEN && gh api "repos/$REPO/actions/runs/$RUN_ID/logs" \
  > $LOG_DIR/run-$RUN_ID.zip 2>/dev/null
cd $LOG_DIR && unzip -o "run-$RUN_ID.zip" -d "run-$RUN_ID" 2>/dev/null; cd -
```

### 2. Identify Test Failures

#### For e2e-validate.sh (helmfile guides):

```bash
# Search for FAIL markers in run logs
grep -riE "FAIL|ERROR|assert.*failed|curl.*failed|HTTP.*[45][0-9][0-9]|Connection refused" \
  $LOG_DIR/run-$RUN_ID/ 2>/dev/null | grep -v "ignore-not-found" | head -30
```

The e2e-validate.sh script checks:
1. **Health check**: `curl <gateway-url>/health` returns 200
2. **Inference**: POST to inference endpoint returns valid response
3. **Routing**: Requests reach expected backend pods
4. **Gateway**: Gateway resource is `Programmed=True`

#### For WVA Go tests (make test-e2e-openshift):

```bash
# Search for Go test failures
grep -riE "FAIL|--- FAIL|panic|timeout.*exceeded|context deadline" \
  $LOG_DIR/run-$RUN_ID/ 2>/dev/null | head -30
```

WVA E2E tests check:
1. **Scale-up**: Send load, verify replicas increase
2. **Scale-to-zero**: Stop load, verify replicas decrease to 0
3. **Scale-from-zero**: Resume load, verify replicas come back

### 3. Common Test Failure Patterns

| Error | Likely Cause | Investigation |
|---|---|---|
| `Connection refused` on gateway | Gateway pod not forwarding | Check gateway/istio pod logs |
| `HTTP 503` from inference | Model pods not registered with InferencePool | Check EPP logs |
| `HTTP 502` | Upstream connection failed | Check vLLM pod logs for errors |
| `Timeout waiting for scale-up` | Metrics pipeline broken | Check Prometheus, adapter, WVA logs |
| `Expected replicas N, got M` | HPA misconfigured or metrics delayed | Check HPA describe, VA status |
| `context deadline exceeded` | Test timeout too short | Increase test timeout |

### 4. Check Component Logs

From the pod logs artifact:

```bash
# EPP (Endpoint Picker) logs — routing issues
cat $LOG_DIR/pod-logs-$RUN_ID/epp-*.log 2>/dev/null | tail -50

# vLLM decode pod logs — inference issues
cat $LOG_DIR/pod-logs-$RUN_ID/ms-*decode*.log 2>/dev/null | tail -50

# Gateway logs
cat $LOG_DIR/pod-logs-$RUN_ID/*gateway*.log 2>/dev/null | tail -50

# WVA controller logs (WVA only)
cat $LOG_DIR/pod-logs-$RUN_ID/*workload-variant*.log 2>/dev/null | tail -50
```

## Correlation: Was it a Regression?

```bash
# Find when this test last passed
unset GITHUB_TOKEN && gh run list --repo "$REPO" --limit 30 \
  --json workflowName,conclusion,startedAt \
  | jq -r ".[] | select(.workflowName | test(\"$GUIDE\")) | \"\(.conclusion) | \(.startedAt)\""

# What changed in llm-d/llm-d since last success?
SINCE=<last-success-date>
unset GITHUB_TOKEN && gh api "repos/llm-d/llm-d/commits?since=$SINCE" \
  | jq -r '.[] | "\(.sha[:8]) \(.commit.message | split("\n")[0])"' | head -20
```

## Resolution

### Test-specific fix needed:
- File issue with test output, pod logs, and regression commit range
- Tag relevant guide owner

### Transient network/timing issue:
```bash
unset GITHUB_TOKEN && gh run rerun "$RUN_ID" --repo "$REPO"
```

### Metrics pipeline broken (WVA):
- Check `nightly:rca` for full metrics pipeline debug
- Verify Prometheus scraping, Prometheus Adapter, external metrics API

## Related Skills

- `nightly` — Parent router
- `nightly:pods` — If pods were the real issue
- `nightly:rca` — Full root cause analysis
