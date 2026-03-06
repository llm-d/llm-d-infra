---
name: nightly:pods
description: Diagnose pod readiness timeout failures in nightly E2E runs
---

# Nightly Pod Readiness Failure Analysis

Diagnose failures where deployment succeeded but pods didn't become ready in time.

## Context-Safe Execution (MANDATORY)

```bash
export LOG_DIR=/tmp/llm-d/nightly-rca
mkdir -p $LOG_DIR
```

## Symptom

`Wait for pods to be ready` step fails with:
```
::error::Pods in <namespace> did not become ready within 30m
```

## Diagnosis

### 1. Download Pod Logs Artifact

Every nightly run (even failures) uploads pod logs as an artifact:

```bash
RUN_ID=<run-id>
REPO=llm-d/llm-d
GUIDE=<guide-name>
PLATFORM=<ocp|gke|cks>

unset GITHUB_TOKEN && gh run download "$RUN_ID" --repo "$REPO" \
  -n "nightly-pod-logs-${GUIDE}-${PLATFORM}" \
  -D $LOG_DIR/pod-logs-$RUN_ID/ 2>/dev/null

# List what we got
ls -la $LOG_DIR/pod-logs-$RUN_ID/
```

### 2. Classify Pod Failure

```bash
# Find non-running pods from describe files
grep -l "Status:.*Pending\|Status:.*Failed\|CrashLoopBackOff\|ImagePullBackOff\|Error\|OOMKilled" \
  $LOG_DIR/pod-logs-$RUN_ID/*-describe.log 2>/dev/null
```

### Common Pod Failure Categories

#### A. ImagePullBackOff

```bash
grep -rE "ImagePullBackOff|ErrImagePull|401.*Unauthorized|manifest unknown" \
  $LOG_DIR/pod-logs-$RUN_ID/*-describe.log 2>/dev/null
```

**Causes**:
- GHCR token expired or missing permissions
- Image tag doesn't exist (chart bumped version, image not built yet)
- Private registry without imagePullSecret

**Check**: Download `image-metadata.json` artifact:
```bash
unset GITHUB_TOKEN && gh run download "$RUN_ID" --repo "$REPO" \
  -n "image-metadata" -D $LOG_DIR/image-meta-$RUN_ID/ 2>/dev/null
cat $LOG_DIR/image-meta-$RUN_ID/image-metadata.json | jq .
```

#### B. CrashLoopBackOff

```bash
# Get logs from crashing pods
for log in $LOG_DIR/pod-logs-$RUN_ID/*.log; do
  if grep -q "Error\|panic\|FATAL\|Traceback\|OOMKilled" "$log" 2>/dev/null; then
    echo "=== $(basename $log) ==="
    tail -30 "$log"
  fi
done
```

**Causes**:
- Model too large for available GPU memory (OOM)
- Config file missing or invalid
- Dependency service not ready (etcd, redis for P/D)

#### C. Pending (Unschedulable)

```bash
grep -rE "Unschedulable|Insufficient.*gpu\|cpu\|memory|didn't match Pod's node" \
  $LOG_DIR/pod-logs-$RUN_ID/*-describe.log 2>/dev/null
```

**Causes**:
- GPU nodes full (see `nightly:gpu`)
- Node affinity/toleration mismatch
- PersistentVolumeClaim pending

#### D. Init Container Stuck

```bash
grep -rE "Init:.*0/[0-9]|PodInitializing" \
  $LOG_DIR/pod-logs-$RUN_ID/*-describe.log 2>/dev/null
```

**Causes**:
- Model download from HuggingFace slow or token invalid
- Init script waiting for dependency

#### E. Model Loading Timeout

vLLM pods may be Running but not Ready (readiness probe failing):

```bash
# Check for model loading in vLLM logs
grep -rE "Loading model|Downloading|Loading.*weights|torch.distributed" \
  $LOG_DIR/pod-logs-$RUN_ID/ms-*.log 2>/dev/null | tail -20
```

**Causes**:
- Large model takes longer than pod_wait_timeout (default: 30m)
- Slow storage or network on GPU nodes
- Model download from HF Hub throttled

**Fix**: Increase `pod_wait_timeout` in caller workflow.

## Resolution Matrix

| Category | Transient? | Action |
|----------|-----------|--------|
| ImagePullBackOff | Maybe | Check if image exists; if yes, rerun |
| CrashLoop (OOM) | No | Reduce model size or increase GPU count |
| CrashLoop (config) | No | Fix config in guide values |
| Pending (GPU) | Maybe | See `nightly:gpu` |
| Pending (PVC) | Maybe | Check StorageClass on platform |
| Model loading timeout | Maybe | Increase pod_wait_timeout; add model caching |

## Quick Rerun

```bash
unset GITHUB_TOKEN && gh run rerun "$RUN_ID" --repo "$REPO"
```

## Related Skills

- `nightly` — Parent router
- `nightly:gpu` — GPU availability issues
- `nightly:deploy` — If deploy itself failed
