---
name: nightly:gpu
description: Diagnose GPU contention failures in nightly E2E runs
---

# Nightly GPU Contention Analysis

Diagnose failures caused by insufficient GPU availability in nightly E2E runs.

## Context-Safe Execution (MANDATORY)

```bash
export LOG_DIR=/tmp/llm-d/nightly-rca
mkdir -p $LOG_DIR
```

## Symptom

`Check GPU availability` step fails with:
```
::error::Insufficient GPUs: need N, have M available
```

## Diagnosis

### 1. Get GPU Status from Step Summary

```bash
RUN_ID=<run-id>
REPO=llm-d/llm-d

# Download run logs to find GPU status table
unset GITHUB_TOKEN && gh api "repos/$REPO/actions/runs/$RUN_ID/logs" \
  > $LOG_DIR/run-$RUN_ID.zip 2>/dev/null
cd $LOG_DIR && unzip -o "run-$RUN_ID.zip" -d "run-$RUN_ID" 2>/dev/null; cd -

# Extract GPU status from logs
grep -rE "Total cluster GPUs|Currently allocated|Available|Required|Recommended" \
  $LOG_DIR/run-$RUN_ID/ 2>/dev/null
```

### 2. Check Who's Using GPUs

If you have cluster access:
```bash
# OCP cluster
export KUBECONFIG=<path>

# GPU allocation by namespace
kubectl get pods --all-namespaces -o json | jq -r '
  [.items[] |
   select(.status.phase == "Running" or .status.phase == "Pending") |
   select(.spec.containers[]?.resources.requests["nvidia.com/gpu"] != null) |
   {
     namespace: .metadata.namespace,
     name: .metadata.name,
     gpus: (.spec.containers[].resources.requests["nvidia.com/gpu"] // "0" | tonumber)
   }] | group_by(.namespace) | .[] |
   {
     namespace: .[0].namespace,
     total_gpus: ([.[].gpus] | add),
     pods: ([.[].name])
   }' > $LOG_DIR/gpu-allocation.json
```

### 3. Check Schedule Overlap

Multiple nightly runs may overlap and compete for GPUs. Cross-reference the schedule:

| Time (UTC) | OCP | GPU Req |
|------------|-----|---------|
| 00:00 | inference-sched | 2 |
| 00:30 | pd-disagg | 2 |
| 01:00 | precise-prefix | 2 |
| 01:30 | sim-accel | 0 |
| 02:00 | tiered-prefix | 1 |
| 02:30 | wide-ep-lws | 2 |

If a prior run's cleanup didn't finish before the next run's GPU check, the prior run's pods still hold GPUs.

### 4. Check for Leaked Namespaces

Previous nightly runs that failed cleanup can leave GPU-holding pods behind:

```bash
# Find nightly namespaces that shouldn't exist
kubectl get ns | grep -E "nightly|llm-d-nightly"

# Find GPU pods in nightly namespaces
kubectl get pods -A -o json | jq -r '
  .items[] | select(
    (.metadata.namespace | test("nightly")) and
    (.spec.containers[]?.resources.requests["nvidia.com/gpu"] != null)
  ) | "\(.metadata.namespace)/\(.metadata.name) — \(.spec.containers[0].resources.requests["nvidia.com/gpu"]) GPUs"'
```

## Resolution

### Immediate: Rerun with Wait

If the cluster is shared and GPUs are temporarily busy:
```bash
# Rerun with GPU wait (30 min)
unset GITHUB_TOKEN && gh workflow run "nightly-e2e-<guide>.yaml" \
  --repo llm-d/llm-d \
  -f gpu_wait_timeout=30
```

### Immediate: Clean Up Leaked Resources

```bash
# Delete leaked nightly namespaces (CAREFUL: verify these are stale)
for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep "nightly"); do
  echo "Checking $ns..."
  AGE=$(kubectl get ns "$ns" -o jsonpath='{.metadata.creationTimestamp}')
  echo "  Created: $AGE"
  kubectl get pods -n "$ns" --no-headers | wc -l
done
# Only delete if confirmed stale:
# kubectl delete ns <stale-nightly-ns> --timeout=120s
```

### Long-term: Adjust Schedule

If GPU contention is recurring:
1. Stagger cron schedules further apart
2. Reduce GPU requirements for nightly (use smaller models)
3. Add `gpu_wait_timeout` to callers
4. Enable `allow_gpu_preemption` (GKE/CKS only)

## Related Skills

- `nightly` — Parent router
- `nightly:pods` — Pod readiness (often follows GPU issues)
