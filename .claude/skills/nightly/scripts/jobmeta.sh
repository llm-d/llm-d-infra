# usage: sh jobmeta.sh <owner/repo> <run_id>
# Prints one line for the first failing step of the first failing job:
#   <job_id>\t<step_started>\t<step_completed>\t<step_name>
# Prints nothing and exits 0 when the run has no failing step — a startup_failure with no jobs
# is the common case. Exits 1 only when the API itself gave nothing.
#
# The response is cached at $LOG_DIR/jobs-<run>.json. errtext.sh, errsig.sh and failed-steps.sh
# all want the same document for the same run, which on a full pass was three identical
# paginated calls per red lane.
repo=$1; run=$2
: "${LOG_DIR:?export LOG_DIR before calling this script}"
c="$LOG_DIR/jobs-$run.json"
src=$c

if [ ! -s "$c" ]; then
  # Stage through a temp: a half-written or empty response left at $c would be treated as a
  # valid cache by every later caller, and the run would silently attribute to nothing.
  t="$c.part"
  (unset GITHUB_TOKEN; gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" \
     --paginate --slurp) > "$t" 2>/dev/null
  jq -e '[.[].jobs[]?] | length > 0' "$t" >/dev/null 2>&1 \
    || { rm -f "$t"; echo "!! jobs API returned no jobs for run $run" >&2; exit 1; }
  # Keep it only if every job has concluded. A job whose conclusion is null is still running,
  # and a run can conclude while one lingers, so caching that would freeze "no failing job"
  # for the rest of the day. Usable now either way.
  if jq -e '[.[].jobs[]?] | map(.conclusion) | index(null) | not' "$t" >/dev/null 2>&1; then
    mv "$t" "$c"
  else
    src=$t
  fi
fi

jq -r '[.[].jobs[]? | select(.conclusion=="failure")][0] as $j
  # steps[]? — when no job failed $j is null, and bare .steps[] raises
  # "Cannot iterate over null" before the null check below can run.
  | ([$j.steps[]? | select(.conclusion=="failure")][0]) as $s
  | if $j == null or $s == null then empty
    else "\($j.id)\t\($s.started_at[0:19])\t\($s.completed_at[0:19])\t\($s.name)" end' "$src"
[ "$src" = "$c" ] || rm -f "$src"
