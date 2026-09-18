---
name: nightly
description: Analyze nightly E2E job failures across llm-d repos. Smart router to sub-skills based on failure type.
---

# Nightly E2E Failure Analysis

Analyze and triage nightly E2E job failures across the llm-d org. This is the entry point — it
routes to the appropriate sub-skill based on what happened.

**The sub-skills are files to Read, not skills to invoke.** Skill discovery scans
`.claude/skills/*/SKILL.md`, one level deep. Every sub-skill here sits a level below that, at
`.claude/skills/nightly/<name>/SKILL.md`, so none of them is registered and the Skill tool
cannot resolve `nightly:report` or any of its siblings — the `name: nightly:<x>` in their
frontmatter declares an identity the loader never reads. Open them with Read, by path. Each
reference below gives the path for that reason.

## Setup

**CI logs and kubectl output can be hundreds of lines.** Everything below writes to files under
`$LOG_DIR` and hands them to `Agent(subagent_type='Explore')` rather than pulling them into
context. The shell and jq live in `nightly/scripts/`, shared with `nightly/report/SKILL.md`;
`nightly/scripts/README.md` is the index.

```bash
# Date-scoped. $LOG_DIR is named after run and job ids, so nothing in it is ever overwritten —
# it accumulates, and a previous day's bodies silently padded one pass with 60 files for 26
# lanes. A fresh directory each day removes that class of error at the root.
export LOG_DIR=/tmp/llm-d/nightly/$(date -u +%F)
export NS="$(git rev-parse --show-toplevel)/.claude/skills/nightly/scripts"
mkdir -p "$LOG_DIR"
[ -d "$NS" ] || echo "!! set NS to the scripts directory next to this file"
```

Do not reach for `gh run view --log`. It renders **every** step as the literal string
`UNKNOWN STEP`, and the env block ahead of each step is re-echoed in full, so a bare
`grep -i error` returns mostly `LLMDBENCH_*` assignments and the runner's echo of the script's
own `::error::` branches. `sh $NS/errtext.sh <repo> <run>` windows the job log on the failing
step's timestamps from the jobs API instead. Step 4b calls it.

### The session shell is zsh

Every block below is POSIX sh and runs under zsh unchanged, but two zsh-only parses will bite
anything you add:

- **`$var[` is a subscript.** zsh reads `"$cand[.]y"` as an array subscript on `cand` and
  raises `bad floating point constant`. Brace it: `"${cand}[.]y"`. Bare `$var` elsewhere is
  fine — it is specifically a `[` directly after the name.
- **`$var` does not word-split.** `set -- $pair` leaves `$1` holding the whole line, so any
  loop built on it silently processes one field. Use `while IFS=... read` instead.

Both fail *quietly* inside `$(...)` or ahead of a `|| continue`, producing a plausible empty
result rather than an error you would notice. When a block returns nothing and you cannot see
why, re-run it as `sh <<'EOS' … EOS` before believing the output. Anything under `$NS` is
already immune: those run under `sh`, which is why the loops that used to sit inline here were
moved there.

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
[1] Gather scheduled runs + workflow registry (all repos)
  |
  v
[2] Any lane registered but not running? ──> propose successors, then report real gaps
  |
  v
[3] Any failures? ───No──> Report "All green" + exit
  |
  Yes
  v
[4] Attribute each failure to its failed step
  |
  v
[4b] Pull the actual error text for each  (report/SKILL.md Phase 3a)
  |
  v
[4c] Is each failure new or chronic?      (report/SKILL.md Phase 3b)
  |
  v
[5] Classify, using the error text — not the step name alone:
  |
  ├── Infra failure (auth, gcloud, AWS creds, runner) ──> nightly/infra/SKILL.md
  ├── GPU contention (insufficient GPUs)               ──> nightly/gpu/SKILL.md
  ├── Deploy failure (helmfile, helm, install.sh)       ──> nightly/deploy/SKILL.md
  ├── Pod readiness timeout                             ──> nightly/pods/SKILL.md
  ├── Test failure (e2e-validate, make test-e2e)        ──> nightly/test/SKILL.md
  └── Unknown                                           ──> nightly/rca/SKILL.md
  |
  v
[6] Report, grouped by shared cause rather than by lane
```

Steps 4b and 4c are not optional polish. Without 4b you are classifying on a step name, and
`Standup` and `Run` each cover several unrelated causes. Without 4c you cannot tell last
night's breakage from a lane that has been red for a month, which is usually the first thing
the reader needs to know.

## Step 1: Gather Status

Use the REST runs endpoint with `--paginate` rather than `gh run list --limit N`. Both stop at
1000 results and exit 0 without warning, and runs come back newest-first, so what you lose is
the *oldest* days. `llm-d/llm-d` alone exceeds the cap inside a week; the 1-day window this
skill uses stays well under it. For anything longer, use `sh $NS/fetch-window.sh`, which fetches
one day per query and checks each day's count against the server's `total_count`
(`.claude/skills/nightly/report/SKILL.md` Phase 0 explains it).

`event=schedule` and `created` are applied server-side. Filter lanes on `.path`. The
`consolidate-status-*` workflows are named `Past Status - … E2E (…)`, so a name regex of
`[Nn]ightly|[Ee]2[Ee]` matches them and roughly doubles the apparent fleet.

```bash
# `created>=<a bare date>` spans two nights (all of yesterday's runs plus today's), so
# every daily lane appears twice and the failure list doubles. A rolling 24-hour
# timestamp catches each lane's latest scheduled run once.
export SINCE=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
               || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)

# Bookkeeping and housekeeping crons. Everything else scheduled is treated as a lane,
# so newly added nightlies show up without editing this list.
export EXCLUDE_RE='prow-pr-automerge|stale[.]yaml|consolidate-status-|slash-test-nightly-cleanup'

for repo in llm-d/llm-d llm-d/llm-d-infra; do
  slug=${repo##*/}
  # NOTE: --slurp cannot be combined with --jq; pipe to a separate jq.
  unset GITHUB_TOKEN && gh api \
    "repos/$repo/actions/runs?event=schedule&created=%3E%3D$SINCE&per_page=100" \
    --paginate --slurp \
    | jq --arg ex "$EXCLUDE_RE" '[.[].workflow_runs[]
        | select(.path | test($ex) | not)
        | {id, name, path, workflow_id, event, conclusion, status, run_started_at, html_url}]' \
    > "$LOG_DIR/$slug-runs.json"

  # Registry of every workflow the repo has, including ones producing no runs.
  # created_at is carried for the TOO NEW guard in Step 2: a lane added hours ago has not
  # reached its first cron yet and must not be reported as one that never ran.
  unset GITHUB_TOKEN && gh api "repos/$repo/actions/workflows?per_page=100" --paginate --slurp \
    | jq '[.[].workflows[] | {id, name, path, state, created: (.created_at | split("T")[0])}]' \
    > "$LOG_DIR/$slug-workflows.json"

  # Workflow files present on the default branch, to tell "deleted" from "not firing".
  unset GITHUB_TOKEN && gh api "repos/$repo/contents/.github/workflows?per_page=100" \
    --paginate --slurp | jq '[.[][] | .path]' > "$LOG_DIR/$slug-files.json"

  echo "$slug: $(jq length $LOG_DIR/$slug-runs.json) scheduled runs since $SINCE"
done
```

## Step 2: Coverage Gaps

A lane that stops running is invisible to any check that starts from a list of runs. It reads
as "not failing" while testing nothing. `gaps.sh` anti-joins the registry against the runs to
find them, then puts a verdict on each: it needs `$EXCLUDE_RE` and the three JSON files Step 1
wrote.

```bash
for repo in llm-d/llm-d llm-d/llm-d-infra; do
  sh $NS/gaps.sh "$repo"
  echo "== ${repo##*/}"; column -t -s$'\t' "$LOG_DIR/${repo##*/}-gap-report.tsv"
done
```

Most zero-run workflows are ordinary PR or push workflows, so the script keeps only the ones
that are actually scheduled — checking the file on the default branch for a `schedule:` key
when the API reports no scheduled run. That check is required, not optional: the
`reusable-nightly-e2e-*.yaml` workflows in this repo are `workflow_call:`-only and never
produce runs of their own, so without it every one of them is reported as a missing nightly.

Each verdict has a different fix. `STALE` and `NEVER RAN` mean checking the trigger — note that
scheduled workflows only fire from the default branch. `DISABLED` is often GitHub's inactivity
auto-off rather than anyone's decision. `TOO NEW` is not a gap; it is a lane waiting for its
first cron, and it resolves itself. `LOOKUP FAILED` is not a verdict about the lane — the
last-scheduled-run call did not return, so nothing is known. Re-run those rows; do not let them
stand as gaps.

### Renames are the common case — check for a successor before reporting a gap

`REMOVED` almost always means renamed, not deleted. The anti-join above cannot see that: the
old path stops appearing in runs, the new path is a different row that is running fine, and
nothing links them. Reported raw, a single naming migration reads as a fleet of lost lanes.

`successor.awk` matches on token overlap rather than a prefix. Lanes moved to the `-acc-`
convention both gained and dropped tokens — `wide-ep-lws-gke` became
`wide-ep-lws-gke-acc-gpu-vllm-x`, but `tiered-prefix-cache-cpu-offloading-gke` became
`tiered-prefix-cache-gke-cpu-gpu-vllm-native`, which shares no usable prefix.

Candidates come from `$slug-files.json` filtered by `$EXCLUDE_RE`. Unfiltered, the
`consolidate-status-<lane>` bookkeeping workflows shadow every real lane: they carry the whole
lane name plus two tokens, so they win the overlap and every row proposes a successor that
tests nothing.

```bash
for repo in llm-d/llm-d llm-d/llm-d-infra; do
  slug=${repo##*/}
  [ -s "$LOG_DIR/$slug-gap-report.tsv" ] || continue
  jq -r --arg ex "$EXCLUDE_RE" '.[] | select(test($ex) | not)
    | split("/") | last | sub("[.]ya?ml$";"")' "$LOG_DIR/$slug-files.json" \
    > "$LOG_DIR/$slug-current.txt"
  jq -r '[.[].path] | unique[]' "$LOG_DIR/$slug-runs.json" > "$LOG_DIR/$slug-ranpaths.txt"
  echo "== $slug"
  awk -f $NS/successor.awk -v cur="$LOG_DIR/$slug-current.txt" \
      -v ran="$LOG_DIR/$slug-ranpaths.txt" "$LOG_DIR/$slug-gap-report.tsv" \
    | column -t -s$'\t'
done
```

Two candidates, not one, because the top score is often a tie and the tie-break is arbitrary.
Token overlap is blind to platform synonyms in particular: `…-cpu-offloading-ocp` scores equally
against the `gke` and the `ibm` lane, and `ibm-` is the OpenShift-GPU prefix, so the right answer
is the one the score cannot distinguish. Read both rows.

This proposes, it does not conclude. Confirm the candidate covers the same guide *and* the same
platform; `ran` only means it fired in the window. A lane whose successor is confirmed is not a
coverage gap and belongs out of the gap table entirely. `NO CANDIDATE` is the row that deserves
attention.

## Step 3: Identify Failures

Carry the repo on each row. Failures come from more than one repo, and a run ID looked up
against the wrong repo returns 404 rather than an error you would notice.

```bash
for f in $LOG_DIR/*-runs.json; do
  jq -r '.[] | select(.conclusion == "failure" or .conclusion == "startup_failure"
                      or .conclusion == "timed_out")
    | [(.html_url | capture("github.com/(?<r>[^/]+/[^/]+)/actions") | .r),
       .id, .conclusion, (.run_started_at | split("T")[0]), .name,
       # Column 6 is the workflow filename, carried so Step 4c does not have to look it up
       # again. Keep the extension: .yaml, .yml and .lock.yml all occur, and the workflows
       # API needs the real basename.
       (.path | sub("^\\.github/workflows/";""))] | @tsv' "$f"
done | sort > $LOG_DIR/failures.tsv
wc -l < $LOG_DIR/failures.tsv
```

`cancelled` and `skipped` are absent by design — they record no verdict either way, so
counting them as failures overstates the damage.

If `failures.tsv` is empty and Step 2 found no gaps, report all green and stop.

## Step 4: Attribute Each Failure to Its Failed Step

`failed-steps.sh` attributes in parallel rather than one `gh run view` at a time, and caches
each run's jobs response under `$LOG_DIR` so Step 4b does not fetch it again.

```bash
cut -f1,2 $LOG_DIR/failures.tsv | sh $NS/failed-steps.sh > $LOG_DIR/failed-steps.tsv

join -t$'\t' <(cut -f2,5 $LOG_DIR/failures.tsv | sort) <(sort $LOG_DIR/failed-steps.tsv) \
  | cut -f2,3 | sort -u | column -t -s$'\t'
```

## Step 4b: Pull the Actual Error Text

A step name says where a run stopped, not why. `Standup` and `Run` each name a whole phase of
the reusable workflow rather than one action, so several unrelated causes land under each — a
single night has put pod-readiness timeouts, GPU starvation, a bad kustomize path and a
CrashLoopBackOff all under `Standup`. Classifying before this step groups them wrongly.

`pull.sh` runs `errtext.sh` over the failures. Read Phase 3a of
`.claude/skills/nightly/report/SKILL.md` before changing either — it explains why
`--allow-escape-sequences`, the `substr($1,1,19)` window and the `##[endgroup]` skip each
matter, and each one silently returns the wrong thing if dropped.

Only the newest failure per lane matters. The 24-hour window in Step 1 normally yields one
failure per lane, but reruns repeat lanes, and a date-only window doubles the list: a bare
`created>=<yesterday>` once returned 52 failures across 34 lanes, at one log download per
extra row. Collapse first; when the rows are already unique this is a no-op:

```bash
# newest failure per lane name (field 5), keeping repo and run id
sort -t$'\t' -k5,5 -k4,4r $LOG_DIR/failures.tsv \
  | awk -F'\t' '!seen[$5]++' | sort -t$'\t' -k5,5 > $LOG_DIR/failures-latest.tsv
```

```bash
sh $NS/pull.sh $LOG_DIR/failures-latest.tsv
```

That writes one `err-<run>.txt` per row, six at a time, and concatenates them into
`$LOG_DIR/errtext.out`. `xargs` cannot drive it — lane names contain spaces, so `-n` splits
mid-name and the run IDs pair with the wrong repos.

It also reports how many bodies named no cause in the step window. Expect roughly a quarter:
`Standup` emits its own `::group::`, which truncates the window on the env dump. Those rows are
already handled — `errtext.sh` escalates to `errsig.sh` itself and marks the body
`## NO CAUSE IN WINDOW`, so there is no second pass to run. `##[error]` is deliberately absent
from the signature that decides this. 25 of 34 bodies carry `##[error]Process completed with
exit code 1.` — it marks the failure without naming it, so including it would pass every
truncated body as explained.

Read each body in full rather than tailing it. A correct window is under ten lines and the
cause is as often on the first as the last; a `tail -6` scan reported an already-solved lane
(`cat: /opt/gh-aw/prompts/xpia.md: No such file or directory`) as unexplained.

At a dozen red lanes `errtext.out` is small enough to Read directly. Past roughly 15 lanes it
stops fitting (34 bodies came to ~60KB with the tickers already stripped), so hand the file to
`Agent(subagent_type='Explore')` instead of pulling it into context. Ask for one line per
`##########` section in the form `lane | run id | cause`, quoting the decisive error line
verbatim or `NO CAUSE IN WINDOW`, followed by clusters of sections sharing one error
signature. Tell the agent to read each body in full rather than tailing it, to skip
`Teardown command failed` lines, and to treat `##[error]Process completed with exit code 1.`
as naming nothing. Step 5 classifies on the verbatim quotes; 4c and the report key on the run
ids.

Two lanes stopped at the same step are the same problem only if the error text agrees.
Conversely, identical text across unrelated platforms is the strongest signal available that
the fault is in shared code rather than in any one cluster — say so in the report.

Note also what is *not* the cause: teardown runs after the failure and logs its own errors,
each prefixed `Teardown command failed (continuing)`. Those are noise.

## Step 4c: New or Chronic?

A lane that failed last night and a lane that has failed for three weeks need different
responses, and the run list cannot tell them apart. `lifetime.sh` — the same script Phase 3b of
`.claude/skills/nightly/report/SKILL.md` runs — answers it per lane:

```bash
# lifetime.sh wants repo, workflow file, lane — in that order. `cut` emits fields in file
# order regardless of how -f is written, and failures.tsv holds the lane name in field 5 and
# the file in field 6, so awk does the reorder. The file comes straight from Step 3 rather
# than being looked up per lane against *-runs.json, which cost a jq fan-out per row and
# resolved by display name, silently picking one when two lanes share a name.
awk -F'\t' -v OFS='\t' '{print $1, $6, $5}' $LOG_DIR/failures.tsv | sort -u \
  | sh $NS/lifetime.sh | column -t -s$'\t'
```

Output is `streak | last green | decisive runs | first run | lane`, worst first. Only decisive
runs count toward the streak, matching `lanes.jq`: counting `cancelled` as a failure inflates a
mostly-cancelled lane into the oldest breakage in the fleet, and the run count in column 3 is
then a count of nothing.

The streak counts consecutive failures back from the newest run; a lane green at the top yields
0. The second column is when it was last green, which is what makes the number readable — "44,
last green 2026-06-29" and "7, last green 2026-08-05" are different problems even though both
read as "chronic".

`NEVER PASSED` in that column means no success anywhere in the lane's history. Column 4 is what
tells you whether that matters: a lane whose first run is two days ago has one decisive failure
and reaches `NEVER PASSED` while saying nothing, whereas `64 runs since 2026-06-11, NEVER
PASSED` is a lane that was merged broken and needs its author rather than a tracking issue.

When several lanes broke on the same day, they are probably one incident. Phase 4 of
`report/SKILL.md` clusters lanes by streak start; use it rather than eyeballing dates.

## Step 5: Classify

Use the error text from 4b, not the step name alone.

| Failed Step Pattern | Category | Sub-skill (Read by path) |
|---|---|---|
| `Authenticate to Google Cloud`, `Set up gcloud`, `Configure AWS Credentials` | Infra auth | `nightly/infra/SKILL.md` |
| `Set up runner`, `Set up job` (startup_failure) | Runner issue | `nightly/infra/SKILL.md` |
| `Check GPU availability`, `Request TPUs (DWS)` | Accelerator contention | `nightly/gpu/SKILL.md` |
| `Deploy guide via helmfile`, `Deploy guide via custom script`, `Deploy infrastructure`, `Standup` | Deploy failure | `nightly/deploy/SKILL.md` |
| `Wait for pods to be ready`, `Wait for infrastructure` | Pod timeout | `nightly/pods/SKILL.md` |
| `Run E2E validation`, `Run E2E tests`, `Run WVA E2E tests` | Test failure | `nightly/test/SKILL.md` |
| Anything else | Unknown | `nightly/rca/SKILL.md` |

Paths are relative to `.claude/skills/`. These are files, not invocable skills — see the note
at the top. Six of the seven have not been edited since 2026-03-06 and predate the `-acc-` lane
naming, the TPU DWS step and the XPU lanes; treat their specifics as unverified.

A `startup_failure` with zero jobs means the run never began, so it is neither infra nor a test
failure. Check whether the workflow file still exists on the default branch and whether it
parses. A rename in flight produces the same symptom until the old registration ages out.

## Step 6: Report

Lead with the clusters, not the lane list. A reader who sees nineteen rows learns less than one
who sees "four problems, one of them ours". Group by the shared error text from 4b, order by
how many lanes each accounts for, and say for each whether it is new.

```markdown
## Nightly Status — YYYY-MM-DD

19 of 44 scheduled runs failed. Four distinct causes; nothing broke last night.

### 1. Benchmark harness never completes (4 lanes, last green 2026-08-05)
`Pods did not complete within 1200s (phases=['Running'])` — identical on OCP, CKS, AMD ROCM
and GKE GPU, so the fault is in the shared harness, not any one cluster.

| Workflow | Platform | Status | Failed step | Streak | Last green | Category |
|----------|----------|--------|-------------|--------|------------|----------|
| Optimized Baseline | OCP GPU | FAIL | Run | 7 | 2026-08-05 | deploy |
| Optimized Baseline | GKE GPU | FAIL | Run | 7 | 2026-08-05 | deploy |

### 2. Flow Control has never passed (1 lane, 63 runs, 0 green)
Empty kustomize path segments (`gpu/vllm///gke`). Not a regression — the lane has been red
since it was added.

### Coverage Gaps

| Lane | Verdict | Last scheduled run | Likely successor | Action |
|------|---------|--------------------|------------------|--------|
| nightly-e2e-sim-cks.yaml | REMOVED | 2026-07-02 | `…-cks-acc-cpu-sim-x` (3/4) | confirm, then drop the row |
| nightly-e2e-foo-gke.yaml | STALE | 2026-06-08 | NO CANDIDATE | check the cron and the default branch |
```

Report `TOO NEW` lanes, if any, as a footnote rather than a table row — they are not gaps.
A gap table where every row resolves to a confirmed successor should be reported as "no
coverage gaps", with the renames named in one line. Reporting a rename as a gap costs the
reader more than saying nothing.

Then Read the appropriate sub-skill file for each cluster.

## Repos to Monitor

| Repo | Scheduled workflows |
|------|---------------------|
| `llm-d/llm-d` | ~40 `nightly-e2e-*` lanes plus `nightly-build-image` |
| `llm-d/llm-d-infra` | `nightly-org-checks`, `reusable-ci-nightly-benchmark`, `upstream-monitor.lock` |

`llm-d/llm-d-workload-variant-autoscaler` has no scheduled E2E of its own. Its nightlies run
in `llm-d/llm-d` as `nightly-e2e-workload-autoscaling-*`.

## Reusable Workflows (in this repo)

| Workflow | Platform |
|----------|----------|
| `reusable-nightly-e2e-openshift.yaml` | OpenShift |
| `reusable-nightly-e2e-gke.yaml` | GKE |
| `reusable-nightly-e2e-gke-tpu.yaml` | GKE TPU |
| `reusable-nightly-e2e-cks.yaml` | CKS (CoreWeave) |
| `reusable-nightly-e2e-xpu.yaml` | Intel XPU |
| `reusable-ci-nightly-benchmark.yaml` | Benchmark harness |

The five `reusable-nightly-e2e-*.yaml` workflows are `workflow_call:`-only — their runs appear
under the calling workflow in `llm-d/llm-d`, never under this repo.
`reusable-ci-nightly-benchmark.yaml` also carries a `schedule:` trigger (`- cron: '0 0 * * *'`)
alongside `workflow_call:`, so it runs in its own right here and is listed as one of this repo's
scheduled lanes above. Look for its failures under `llm-d/llm-d-infra`.

## Schedule Matrix

Derive it rather than reading a checked-in copy, which goes stale as lanes are added and
retired:

```bash
unset GITHUB_TOKEN && gh api "repos/llm-d/llm-d/actions/workflows?per_page=100" --paginate --slurp \
  | jq -r '.[].workflows[] | select(.path | test("nightly-")) | .path' \
  | xargs -P 8 -n 1 sh -c '
      cron=$(unset GITHUB_TOKEN; gh api "repos/llm-d/llm-d/contents/$0" \
        -H "Accept: application/vnd.github.raw" 2>/dev/null \
        | grep -E "^[[:space:]]*-[[:space:]]*cron:" | head -1 \
        | tr -d "\047\"" \
        | sed -E "s/^[[:space:]]*-[[:space:]]*cron:[[:space:]]*//; s/[[:space:]]*#.*$//")
      [ -n "$cron" ] && printf "%s\t%s\n" "$cron" "${0##*/}"' \
  | sort -k2,2n -k1,1n | column -t -s$'\t'   # minute hour dom mon dow, ordered by hour
```

## Related Files

Read these by path. None is a registered skill — the Skill tool cannot resolve any of them, for
the reason given at the top of this file. Paths are relative to `.claude/skills/`.

| Path | Covers |
|------|--------|
| `nightly/scripts/` | The shell and jq every step above runs; `README.md` there is the index |
| `nightly/report/SKILL.md` | Multi-day windows, `errtext.sh`, streak history, incident clustering, week-over-week |
| `nightly/infra/SKILL.md` | Infrastructure/auth failures |
| `nightly/gpu/SKILL.md` | Accelerator contention |
| `nightly/deploy/SKILL.md` | helmfile/helm/kustomize failures |
| `nightly/pods/SKILL.md` | Pod readiness timeouts |
| `nightly/test/SKILL.md` | E2E test failures |
| `nightly/rca/SKILL.md` | Full root cause analysis |

`nightly/report/SKILL.md` is the one to reach for by default: this file is the daily pass, and
anything needing more than a one-day window, real error text, or history belongs there. The
other six were last touched 2026-03-06 and have not been checked against the current lane
naming or the TPU and XPU platforms.
