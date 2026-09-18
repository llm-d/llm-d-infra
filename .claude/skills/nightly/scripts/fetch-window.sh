# usage: sh fetch-window.sh <owner/repo> <oldest-days-ago> <newest-days-ago> <outfile>
#
# One query per day. `gh run list --limit N` and the REST runs endpoint both stop at 1000
# results and exit 0 without warning, and runs come back newest-first, so an oversized window
# silently loses its *oldest* days — llm-d/llm-d alone exceeds the cap inside a week, while one
# day stays well under it.
repo=$1; from=$2; to=$3; out=$4
# jq's test("") matches every string, so an unset filter silently excludes every run.
: "${EXCLUDE_RE:?export EXCLUDE_RE before calling this script}"
unset GITHUB_TOKEN
tmp=$(mktemp -d); i=$from
while [ "$i" -ge "$to" ]; do
  day=$(date -u -v-${i}d +%Y-%m-%d 2>/dev/null || date -u -d "$i days ago" +%Y-%m-%d)
  # `created=A..B` is inclusive at both ends, so A==B is a single day.
  # NOTE: --slurp cannot be combined with --jq; pipe to a separate jq.
  #
  # Every page carries the server's own total_count, so the truncation check is free — a
  # separate per_page=1 probe doubled the call count for a number already in hand. Checking
  # each day against it catches truncation while it is still partial; an assertion on the
  # window's start date would only fire once a *whole* day had already vanished.
  gh api "repos/$repo/actions/runs?event=schedule&created=$day..$day&per_page=100" \
    --paginate --slurp \
    | jq --arg day "$day" '(.[0].total_count // 0) as $want
        | [.[].workflow_runs[]]
        | if length < $want
          then error("\($day): \(length) of \($want) runs returned — one day now exceeds the 1000 cap; split by hour")
          else . end' > "$tmp/$day.json" || { echo "!! fetch failed for $day" >&2; exit 1; }
  i=$((i-1))
done
jq -s --arg ex "$EXCLUDE_RE" 'add
  | map(select(.path | test($ex) | not))
  | map({id, name, path, workflow_id, event, conclusion,
         run_started_at, updated_at, html_url})' "$tmp"/*.json > "$out"
rm -rf "$tmp"
