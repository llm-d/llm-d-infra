# nightly scripts

The shell and jq that `nightly/SKILL.md` and `nightly/report/SKILL.md` run. They live here as
files rather than as heredocs inside the two documents, because both documents need most of
them and a heredoc can only be copied, not shared. Every copy that existed drifted: the gap
scan grew a `TOO NEW` guard in one document and not the other, so the weekly report turned
every lane added yesterday into a coverage gap.

Both documents export the same two variables before calling anything here:

```bash
export LOG_DIR=/tmp/llm-d/nightly/$(date -u +%F)   # per-day, so yesterday's artifacts cannot leak in
export NS="$(git rev-parse --show-toplevel)/.claude/skills/nightly/scripts"
mkdir -p "$LOG_DIR"
```

Everything is POSIX `sh`, invoked as `sh $NS/<name>.sh`, and writes its bulk output to
`$LOG_DIR` rather than to stdout. `awk`/`jq` files are passed with `-f`.

| File | Takes | Gives |
|---|---|---|
| `fetch-window.sh` | repo, oldest-days-ago, newest-days-ago, outfile | scheduled runs for the window, one API query per day |
| `gaps.sh` | repo | `$slug-gaps.json`, `$slug-gap-report.tsv` — registered lanes producing no runs, with a verdict each |
| `successor.awk` | `cur=`, `ran=`, gap report on argv | a proposed replacement lane per gap row, by token overlap |
| `jobmeta.sh` | repo, run id | `job_id⇥step_start⇥step_end⇥step_name` for the first failing step; caches the jobs response |
| `joblog.sh` | repo, job id | ensures `$LOG_DIR/job-<job>.log`; a concluded job's log is immutable, so it downloads once |
| `clean.sh` | a job log on stdin | the same log with ANSI stripped and the timestamp column cut |
| `errtext.sh` | repo, run id | the failing step's real output, escalating to `errsig.sh` when that window names no cause |
| `errsig.sh` | repo, run id | whole-job-log grep for error signatures, minus the known false positives |
| `bench-steps.awk` | `out=`, benchmark workflow on argv | the step-id→category map to `out=`, and to stdout the ids that set no category |
| `failed-steps.sh` | `repo⇥run` on stdin | `run⇥step` TSV, 8 at a time |
| `pull.sh` | TSV whose fields 1, 2 and 5 are repo, run id, lane | one `err-<run>.txt` body per row, 6 at a time |
| `lifetime.sh` | `repo⇥file⇥lane` on stdin | lifetime streak, last green, decisive runs, first run, lane — `NEVER PASSED`, `NO DECISIVE RUN` or `LOOKUP FAILED` in column 2 where there is no green |
| `lanes.jq` | a window of runs | one classified row per lane |
| `cluster.jq` | `$steps` + lane rows | red lanes grouped into probable single incidents |

The scripts that fan out over a TSV feed `xargs` one NUL-delimited *record* and split the fields
inside with `cut`, rather than letting `xargs -n <fields>` do the splitting. `xargs` splits on any
whitespace, so a single field containing a space — a lane's display name, "Nightly - Optimized
Baseline E2E (GKE GPU)" — shifts every field of that row and of every row batched after it. That
failed loudly once, only because the stray words were not valid repo names; the general case is
silently misaligned output. `pull.sh` avoids `xargs` altogether for the same reason.

The two documents explain why each script does what it does. The comments in the scripts cover
only what would be unsafe to change without reading that prose. Read `nightly/report/SKILL.md`
Phase 3a before touching `errtext.sh` or `errsig.sh`. Each filter in them removes a specific
kind of noise, and removing a filter drops output without raising an error.
