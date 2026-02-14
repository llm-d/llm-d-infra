# llm-d Repo Template

This directory contains the canonical repo template for all llm-d organization repositories. It codifies best practices gathered from across the org into a single, consistent starting point.

## Using This Template

### For New Repos

1. Copy the entire `repo-template/` directory into your new repository:
   ```bash
   cp -r templates/repo-template/* templates/repo-template/.* /path/to/new-repo/
   ```

2. Find and replace all `{{PROJECT_NAME}}` placeholders with your project name:
   ```bash
   cd /path/to/new-repo
   grep -r '{{PROJECT_NAME}}' --include='*.md' --include='*.yml' --include='*.yaml' --include='Makefile' --include='Dockerfile' --include='go.mod' -l | \
     xargs sed -i '' 's/{{PROJECT_NAME}}/my-project/g'
   ```

3. Update these files with your project's specifics:
   - `OWNERS` — Add your team's GitHub usernames
   - `.github/CODEOWNERS` — Add your team
   - `README.md` — Fill in the TODO sections
   - `go.mod` — Run `go mod tidy` after adding dependencies
   - `.github/ISSUE_TEMPLATE/feature_request.yml` — Update the repo link

4. Remove this file (`TEMPLATE_README.md`) from your repo.

5. Install pre-commit hooks:
   ```bash
   pre-commit install
   ```

### For Existing Repos

Compare your repo against this template and adopt what's missing:

```bash
# See what files you're missing
diff -rq templates/repo-template/ /path/to/your-repo/ --exclude='.git' --exclude='node_modules' --exclude='vendor'
```

Priority adoption order:
1. **Governance** (if missing): `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `PR_SIGNOFF.md`
2. **Linting** (if outdated): `.golangci.yml`, `.pre-commit-config.yaml`, `.hadolint.yaml`, `_typos.toml`
3. **CI workflows** (if missing): Start with `ci-signed-commits.yaml`, `check-typos.yaml`, then `ci-pr-checks.yaml`
4. **Prow integration**: `prow-github.yml`, `prow-pr-automerge.yml`, `prow-pr-remove-lgtm.yml`
5. **Release pipeline**: `ci-release.yaml` + `.github/actions/`

## What's Included

### Governance
| File | Purpose |
|------|---------|
| `LICENSE` | Apache 2.0 |
| `CONTRIBUTING.md` | Development guidelines, lazy consensus model, testing tiers |
| `CODE_OF_CONDUCT.md` | Contributor Covenant v1.4 |
| `SECURITY.md` | Vulnerability disclosure process |
| `PR_SIGNOFF.md` | DCO sign-off and GPG/SSH signing instructions |
| `OWNERS` | Kubernetes-style reviewers/approvers |
| `.github/CODEOWNERS` | GitHub code ownership |

### Tooling & Linting
| File | Purpose |
|------|---------|
| `.pre-commit-config.yaml` | Pre-commit hooks: shellcheck, hadolint, markdownlint, yamllint |
| `.golangci.yml` | Go linter config (40+ linters, golangci-lint v2) |
| `.hadolint.yaml` | Dockerfile linting rules |
| `.yamllint.yml` | YAML lint (K8s-safe: 250 char lines, no doc-start requirement) |
| `_typos.toml` | Spell checker false-positive exceptions |
| `pyproject.toml` | Python: ruff linter + formatter config |
| `.prowlabels.yaml` | Prow label definitions |

### CI Workflows
| File | Purpose |
|------|---------|
| `ci-pr-checks.yaml` | PR validation: Go lint/test/build, Python lint, container build |
| `ci-release.yaml` | Tag-triggered: multi-arch build, push to ghcr.io, Trivy scan |
| `ci-signed-commits.yaml` | DCO enforcement (calls llm-d-infra reusable workflow) |
| `check-typos.yaml` | Spell checking (calls llm-d-infra reusable workflow) |
| `md-link-check.yml` | Markdown link validation |
| `stale.yaml` / `unstale.yaml` | Issue/PR staleness management |
| `prow-github.yml` | Prow commands (`/lgtm`, `/approve`, `/hold`) |
| `prow-pr-automerge.yml` | Auto-merge when Prow labels are set |
| `prow-pr-remove-lgtm.yml` | Remove lgtm on new pushes |
| `non-main-gatekeeper.yml` | Prevent PRs to non-main branches |

### Build
| File | Purpose |
|------|---------|
| `Makefile` | Standard targets: help, build, test, lint, fmt, image-build, image-push |
| `Dockerfile` | Multi-stage, distroless, non-root, multi-arch ready |
| `go.mod` | Go 1.24+ module template |
| `.github/dependabot.yml` | Automated dependency updates (Go, Actions, Docker) |

### GitHub
| File | Purpose |
|------|---------|
| `.github/PULL_REQUEST_TEMPLATE.md` | Standardized PR checklist |
| `.github/ISSUE_TEMPLATE/bug_report.yml` | Bug report form |
| `.github/ISSUE_TEMPLATE/feature_request.yml` | Feature request form |
| `.github/ISSUE_TEMPLATE/config.yml` | Disable blank issues, link to discussions |
| `.github/actions/docker-build-and-push/` | Reusable Docker buildx composite action |
| `.github/actions/trivy-scan/` | Reusable Trivy security scan composite action |

## Sources

Best practices were sourced from across the llm-d org:

- **llm-d/llm-d** — Governance docs (CONTRIBUTING, CODE_OF_CONDUCT, SECURITY, PR_SIGNOFF)
- **llm-d/kv-cache** — Go linter config (most comprehensive), Python/ruff config
- **llm-d/llm-d-workload-variant-autoscaler** — CI patterns (PR checks, release pipeline)
- **llm-d/llm-d-inference-sim** — Docker build + Trivy scan composite actions
- **llm-d/llm-d-infra** — Reusable workflows, pre-commit config, dependabot config
