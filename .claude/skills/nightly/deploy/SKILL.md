---
name: nightly:deploy
description: Diagnose deployment failures in nightly E2E runs (helmfile, helm, install.sh)
---

# Nightly Deploy Failure Analysis

Diagnose failures during the deployment phase of nightly E2E runs.

## Context-Safe Execution (MANDATORY)

```bash
export LOG_DIR=/tmp/llm-d/nightly-rca
mkdir -p $LOG_DIR
```

## Failed Step Patterns

| Step | Workflow Type | Deploy Method |
|------|-------------|---------------|
| `Deploy guide via helmfile` | helmfile-based | `helmfile apply` |
| `Deploy guide via custom script` | kustomize+helm | Custom bash script |
| `Deploy infrastructure` | WVA (legacy) | `deploy/install.sh` |
| `Install gateway provider` | OCP helmfile | `istioctl install` or helm |

## Diagnosis

### 1. Download Artifacts

```bash
RUN_ID=<run-id>
REPO=llm-d/llm-d

# Download pod logs artifact (collected on every run, even failures)
unset GITHUB_TOKEN && gh run download "$RUN_ID" --repo "$REPO" \
  -n "nightly-pod-logs-<guide-name>-<platform>" \
  -D $LOG_DIR/pod-logs-$RUN_ID/ 2>/dev/null

# Download helmfile deploy log
unset GITHUB_TOKEN && gh run download "$RUN_ID" --repo "$REPO" \
  -n "helm-values-*" \
  -D $LOG_DIR/helm-$RUN_ID/ 2>/dev/null

# Download full run logs
unset GITHUB_TOKEN && gh api "repos/$REPO/actions/runs/$RUN_ID/logs" \
  > $LOG_DIR/run-$RUN_ID.zip 2>/dev/null
cd $LOG_DIR && unzip -o "run-$RUN_ID.zip" -d "run-$RUN_ID" 2>/dev/null; cd -
```

### 2. Common Helmfile Failures

```bash
# Search for helmfile errors
grep -riE "error|FAIL|helm.*failed|release.*failed|timeout|timed out" \
  $LOG_DIR/run-$RUN_ID/ 2>/dev/null | grep -v "ignore-not-found" | head -30
```

| Error Pattern | Cause | Fix |
|---|---|---|
| `release "X" failed` | Chart values incompatible | Check guide's `values*.yaml` against chart version |
| `timed out waiting for condition` | CRDs not installed | Ensure CRD install step ran before helmfile |
| `cannot re-use a name that is still in use` | Previous cleanup failed | Manual cleanup: `helm uninstall -n <ns>` |
| `Error: INSTALLATION FAILED: rendered manifests contain a resource that already exists` | Orphaned resources | Delete the conflicting resource, then retry |
| `context deadline exceeded` | Helm timeout too short | Increase `--timeout` in helmfile args |
| `ImagePullBackOff` during deploy | GHCR auth or image tag missing | Check `image-metadata.json` artifact for resolved tags |

### 3. Custom Script Failures (Kustomize+Helm)

For guides using `custom_deploy_script` (tiered-prefix-cache, wide-ep-lws):

```bash
# The custom script is inlined in the caller workflow — check the workflow file
grep -A 20 "custom_deploy_script:" $LOG_DIR/run-$RUN_ID/*.txt 2>/dev/null
```

Common issues:
- `kustomize build` fails on invalid overlays
- LeaderWorkerSet CRD not installed
- Helm install needs `--create-namespace` but namespace already exists

### 4. WVA deploy/install.sh Failures

```bash
# Search for install.sh specific errors
grep -riE "install.sh|deploy/install" $LOG_DIR/run-$RUN_ID/ 2>/dev/null | tail -20
```

Common issues:
- `deploy/install.sh not found` — caller repo checkout failed
- Helm chart version mismatch between WVA and llm-d charts

## Resolution

### Transient: Rerun

If the failure looks transient (network timeout, mirror down):
```bash
unset GITHUB_TOKEN && gh run rerun "$RUN_ID" --repo "$REPO"
```

### Chart/Values Change: Check Recent Commits

```bash
# What changed in llm-d/llm-d guides since last successful run?
LAST_SUCCESS_DATE=$(unset GITHUB_TOKEN && gh run list --repo llm-d/llm-d --limit 50 \
  --json workflowName,conclusion,startedAt \
  | jq -r '[.[] | select(.workflowName | test("<guide>")) | select(.conclusion == "success")][0].startedAt')

unset GITHUB_TOKEN && gh api "repos/llm-d/llm-d/commits?since=$LAST_SUCCESS_DATE&path=guides/<guide-name>" \
  | jq -r '.[] | "\(.sha[:8]) \(.commit.message | split("\n")[0])"'
```

### File Issue

If the failure is a real regression:
```bash
unset GITHUB_TOKEN && gh issue create --repo llm-d/llm-d \
  --title "Nightly E2E: <guide> deploy failure on <platform>" \
  --body "Run: https://github.com/llm-d/llm-d/actions/runs/$RUN_ID
Failed step: <step-name>
Error: <error-summary>
Last successful: <date>"
```

## Related Skills

- `nightly` — Parent router
- `nightly:pods` — If deploy succeeds but pods don't come up
