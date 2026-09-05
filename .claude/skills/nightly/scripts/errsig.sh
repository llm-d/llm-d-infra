# usage: sh errsig.sh <owner/repo> <run_id> — greps the whole failing job log for real errors
# errtext.sh calls this itself when its window names no cause; call it directly only to widen
# an answer you already have.
repo=$1; run=$2
: "${LOG_DIR:?export LOG_DIR before calling this script}"
: "${NS:?export NS to this scripts directory before calling this script}"

meta=$(sh "$NS/jobmeta.sh" "$repo" "$run") || exit 1
job=$(printf '%s' "$meta" | cut -f1)
[ -n "$job" ] || { echo "!! no failing step on run $run"; exit 1; }
sh "$NS/joblog.sh" "$repo" "$job" || exit 1

# Post-failure debug collection, present on ~70% of failing jobs regardless of cause.
noise='::error::|LLMDBENCH_|Teardown command failed|Optional tool not found'
# The tool-check table renders as `  oc  —  (optional, not found)`, which shares no substring
# with "Optional tool not found" above and so survives it. It matches the broad `not found`
# term and heads the tail on any lane where `oc` is absent.
noise="$noise"'|\(optional, not found\)'
noise="$noise"'|jobs.batch "download-model" not found'
noise="$noise"'|pods "access-to-harness-data-workload-pvc" not found'
noise="$noise"'|::warning::|GITHUB_STEP_SUMMARY|⏳'

sh "$NS/clean.sh" < "$LOG_DIR/job-$job.log" \
  | grep -nE '❌|FAILED -|\* Error:|^error:|^Error|##\[error\]|FailedScheduling|Unschedulable|Insufficient|ErrImagePull|ImagePullBackOff|CrashLoopBackOff|BackOff|No such file|not found|denied' \
  | grep -vE "$noise" \
  | awk -F: '{k=$0; sub(/^[0-9]+:/,"",k); if (!seen[k]++) print}' \
  | tail -20
