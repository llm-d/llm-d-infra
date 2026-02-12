# llm-d-infra

Repo for CI and infrastructure required to maintain llm-d org member repos.

## Reusable Workflows

This repo provides [reusable GitHub Actions workflows](https://docs.github.com/en/actions/sharing-automations/reusing-workflows) that standardize CI/CD across all llm-d repos. Instead of copy-pasting workflow files, each repo calls the shared version with a thin caller workflow.

### Available Workflows

| Workflow | Purpose | Caller Trigger |
|----------|---------|----------------|
| `reusable-prow-commands.yml` | Prow-style commands (/lgtm, /approve, /assign, etc.) | `issue_comment` |
| `reusable-prow-automerge.yml` | Auto-merge PRs with `lgtm` label | `schedule` (every 5 min) |
| `reusable-prow-remove-lgtm.yml` | Remove `lgtm` label on PR push | `pull_request` |
| `reusable-stale.yml` | Mark stale issues/PRs, then rotten, then close | `schedule` (daily) |
| `reusable-unstale.yml` | Remove stale/rotten labels on activity | `issues` + `issue_comment` |
| `reusable-signed-commits.yml` | Enforce signed/DCO commits | `pull_request_target` |
| `reusable-typos.yml` | Spell-check code and docs | `pull_request` + `push` |
| `reusable-md-link-check.yml` | Validate markdown links with lychee | `push` + `pull_request` |
| `reusable-non-main-gatekeeper.yml` | Block PRs to non-main branches | `pull_request` |

### Usage

Create a thin caller workflow in your repo's `.github/workflows/` directory. Each caller is typically 8-12 lines:

```yaml
# .github/workflows/prow-github.yml
name: Prow Commands
on:
  issue_comment:
    types: [created]
jobs:
  prow:
    uses: llm-d/llm-d-infra/.github/workflows/reusable-prow-commands.yml@main
    permissions:
      issues: write
      pull-requests: write
```

```yaml
# .github/workflows/prow-pr-automerge.yml
name: Prow Auto-merge
on:
  schedule:
    - cron: "*/5 * * * *"
jobs:
  auto-merge:
    uses: llm-d/llm-d-infra/.github/workflows/reusable-prow-automerge.yml@main
```

```yaml
# .github/workflows/prow-pr-remove-lgtm.yml
name: Prow Remove LGTM
on: pull_request
jobs:
  remove-lgtm:
    uses: llm-d/llm-d-infra/.github/workflows/reusable-prow-remove-lgtm.yml@main
```

```yaml
# .github/workflows/stale.yaml
name: Mark Stale Issues
on:
  schedule:
    - cron: '0 1 * * *'
jobs:
  stale:
    uses: llm-d/llm-d-infra/.github/workflows/reusable-stale.yml@main
    permissions:
      issues: write
      pull-requests: write
```

```yaml
# .github/workflows/unstale.yaml
name: Unstale Issues
on:
  issues:
    types: [reopened]
  issue_comment:
    types: [created]
jobs:
  unstale:
    uses: llm-d/llm-d-infra/.github/workflows/reusable-unstale.yml@main
    permissions:
      issues: write
```

```yaml
# .github/workflows/ci-signed-commits.yaml
name: Check Signed Commits
on: pull_request_target
jobs:
  signed-commits:
    uses: llm-d/llm-d-infra/.github/workflows/reusable-signed-commits.yml@main
    permissions:
      contents: read
      pull-requests: write
```

```yaml
# .github/workflows/check-typos.yaml
name: Check Typos
on:
  pull_request:
  push:
jobs:
  typos:
    uses: llm-d/llm-d-infra/.github/workflows/reusable-typos.yml@main
```

```yaml
# .github/workflows/md-link-check.yml
name: Markdown Link Check
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:
jobs:
  links:
    uses: llm-d/llm-d-infra/.github/workflows/reusable-md-link-check.yml@main
```

```yaml
# .github/workflows/non-main-gatekeeper.yml
name: Non-Main Gatekeeper
on:
  pull_request:
    types: [opened, edited, synchronize, reopened]
jobs:
  gatekeeper:
    uses: llm-d/llm-d-infra/.github/workflows/reusable-non-main-gatekeeper.yml@main
```

### Customization

Most workflows accept optional inputs. See each workflow file for available inputs and defaults:

```yaml
jobs:
  stale:
    uses: llm-d/llm-d-infra/.github/workflows/reusable-stale.yml@main
    with:
      days-before-issue-stale: 60  # override default of 90
```

## Templates

The `templates/` directory contains canonical configuration files for adoption across repos:

| Template | Purpose | Copy To |
|----------|---------|---------|
| `dependabot.yml` | Automated dependency updates for Go, Actions, Docker | `.github/dependabot.yml` |
| `.pre-commit-config.yaml` | File hygiene, shell/Dockerfile/markdown/YAML linting | repo root |

## Migrating Existing Repos

To migrate from copy-pasted workflows to shared reusable ones:

1. Replace each local workflow file with the corresponding thin caller (see examples above)
2. Remove any duplicate logic now handled by the reusable workflow
3. Test by opening a PR and verifying workflows trigger correctly

## Sync Workflow

The `sync-caller-workflows.yml` checks which consuming repos still use local copies vs. shared reusable workflows. It runs when reusable workflows change and generates an adoption report in the workflow summary.
