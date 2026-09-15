---
name: nightly:report
description: Generate weekly nightly E2E trend report with failure patterns and success rates
---

# Nightly Weekly Trend Report

Generate a comprehensive weekly report of nightly E2E job health across all platforms and guides.

## Setup (MANDATORY)

Every phase writes its bulk output to `$LOG_DIR` rather than into context, and runs the shell
and jq in `nightly/scripts/` — shared with the parent `nightly/SKILL.md`, indexed by
`nightly/scripts/README.md`.

```bash
# Date-scoped. Every file in $LOG_DIR is named after a run, job or repo, so nothing in it is
# ever overwritten — it accumulates, and a previous pass's bodies silently padded one report
# with lanes that had not failed. A fresh directory each day removes that at the root.
export LOG_DIR=/tmp/llm-d/nightly/$(date -u +%F)
export NS="$(git rev-parse --show-toplevel)/.claude/skills/nightly/scripts"
mkdir -p "$LOG_DIR"
[ -d "$NS" ] || echo "!! set NS to the scripts directory beside nightly/SKILL.md"
```

## When to Use

- Weekly review of nightly health
- User says "nightly report", "weekly summary", "how are nightlies doing"
- Before a release to verify stability

## Phase 0: Gather All Data

The run list alone is not enough. Collect all of:

1. **Scheduled runs over the window**, fetched one day per query. `gh run list --limit N` and the
   REST runs endpoint both stop at 1000 results and exit 0 without warning. Runs come back
   newest-first, so an oversized window silently loses its oldest days and every rate below is
   computed on a partial week — `llm-d/llm-d` alone exceeds the cap inside a week, while one day
   stays well under it. Each day is checked against the server's own `total_count`, so a day
   that ever does overflow raises instead of returning short.
2. **The workflow registry**, so lanes that produced no runs stay visible.
3. **Workflow files on the default branch**, to tell a deleted lane from a stalled one.

Filter lanes on `.path`. The `consolidate-status-*` workflows are named
`Past Status - … E2E (…)`, so a `[Nn]ightly|[Ee]2[Ee]` name regex matches them and nearly
doubles the apparent fleet.

`fetch-window.sh` does the day-by-day fetch. Phase 6 calls it again for the previous week.

```bash
export DAYS=7
export EXCLUDE_RE='prow-pr-automerge|stale[.]yaml|consolidate-status-|slash-test-nightly-cleanup'

for repo in llm-d/llm-d llm-d/llm-d-infra; do
  slug=${repo##*/}
  sh $NS/fetch-window.sh "$repo" $((DAYS-1)) 0 "$LOG_DIR/$slug-runs.json"

  # created_at is carried for the TOO NEW guard in Phase 2: a lane registered hours ago has
  # not reached its first cron and must not be reported as one that never ran.
  unset GITHUB_TOKEN && gh api "repos/$repo/actions/workflows?per_page=100" --paginate --slurp \
    | jq '[.[].workflows[] | {id, name, path, state, created: (.created_at | split("T")[0])}]' \
    > "$LOG_DIR/$slug-workflows.json"

  unset GITHUB_TOKEN && gh api "repos/$repo/contents/.github/workflows?per_page=100" \
    --paginate --slurp | jq '[.[][] | .path]' > "$LOG_DIR/$slug-files.json"
done
```

`fetch-window.sh` compares each day's returned count against the `total_count` the server puts
on every page, and raises rather than returning short. Checking per day catches truncation
while it is still partial; an assertion on the window's start date would only fire once a
*whole* day had already vanished.

The remaining check is coverage. A gap in the dates means a day returned nothing at all:

```bash
for slug in llm-d llm-d-infra; do
  jq -r --arg slug "$slug" --argjson days "$DAYS" '
    if length == 0 then "\($slug): 0 runs  !! empty — check the event filter and $DAYS"
    else ([.[].run_started_at[0:10]] | unique) as $d
    | "\($slug): \(length) runs, \([.[].path] | unique | length) lanes, "
      + "\($d[0]) -> \($d[-1]), \($d | length)/\($days) days"
      + (if ([.[].event] | unique) != ["schedule"] then "  !! non-schedule events present"
         else "" end)
      + (if ($d | length) < $days
         then "  !! a day produced no scheduled run at all" else "" end)
    end' "$LOG_DIR/$slug-runs.json"
done
```

Expect `7/7` for `llm-d`. A repo with weekly crons can legitimately report fewer.

## Phase 1: Classify Each Lane

Pass rate alone cannot separate "broke last night" from "passed early in the week and has
been dead since". Both read 3/7. Compute the trailing failure streak alongside the rate and
classify on both.

For the denominator, exclude `cancelled` and `skipped`. They record no verdict, and counting
them as failures reports a clean lane as 87%. Sort by `run_started_at` before taking a streak.

A run still in flight has `conclusion: null`. The window always ends at "now", so this is the
common case and every lookup that touches `.conclusion` needs a guard. `{...}[null]` raises
`Cannot index object with null` *before* a `// "?"` fallback can apply, so the fallback that
looks like it handles this does not. `decisive` below is already safe because `IN()` returns
`false` on null.

```bash
for slug in llm-d llm-d-infra; do
  jq -f $NS/lanes.jq "$LOG_DIR/$slug-runs.json" > "$LOG_DIR/$slug-lanes.json"
done
# Both repos, and HEALTHY lanes as a count rather than a row each: on llm-d that is ~80 lanes
# of which the majority are green, and no later phase reads a green row. The full table stays
# in $slug-lanes.json if you need it.
for slug in llm-d llm-d-infra; do
  jq -r --arg s "$slug" '(map(select(.status == "HEALTHY")) | length) as $ok
    | "\($s): \($ok) healthy of \(length) lanes",
      (.[] | select(.status != "HEALTHY")
       | "\(.status)\t\(.passes)/\(.decisive)\t\(.seq)\t\(.lane)")' \
    "$LOG_DIR/$slug-lanes.json"
done | column -t -s$'\t'
```

`seq` is oldest to newest: `P` pass, `F` fail, `T` timeout, `X` startup failure,
`-` cancelled, `s` skipped, `?` still running.

| Status | Meaning | What it asks for |
|---|---|---|
| NEW BREAK | passing until the last run or two | start here |
| DEGRADED | red now, unreliable before | check the current failure matches the older ones |
| CHRONIC | red for the whole window | an owner and a tracking issue; the lane validates nothing meanwhile |
| UNRELIABLE | green on the latest run, red most other nights | the green badge is hiding the rate |
| NO VERDICT | most runs cancelled or skipped | usually a workflow timeout or a concurrency group |
| FLAKY | mixed, currently green | judge on rate across the window |
| HEALTHY | no failures | — |

**Every phase below selects red lanes with `select(.red)`,** the field `lanes.jq` computes as
`$streak > 0 and $status != "NO VERDICT"`. It is a field rather than a predicate spelled out
per phase because each phase that spelled it out was one edit away from selecting on `.streak`
alone. A lane can be NO VERDICT and still carry a nonzero streak: seven cancellations with one
older failure among them classifies as NO VERDICT, and its trailing streak is 1. Selecting on
`.streak` pulls that lane into attribution, clustering and lifetime lookup, where its stale
failure is presented as the current one. Report NO VERDICT lanes on their own, against the
cancellation, and do not attribute a step to them.

The table cannot say either of the following. Say them in the report yourself:

- **How long the lane has been red.** The window is seven days, so a lane red for eight nights
  and one red for a hundred are both CHRONIC. Phase 3b resolves this.
- **Whether the lane can recover on its own.** A failure that leaves state behind, such as an
  undeleted namespace or an orphaned Job, makes the next run fail the same way, so the lane
  stays red however the underlying resource pressure changes. Call these out. They need a manual
  cleanup rather than a rerun.

## Phase 2: Coverage Gaps

A lane that stopped running never appears in a run list, so it reads as "not failing" while
testing nothing. Anti-join the registry against the runs, then keep only workflows that are
actually scheduled. Most zero-run workflows are ordinary PR workflows, and the
`reusable-nightly-e2e-*.yaml` workflows in `llm-d-infra` are `workflow_call:`-only and would
otherwise all be reported as missing nightlies.

```bash
for repo in llm-d/llm-d llm-d/llm-d-infra; do
  sh $NS/gaps.sh "$repo"
  echo "== ${repo##*/}"; column -t -s$'\t' "$LOG_DIR/${repo##*/}-gap-report.tsv"
done
```

Each verdict wants a different response. `REMOVED` needs confirmation that a replacement lane
covers the same ground — `successor.awk` proposes one, and the parent `nightly/SKILL.md` Step 2
shows the invocation. `STALE` means the file is on the default branch with a `schedule:` block
that has stopped firing, so check whether the cron was edited to something that no longer
matches, or whether the repo hit GitHub's 60-day inactivity auto-off. `DISABLED` is usually that
same auto-off rather than a decision anyone made. `TOO NEW` is not a gap at all: the lane was
registered within the last two days and has not reached its first cron. Report it as a footnote
if at all. `LOOKUP FAILED` says nothing about the lane either — the last-scheduled-run call did
not return. Re-run Phase 2 for those rows before publishing rather than letting them stand as
gaps.

`NEVER RAN` is the awkward one, because the filter above has already established the two things
you would check first. The workflow is registered and active, its file *is* on the default
branch, and that file *does* contain a `schedule:` key. Do not re-check those. What is still
open is whether the cron expression is syntactically valid but matches nothing reachable,
whether the file landed within the last cron interval and has not come round yet, and whether
the `schedule:` trigger sits under a `branches:`/`paths:` guard that never matches, which GitHub
accepts silently. If none of those explain it, report the lane as unexplained rather than
repeating the trigger advice.

When several gaps share one `last` date, suspect a single rename rather than several
independent losses, and check for successor lanes before writing one action item per row.

## Phase 3: Attribute the Current Failures

Only the latest failure per red lane matters for triage, so attribute those rather than every
failure in the window. That is one call per red lane instead of one per failure, an order of
magnitude fewer, and they parallelize.

Derive the repo per row from the run URL rather than hardcoding it. A run ID looked up against
the wrong repo returns 404 rather than an error you would notice.

`failed-steps.sh` caches each run's jobs response under `$LOG_DIR`, so Phase 3a reuses it rather
than fetching the same document again per lane.

```bash
for slug in llm-d llm-d-infra; do
  jq -r '.[] | select(.red)
    | [(.last_fail_url | capture("github.com/(?<r>[^/]+/[^/]+)/actions") | .r),
       (.last_fail_id | tostring)] | @tsv' "$LOG_DIR/$slug-lanes.json"
done | sh $NS/failed-steps.sh > $LOG_DIR/steps.tsv

# `reduce` over `inputs` starts from {} and never sees the trailing empty line, so an all-green
# week's empty steps.tsv yields {} with no guard needed.
jq -Rn 'reduce (inputs | split("\t")) as $x ({}; .[$x[0]] = $x[1])' \
  $LOG_DIR/steps.tsv > $LOG_DIR/steps.json
```

`steps.tsv` is keyed on run ID, which is not something a human triages against. Join it back to
the lane table before printing, since the lane name is already sitting next to `last_fail_id`:

```bash
for slug in llm-d llm-d-infra; do
  jq -r --slurpfile s $LOG_DIR/steps.json '$s[0] as $st
    | .[] | select(.red)
    | "\(.status)\t\(.passes)/\(.decisive)\t\($st[(.last_fail_id|tostring)] // "?")\t\(.lane)"' \
    "$LOG_DIR/$slug-lanes.json"
done | column -t -s$'\t'
```

### Getting the actual error text

A step name only says where a run stopped. Every later phase that asks you to confirm something
needs the real output of the failed step, and the two obvious routes do not provide it:

- `gh run view <id> --log` renders **every** step as the literal string `UNKNOWN STEP`, so the
  step name this phase just derived cannot be used to find anything in it.
- The run-level log zip (`actions/runs/<id>/logs`) contains one file per *job*, not per step.

What works is to window the job log on the failed step's timestamps, which the jobs API already
returns. That is `errtext.sh`:

```bash
sh $NS/errtext.sh llm-d/llm-d 30377187409
```

It takes the failing job and step from `jobmeta.sh`, downloads the job log via `joblog.sh`,
windows it, strips ANSI through `clean.sh`, and cuts the result to the step's own output. Each
of the following silently returns the wrong thing if dropped:

- **`--allow-escape-sequences` on the log fetch** (`joblog.sh`). Job logs carry ANSI colour, and
  without the flag `gh` refuses the body and exits 1 with nothing on stdout. Sending that stderr
  to `/dev/null` makes a download failure read as a step that produced no output, which is the
  worst available failure mode, so `joblog.sh` keeps and reports it.
- **`substr($1,1,19)` rather than bare `$1`.** Log lines carry sub-second precision while the
  API bounds are whole seconds, so a direct string compare excludes every line in the final
  second, which is the entire output of a step that fails in one second.
- **Skip past the first `##[endgroup]`.** Ahead of it sits the runner's echo of the *script
  source*. This is why `grep -i error` on a raw job log returns things like
  `echo "::error::Unsupported accelerator type"`, a line of the script's own error branch.
- **Stop at the next `##[group]`.** Otherwise the following step's preamble trails in. The
  cost: a step that emits `::group::` in its *own* output is truncated at its first group, which
  is what the escalation below exists for.
- **The ANSI class in `clean.sh` is `[a-zA-Z]`, not `[m]`.** Colour codes are `m`-terminated,
  but the smoketest ticker's erase-line sequence is `ESC[2K`, and a colour-only strip leaves a
  literal `[2K` on every ticker line for each consumer to filter out by name.

The `##[endgroup]` cut does most of the reduction — timestamp windowing alone still leaves
hundreds of lines; the group boundaries take it to under ten:

```
Error from server (AlreadyExists): namespaces "llm-d-nightly-<guide>-gke-tpu" already exists
job.batch/tpu-request-job unchanged        <- apply is a no-op, so no pod is created
error: no matching resources found         <- kubectl wait then finds no pods
```

### When the window names no cause — `errsig.sh`

The group filter is not an edge case on this fleet. On a recent pass it truncated 9 of 34 runs:
the `Standup` step emits its own `::group::` around the env dump, so the window ends on the env
block and the output tails out on `namespace/… configured` and `secret/llm-d-hf-token created`.
Both are normal setup lines, so the result reads like a step that failed without saying
anything.

`errtext.sh` detects this itself and escalates — there is no second pass to run by hand. Before
printing, it tests the body against the signature list below; if fewer than three substantive
lines survive, or nothing in them matches, it prints `## NO CAUSE IN WINDOW — whole-log
signature scan follows` and hands off to `errsig.sh`. The marker is what `pull.sh` counts to
report the escalation rate, and it is worth reading in the output: a body carrying it was found
by a net rather than by a window, so it is likelier to need a second look.

`##[error]` is deliberately absent from that signature list, though `errsig.sh` greps for it. 25
of 34 bodies carry `##[error]Process completed with exit code 1.` — it marks the failure without
naming it, so treating it as a cause would pass every truncated body as explained.

Read the *whole* windowed body, not its tail. When the window is correct it is usually under
ten lines, and the cause often sits on the first — `cat: /opt/gh-aw/prompts/xpia.md: No such
file or directory` opened the window on a lane that a `tail -6` scan reported as unexplained.
Reserve `tail` for the untruncated raw log.

Dropping the group filter does not rescue those. What follows the failure is the pipeline's
debug collection — node capacity listings, `kubectl describe`, `kubectl get events`, and a
second echo of the env — so the error is buried mid-log rather than at the tail.

What `errsig.sh` does instead is search the whole job log for the signatures the harness and
kubelet actually emit, and subtract the known sources of false positives. It shares
`jobmeta.sh`, `joblog.sh` and `clean.sh` with `errtext.sh`, so on the escalation path the jobs
response and the job log are both already on disk and no call is repeated.

Four filters. Dropping any of them buries the cause:

- **`::error::`, `::warning::`, `GITHUB_STEP_SUMMARY` and `LLMDBENCH_`** — the runner
  re-echoes the script source and the whole env block ahead of every step, so without these
  the output is the script's own error and warning branches and a wall of `LLMDBENCH_EXTRA_*`
  assignments. This is the same trap the parent skill warns about for `gh run view --log`.
  The `::warning::` and step-summary echoes quote the condition verbatim:
  `echo "**Insufficient GPUs** — need $REQUIRED_GPUS…" >> $GITHUB_STEP_SUMMARY` matches the
  `Insufficient` signature and reads like a scheduler event.
- **The progress ticker (`⏳`)** — the smoketest wait redraws its status line every ten
  seconds, and each redraw names every not-ready pod with states like `Unschedulable`, so one
  failing wait matches the signature list hundreds of times. The `ESC[2K` erase-line sequence
  that starts each redraw is already gone by this point — `clean.sh` strips it — but the hourglass
  is ordinary text and has to be filtered by name.
- **The `$noise` list** — teardown runs *after* the failure and logs its own errors, and the
  pipeline's debug collection reliably emits `jobs.batch "download-model" not found`,
  `pods "access-to-harness-data-workload-pvc" not found` and the tool-check table's
  `oc — (optional, not found)` whatever went wrong. Note the last one is *not* covered by the
  `Optional tool not found` term — that is a different line, and filtering one does not filter
  the other. Each appears in 29 of 41 failing job logs. Left in, they match the
  broad `not found` term and crowd the real cause out of the `tail`; that is what buried
  `Failed to pull image "…llm-d-router-disagg-sidecar:v0.8.1": … not found` on the ROCM lane.
- **The `awk` dedup on line content** — `FailedScheduling` events repeat once per pod and once
  per collection pass. One node-capacity message across ten pods otherwise fills the whole
  tail and pushes the actual failure out.

If the tail still looks like debug output, widen the `tail` in `errsig.sh` or grep
`$LOG_DIR/job-<job>.log` for the specific term the earlier lines hint at. `errsig.sh` is a net,
not a parser. Two signatures worth knowing on sight, because neither appears in the windowed
output and both arrive only via the escalation:

```
0/20 nodes are available: 13 Insufficient cpu, 3 node(s) had untolerated taint …
      -> cluster capacity, not the guide. Expect every lane on that platform to be red.
Failed to pull image "docker.io/lmsysorg/sglang:v0.5.16.0": … not found
      -> a tag that does not exist. Will not clear on a rerun.
```

## Phase 3b: Lifetime Context for Red Lanes

Everything so far is scoped to seven days, so every lane that is red throughout looks the same.
They want opposite actions. A lane that regressed last month needs the change that broke it
reverted, a lane red since spring needs a decision about whether to keep it, and a lane that has
**never passed once** needs its author, because there is no green state to restore and a
tracking issue will sit on it forever.

Count the streak over decisive runs only, matching Phase 1; counting cancellations as failures
here inflates a mostly-cancelled lane into the oldest breakage in the fleet.

One paginated call per red lane, so roughly a dozen:

```bash
for slug in llm-d llm-d-infra; do
  jq -r --arg r "llm-d/$slug" '.[] | select(.red) | "\($r)\t\(.file)\t\(.lane)"' \
    "$LOG_DIR/$slug-lanes.json"
done | sh $NS/lifetime.sh > $LOG_DIR/lifetime.tsv
column -t -s$'\t' $LOG_DIR/lifetime.tsv   # streak | last success | decisive runs | first run | lane
```

`.file` and not `.lane` in the second column: the workflows API needs the real basename, and
`.yaml`, `.yml` and `.lock.yml` all occur in this fleet.

Runs come back newest first, so the index of the first `success` is the lifetime failure streak.
A lane with no success anywhere reads `NEVER PASSED` in column 2. That is not a regression, so
report those separately from CHRONIC:

```bash
awk -F'\t' '$2 == "NEVER PASSED"' $LOG_DIR/lifetime.tsv | column -t -s$'\t'
```

Check `first run` before writing any of these up. A lane merged yesterday shows one decisive run
and a streak of 1, which satisfies the test while saying nothing. Report a never-passed lane
only once it has had a few nights to run.

Column 2 carries two other sentinels, and neither is a finding about the lane. `LOOKUP FAILED`
means the workflows API returned nothing for that basename — a rename, or a rate limit — and
`NO DECISIVE RUN` means every run it has ever had was cancelled or skipped. Both print a row
rather than vanishing: an unguarded lookup used to drop the lane from the table entirely, which
reads as "no lifetime concern" rather than "not answered".

## Phase 3c: Categorize

Do not invent a failure taxonomy and do not map step names to it by hand. The pipeline already
classifies its own failures: `reusable-ci-nightly-benchmark.yaml` in `llm-d-infra` assigns every
run a `failure_category` of `prepare`, `prereqs`, `infra`, `guide` or `benchmark`, chosen by
which step ID failed, and the step IDs carry the category as a prefix. Generate the lookup from
the workflow source so it stays correct as steps are renamed, added and removed:

```bash
unset GITHUB_TOKEN && gh api \
  "repos/llm-d/llm-d-infra/contents/.github/workflows/reusable-ci-nightly-benchmark.yaml" \
  -H "Accept: application/vnd.github.raw" > $LOG_DIR/benchmark-wf.yaml

# One pass produces both things this phase needs. The category map goes to -v out=…; the step
# ids that can fail *without* setting a category go to stdout, and are discussed below.
awk -f $NS/bench-steps.awk -v out=$LOG_DIR/step-category.tsv $LOG_DIR/benchmark-wf.yaml \
  | sort > $LOG_DIR/uncategorized-step-ids.txt
jq -Rn 'reduce (inputs | split("\t")) as $x ({}; .[$x[1]] = $x[0])' \
  $LOG_DIR/step-category.tsv > $LOG_DIR/step-category.json

# Fleet-wide counts over the current failures Phase 3 attributed
jq -r -n --slurpfile st $LOG_DIR/steps.json --slurpfile cat $LOG_DIR/step-category.json '
  $st[0] | to_entries | map($cat[0][.value] // "uncategorized")
  | group_by(.) | map("\(length)\t\(.[0])") | .[]' | sort -rn
```

`uncategorized` is expected. The map covers the benchmark reusable workflow, so lanes that stand
a guide up by another route and non-benchmark lanes such as the `gh-aw` agentic workflows fall
outside it. Report the count rather than forcing those into a bucket.

Categorizing on the step *name* instead is wrong in both directions. `Request TPUs (DWS)` reads
like accelerator contention and is `infra_request_tpus` → **infra**; the step usually dies in
about a second on stale cluster state with no contention involved. `Standup` is `guide_standup`
→ **guide** for every lane that fails there, which is correct but coarse, collecting capacity
exhaustion and pod-readiness failures under one label.

That coarseness is deliberate. Categories are cheap and belong in the breakdown table. Causes
are expensive and belong in the incidents section, backed by the error text from `errtext.sh`.
Do not try to recover causes from the category table, and do not subdivide the categories on
guesswork to make the table look more informative than it is.

As a cross-check, the badge job commits its verdict to `gh-pages` with the category in the
commit message:

```bash
unset GITHUB_TOKEN && gh api \
  "repos/llm-d/llm-d/commits?sha=gh-pages&since=$(date -u -v-${DAYS}d +%Y-%m-%d 2>/dev/null \
    || date -u -d "$DAYS days ago" +%Y-%m-%d)&per_page=100" --paginate --slurp \
  | jq -r '[.[][].commit.message] | map(capture("\\((?<m>[a-z-]+)\\)$").m)
           | group_by(.) | map("\(length)\t\(.[0])") | .[]' | sort -rn
```

Read this as state transitions rather than one row per run. The badge is only committed when the
JSON changes, so a lane failing the same way two nights running produces one commit. Use it to
sanity-check the shape of the breakdown rather than to fill it.

The two disagree on a known set of steps. The map above is derived from step-ID prefixes, but
`detect_failure` tests an explicit `elif` list, and that list is a subset of the steps carrying a
category prefix. If a step outside it fails, the pipeline emits an empty category and the badge
reads a bare `failing` while the map here assigns a category from the prefix. An unexplained
`failing` badge against a populated row is that gap rather than a miscount.

That set changes as steps are added, which is why `bench-steps.awk` derives it above rather than
carrying a list. It is already in `$LOG_DIR/uncategorized-step-ids.txt`:

```bash
cat $LOG_DIR/uncategorized-step-ids.txt
```

Match the step id token class as `[a-z0-9_]`. An earlier `grep` used `[a-z_]` and stopped at the
first digit, so `prepare_skip_tpu_v7_run` was compared as `prepare_skip_tpu_v` on both sides and
reported under a step id that does not exist. The full id is a real gap; the truncated name it
was reported under was noise.

## Phase 4: Correlate

Grouping on the failed step alone over-merges. `Standup` and `Run` name a whole phase of the
reusable workflow, so unrelated causes collect under one name. Group by step *and* by when each
lane broke: lanes that failed at the same step starting the same night are one investigation,
while a lane that broke last night at a step five others have failed at all week is separate.

```bash
# cluster.jq needs $steps bound, and jq has no --slurpfile equivalent for a *filter* file, so
# the filter is composed inline around it rather than passed with -f.
jq --slurpfile sf $LOG_DIR/steps.json \
   '$sf[0] as $steps | '"$(cat $NS/cluster.jq)" \
   $LOG_DIR/llm-d-lanes.json > $LOG_DIR/incidents.json
jq -r '.[] | "\(if .incident then "INCIDENT" else "pair" end)\t\(.lanes)\t\(.step)"
  + "\t\(.broke_on | map(. // "before window") | join(", "))"
  + "\t\([.members[].lane] | join(", "))"' \
  $LOG_DIR/incidents.json | column -t -s$'\t'
```

A cluster whose `broke_on` is a single date is one event and you can line it up against what
merged that day. Several dates means the members went red on different nights, which points at
a fault carried in state rather than a change landing. `before window` means the whole cluster
predates the window, so take the real dates from Phase 3b.

This clusters `llm-d` only. The other repo has few enough lanes to correlate by eye, but say so
rather than letting its failures quietly skip incident analysis.

Before writing a cluster up as one cause, confirm it on the error text of two of its members
rather than on the step name: `sh $NS/errtext.sh <repo> <run_id>` on two `members[].url`
values.

Clustering fails in both directions:

- **Over-merged.** Two unrelated causes share a step name. Four lanes failing at `Standup` can
  be capacity exhaustion on one platform and pods that schedule fine then never pass a startup
  probe on another. Confirming on error text splits these.
- **Under-merged.** One cause spreads across lanes on different nights, so the streak window
  puts them in separate clusters. A fault carried in per-namespace or per-cluster state poisons
  each lane the first time *that lane* touches it, which can be days apart. The symptom is a
  lane with a short streak whose error text matches a much older cluster at the same step.

The clustering above only catches the first. List the candidates for the second explicitly,
which are the steps whose red lanes span more than the cluster window:

```bash
jq -r --slurpfile sf $LOG_DIR/steps.json '$sf[0] as $st
  | [ .[] | select(.red)
      | {lane, streak, step: ($st[(.last_fail_id|tostring)] // "(unknown)")} ]
  | group_by(.step) | map(select(length >= 2))
  | map(select((map(.streak) | max) - (map(.streak) | min) > 2))
  | .[] | "\(.[0].step)\t\([.[] | "\(.lane) [streak \(.streak)]"] | join(", "))"' \
  $LOG_DIR/llm-d-lanes.json | column -t -s$'\t'
```

This is a candidate list. It will surface unrelated lanes that happen to share a step name. Resolve each one on error text. Matching signatures mean one incident
reported once; differing signatures mean the split was right. Check a newly broken lane
appearing next to a long-broken one first, since reporting it as an isolated new break costs
more than the reverse.

## Phase 5: Generate Report

Compute the summary figures rather than estimating them from the tables above:

```bash
jq -n --slurpfile a $LOG_DIR/llm-d-lanes.json --slurpfile b $LOG_DIR/llm-d-infra-lanes.json '
  def rate: (map(.decisive) | add // 0) as $n
    | {runs: $n, pct: (if $n > 0 then ((map(.passes) | add) * 100 / $n | floor) else null end)};
  ($a[0] + $b[0]) as $all
  | { lanes:      ($all | length), llm_d: ($a[0] | length), infra: ($b[0] | length),
      fleet:      ($all | rate),
      ex_chronic: ($all | map(select(.status != "CHRONIC")) | rate),
      new_break:  ($all | map(select(.status == "NEW BREAK")) | length),
      chronic:    ($all | map(select(.status == "CHRONIC"))   | length),
      no_verdict: ($all | map(select(.status == "NO VERDICT"))| length) }' \
  > $LOG_DIR/summary.json
cat $LOG_DIR/summary.json
echo "never passed:  $(awk -F'\t' '$2 == "NEVER PASSED"' $LOG_DIR/lifetime.tsv \
                       | wc -l | tr -d ' ')"
# TOO NEW is a lane awaiting its first cron and LOOKUP FAILED is a call that did not return.
# Neither is a coverage gap, and counting the rows wholesale reported both as one.
echo "coverage gaps: $(cat $LOG_DIR/*-gap-report.tsv \
                       | grep -cvE '^(TOO NEW|LOOKUP FAILED)')"
```

`pct` is null when no lane produced a decisive run, which is the all-green-and-all-cancelled
case. Say so rather than printing 0%.

### Template

```markdown
## Nightly E2E Report — Week of YYYY-MM-DD

### Summary
- **Lanes**: `.lanes` (`.llm_d` in llm-d, `.infra` in llm-d-infra)
- **Decisive runs**: `.fleet.runs` — `.fleet.pct`% passed, **`.ex_chronic.pct`% excluding chronic lanes**
- **Needs attention**: `.new_break` new breaks, `.chronic` chronic (C of which have never passed),
  D coverage gaps

Fleet-wide pass rate is a weak signal on its own, because chronic lanes hold it down and it
barely moves when one lane breaks. Quote it next to the rate with chronic lanes excluded. The
second number answers whether the working part of the fleet is getting worse.

### Lanes Needing Attention

| Lane | Status | Passed | Broke on | Sequence | Failed step | Cost | Run |
|------|--------|--------|----------|----------|-------------|------|-----|
| nightly-e2e-pd-disaggregation-gke-acc-tpu-vllm-x | NEW BREAK | 5/7 | 2026-07-27 | `PPPPPFF` | Request TPUs (DWS) | 1h2m | <url> |
| nightly-e2e-wide-ep-lws-gke-acc-gpu-vllm-x | CHRONIC | 0/7 | before window | `FFFFFFF` | Standup | 5h1m | <url> |

`Passed` is a count over decisive runs. At seven runs a week `5/7` carries information that
`71%` throws away, and it makes the denominator visible when cancellations shrink it.
Percentages appear only in the summary and in Phase 6, where the comparison is across weeks. Do
not mix the two units in one table.

Rates exclude cancelled and skipped runs. Sequence is oldest to newest. Cost is `fail_min` ×
failures, roughly the cluster time this lane burnt over the window. `fail_min` is whole-run wall
clock rather than time in the failing step, so a run whose step dies in the first second still
pays for debug collection and teardown. Expect a lane that bails during standup to read around
10 minutes against 40-plus for one that holds accelerators through a readiness timeout. Use the
ratio between lanes rather than the absolute number. Flag any lane that cannot recover without
manual cleanup, since a rerun will not clear it.

### Lanes That Have Never Passed

From Phase 3b, the lanes reading `NEVER PASSED` in `lifetime.tsv`. These are not regressions and
do not belong in the chronic list. `First seen` is the `first run` column from the same file.

| Lane | Runs | First seen | Note |
|------|------|------------|------|
| nightly-e2e-flow-control-gke-acc-gpu-vllm-x | 63 | 2026-06-11 | merged broken; needs its author |

Drop any lane whose first run is within the last few days. One decisive run satisfies the
never-passed test without meaning anything.

For chronic lanes that *did* once pass, give the last-success date rather than the in-window
streak. "Red since April" and "red since Monday" read identically at seven days.

### Coverage Gaps

| Lane | Verdict | Last scheduled run | Action |
|------|---------|--------------------|--------|
| nightly-e2e-wide-ep-lws-gke | REMOVED | 2026-06-08 | confirm a replacement lane covers this |
| nightly-e2e-fast-model-actuation-ibm-acc-gpu-vllm-x | NEVER RAN | never | unexplained — trigger checks exhausted |

Action is the standard response for the verdict. Where a gap survives those checks, say so
instead of restating them. Gaps sharing a `last` date are usually one
rename, so collapse them into a single row.

### Lanes With No Verdict

Lanes classified NO VERDICT in Phase 1, which every later phase excludes. These have no failed
step to attribute, so report the cancellation itself.

| Lane | Sequence | Note |
|------|----------|------|
| nightly-e2e-tiered-prefix-cache-gke-cpu-gpu-vllm-native | `-------` | cancelled every night; check the workflow timeout and concurrency group |

### Probable Single Incidents

One row per confirmed cause rather than per cluster. Split a cluster whose members show
different error text, and merge clusters whose members show the same.

| Cause | Step | Lanes | Broke on | Evidence |
|-------|------|-------|----------|----------|
| GKE accelerator capacity exhausted | Standup | 3 | before window (since 2026-06-29) | `FailedScaleUp: GCE out of resources` |
| Stale namespace blocks TPU request | Request TPUs (DWS) | 3 | 2026-07-22, 2026-07-26 | `AlreadyExists` then `no matching resources found` |

`Broke on` comes from the cluster's `broke_on`. Where it reads `before window`, give the real
date from Phase 3b in parentheses. An incident whose members have been red since June is a
different conversation from one that started this week.

### Failure Breakdown by Category

The pipeline's own categories, from Phase 3c. Do not substitute a taxonomy of your own.

| Category | Count | % of Failures |
|----------|-------|---------------|
| prepare | N | X% |
| prereqs | N | X% |
| infra | N | X% |
| guide | N | X% |
| benchmark | N | X% |
| uncategorized | N | X% |

State the denominator. If these counts come from the current failure per red lane, they cover
that set rather than every failure in the window, and the two differ by roughly an order of
magnitude. Keep the `uncategorized` row even at zero, since Phase 3c's count is part of the
result.

### Action Items
- [ ] <action 1>
- [ ] <action 2>
```

Group findings by cause rather than by lane. Say which lanes you could not explain, and treat a
step name as an explanation only if you have the error text behind it.

## Phase 6: Week-over-Week

Both windows are `$DAYS` long and they do not overlap: the current one covers days `DAYS-1`
through `0` and the previous one covers `2*DAYS-1` through `DAYS`. Unequal windows would put a
`/7` denominator next to a `/8` one and read the difference as a change in health.

```bash
for repo in llm-d/llm-d llm-d/llm-d-infra; do
  slug=${repo##*/}
  sh $NS/fetch-window.sh "$repo" $((2*DAYS-1)) $DAYS "$LOG_DIR/$slug-prev-runs.json"
  jq -f $NS/lanes.jq "$LOG_DIR/$slug-prev-runs.json" > "$LOG_DIR/$slug-prev-lanes.json"
done

# Confirm the two windows are the same length and disjoint before comparing them.
jq -n --slurpfile p $LOG_DIR/llm-d-prev-runs.json --slurpfile c $LOG_DIR/llm-d-runs.json '
  ([$p[0][].run_started_at[0:10]] | unique) as $a
  | ([$c[0][].run_started_at[0:10]] | unique) as $b
  | {prev: "\($a[0]) -> \($a[-1])", days_prev: ($a|length),
     cur:  "\($b[0]) -> \($b[-1])", days_cur:  ($b|length),
     overlap: [$a[] | select(IN($b[]))]}'

# Per-lane rate delta against last week
jq -rn --slurpfile now $LOG_DIR/llm-d-lanes.json --slurpfile prev $LOG_DIR/llm-d-prev-lanes.json '
  ($prev[0] | map({key: .lane, value: .rate}) | from_entries) as $p
  | $now[0]
  | map(select($p[.lane] != null and (.rate - $p[.lane] | fabs) >= 15)
        | {lane, was: $p[.lane], now: .rate, status})
  | sort_by(.now - .was)
  | .[] | "\(.lane)\t\(.was)% -> \(.now)%\t\(.status)"' \
  | column -t -s$'\t'
```

Also compare the lane sets, in both directions:

```bash
jq -n --slurpfile now $LOG_DIR/llm-d-lanes.json --slurpfile prev $LOG_DIR/llm-d-prev-lanes.json '
  ($prev[0] | map(.lane)) as $p
  | {appeared:    ($now[0]  | map(select(.lane | IN($p[])            | not))
                            | map({lane, status, rate})),
     disappeared: ($prev[0] | map(select(.lane | IN($now[0][].lane)  | not)) | map(.lane))}'
```

A lane that **disappeared** is a coverage gap that Phase 2 will confirm. A lane that
**appeared** matters too and is easy to miss: one merged in a broken state starts inflating the
chronic count immediately while looking like ordinary background red. Check the status of every
lane in `appeared`. A new lane that has never passed belongs with the never-passed lanes from
Phase 3b rather than with the chronic ones.

## Related Files

Read these by path; none is a registered skill. Paths are relative to `.claude/skills/`.

- `nightly/scripts/` — the shell and jq every phase above runs; `README.md` there is the index
- `nightly/SKILL.md` — parent router, for triaging a single night rather than a week
- `nightly/rca/SKILL.md` — deep dive on specific failures flagged in this report
