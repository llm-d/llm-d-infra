# usage: sh errtext.sh <owner/repo> <run_id> — prints the failing step's actual output
#
# Windows the job log on the failed step's timestamps, which the jobs API already returns.
# The two obvious routes do not work: `gh run view <id> --log` renders every step as the
# literal string UNKNOWN STEP, and the run-level log zip holds one file per *job*, not per
# step. See nightly/report/SKILL.md Phase 3a — every filter below drops silently.
repo=$1; run=$2
: "${LOG_DIR:?export LOG_DIR before calling this script}"
: "${NS:?export NS to this scripts directory before calling this script}"

meta=$(sh "$NS/jobmeta.sh" "$repo" "$run") || exit 1
[ -n "$meta" ] || { echo "!! no failing job/step on run $run"; exit 1; }
job=$(printf '%s' "$meta" | cut -f1); a=$(printf '%s' "$meta" | cut -f2)
b=$(printf '%s' "$meta" | cut -f3);   step=$(printf '%s' "$meta" | cut -f4)
sh "$NS/joblog.sh" "$repo" "$job" || exit 1

echo "== $step  ($a -> $b) =="
# substr($1,1,19), not bare $1: log lines carry sub-second precision while the API bounds are
# whole seconds, so a direct string compare excludes every line in the final second — which is
# the entire output of a step that fails in one second.
#
# Then skip past the first ##[endgroup] and stop at the next ##[group]. Ahead of the endgroup
# sits the runner's echo of the *script source*, which is why `grep -i error` on a raw job log
# returns things like `echo "::error::Unsupported accelerator type"`. Without the stop the
# following step's preamble trails in. Timestamp windowing alone still leaves hundreds of
# lines; the group boundaries take it to under ten.
#
# ⏳ is the smoketest progress ticker. It redraws every ten seconds, so on any lane that failed
# during a wait it owns the whole body and the cause never makes it in. clean.sh has already
# removed the ESC[2K that goes with it.
body=$(awk -v a="$a" -v b="$b" 'substr($1,1,19) >= a && substr($1,1,19) <= b' \
         "$LOG_DIR/job-$job.log" \
       | sh "$NS/clean.sh" \
       | awk 'f && /##\[group\]/{exit} f; /##\[endgroup\]/{f=1}' \
       | grep -v '⏳')

# The stop-at-##[group] clause is not an edge case on this fleet: `Standup` emits its own
# ::group:: around the env dump, so the window ends on the env block and tails out on
# `namespace/… configured` and `secret/llm-d-hf-token created` — normal setup lines that read
# like a step which failed without saying anything. That truncated 9 of 34 runs on one pass.
# Escalating here rather than leaving it to the caller: every caller wants the same answer, and
# the two that existed had to keep their copies of this signature list in step.
#
# ##[error] is deliberately absent. 25 of 34 bodies carry `##[error]Process completed with exit
# code 1.`, which marks the failure without naming it, so including it passes every truncated
# body as explained.
sig='❌|FAILED -|\* Error:|^error:|^Error|FailedScheduling|Unschedulable|Insufficient'
sig="$sig"'|ErrImagePull|CrashLoopBackOff|BackOff|No such file|not found|timed out|did not become'
n=$(printf '%s\n' "$body" \
    | grep -cvE '^[[:space:]]*$|^namespace/|^secret/|^##\[endgroup\]')

if [ "$n" -lt 3 ] || ! printf '%s\n' "$body" | grep -qE "$sig"; then
  # Grep for this marker to count how much of a pass fell back; expect roughly a quarter.
  echo "## NO CAUSE IN WINDOW — whole-log signature scan follows"
  sh "$NS/errsig.sh" "$repo" "$run"
else
  printf '%s\n' "$body"
fi
