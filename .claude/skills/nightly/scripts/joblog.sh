# usage: sh joblog.sh <owner/repo> <job_id> — ensures $LOG_DIR/job-<job_id>.log exists
# --allow-escape-sequences is not optional. Job logs carry ANSI colour, and without the flag
# `gh` refuses the body and exits 1 with nothing on stdout. Sending that stderr to /dev/null
# makes a download failure read as a step that produced no output, which is the worst
# available failure mode, so the download is checked here and the stderr is kept.
repo=$1; job=$2
: "${LOG_DIR:?export LOG_DIR before calling this script}"
f="$LOG_DIR/job-$job.log"
[ -s "$f" ] && exit 0    # a concluded job's log is immutable; never refetch

if ! (unset GITHUB_TOKEN; gh api "repos/$repo/actions/jobs/$job/logs" --allow-escape-sequences) \
     > "$f" 2>"$LOG_DIR/job-$job.err"; then
  echo "!! log download failed for job $job:"; cat "$LOG_DIR/job-$job.err"; rm -f "$f"; exit 1
fi
