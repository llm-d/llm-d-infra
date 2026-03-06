---
name: nightly:infra
description: Diagnose infrastructure and authentication failures in nightly E2E runs (GCP, AWS, runner issues)
---

# Nightly Infrastructure Failure Analysis

Diagnose failures in the infrastructure/auth layer of nightly E2E runs. These are failures that happen **before** any Kubernetes work begins.

## Context-Safe Execution (MANDATORY)

```bash
export LOG_DIR=/tmp/llm-d/nightly-rca
mkdir -p $LOG_DIR
```

## Common Failure Patterns

### 1. GCP Authentication Failure

**Symptom**: `Authenticate to Google Cloud` or `Set up gcloud CLI and kubectl` step fails.

**Diagnosis**:
```bash
RUN_ID=<run-id>
REPO=llm-d/llm-d

# Get job annotations/error messages
unset GITHUB_TOKEN && gh run view "$RUN_ID" --repo "$REPO" --json jobs \
  | jq '.jobs[0].steps[] | select(.conclusion == "failure")' \
  > $LOG_DIR/infra-failure-$RUN_ID.json

# Download full logs
unset GITHUB_TOKEN && gh api "repos/$REPO/actions/runs/$RUN_ID/logs" \
  > $LOG_DIR/run-$RUN_ID.zip 2>/dev/null
cd $LOG_DIR && unzip -o "run-$RUN_ID.zip" -d "run-$RUN_ID" 2>/dev/null; cd -
```

**Root Causes**:
| Error | Cause | Fix |
|-------|-------|-----|
| `google-github-actions/auth failed` | `GKE_SA_KEY` secret expired/rotated | Org admin: rotate secret in llm-d org settings |
| `gcloud components install failed` | Ubuntu package mirror issue | Transient — rerun workflow |
| `auth plugin not found` | gke-gcloud-auth-plugin missing | Check `install_components` in workflow |

**Action**: If secret expired, file issue on llm-d/llm-d-infra. If transient, rerun:
```bash
unset GITHUB_TOKEN && gh run rerun "$RUN_ID" --repo "$REPO"
```

### 2. AWS Credential Failure

**Symptom**: `Configure AWS Credentials` step fails (EC2 workflows).

**Root Causes**:
| Error | Cause | Fix |
|-------|-------|-----|
| `Credentials could not be loaded` | OIDC provider misconfigured | Check GitHub OIDC setup in AWS IAM |
| `AssumeRoleWithWebIdentity` error | IAM role trust policy expired | Org admin: update trust policy |
| `ExpiredToken` | Session token expired | Rerun — tokens are per-run |

### 3. Runner Startup Failure

**Symptom**: Run shows `startup_failure` conclusion. No steps executed.

**Root Causes**:
- Self-hosted runner offline (OCP, CKS)
- Runner labels don't match (`self-hosted, openshift, pok-prod`)
- Runner VM crashed or ran out of disk

**Diagnosis**:
```bash
# Check runner status (requires admin)
unset GITHUB_TOKEN && gh api "repos/$REPO/actions/runners" \
  | jq '.runners[] | {name, status, busy, labels: [.labels[].name]}'
```

**Action**: If runners are offline, escalate to infra team. If labels changed, update workflow.

### 4. Tool Installation Failure

**Symptom**: `Install prerequisites` or `Install tools` step fails.

**Root Causes**:
- `dl.k8s.io` or `mirror.openshift.com` temporarily down
- Network connectivity on runner
- `apt-get update` failure (Ubuntu mirror)

**Action**: Rerun. If persistent across multiple runs, check:
```bash
# From the logs, grep for specific download failures
grep -iE "curl.*failed|404|timeout|Could not resolve" $LOG_DIR/run-$RUN_ID/*.txt 2>/dev/null
```

## Triage Decision

```
Is the failure transient (first occurrence in 3 days)?
  ├── Yes ──> Rerun the workflow
  └── No (repeated) ──> File issue:
      ├── Secret rotation ──> llm-d/llm-d-infra
      ├── Runner issue ──> llm-d/llm-d-infra
      └── Network/mirror ──> rerun + monitor
```

## Related Skills

- `nightly` — Parent router
- `nightly:rca` — Full root cause analysis when infra issues cascade
