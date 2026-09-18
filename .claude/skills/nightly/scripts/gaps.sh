# usage: sh gaps.sh <owner/repo>
# Reads  $LOG_DIR/<slug>-{workflows,runs,files}.json   (workflows must carry `created`)
# Writes $LOG_DIR/<slug>-gaps.json        — registered lanes that produced no run
#        $LOG_DIR/<slug>-gap-report.tsv   — verdict \t last scheduled run \t state \t lane
#
# A lane that stops running is invisible to any check that starts from a list of runs: it reads
# as "not failing" while testing nothing. Anti-join the registry against the runs to find them.
repo=$1; slug=${repo##*/}
: "${LOG_DIR:?export LOG_DIR before calling this script}"
# jq's test("") matches every string, so an unset filter silently excludes every run — and an
# empty gap table then reads as a clean fleet.
: "${EXCLUDE_RE:?export EXCLUDE_RE before calling this script}"

jq -n --slurpfile wf "$LOG_DIR/$slug-workflows.json" \
      --slurpfile runs "$LOG_DIR/$slug-runs.json" \
      --slurpfile files "$LOG_DIR/$slug-files.json" \
      --arg ex "$EXCLUDE_RE" '
  ($runs[0] | map(.path) | unique) as $ran
  | $files[0] as $onbranch
  | [ $wf[0][]
      | select(.path | test($ex) | not)
      | select(.path | IN($ran[]) | not)
      | {id, path, name, state, created, on_branch: (.path | IN($onbranch[]))} ]' \
  > "$LOG_DIR/$slug-gaps.json"

# Most zero-run workflows are ordinary PR or push workflows. Keep only the ones that are
# actually scheduled — without this the `reusable-nightly-e2e-*.yaml` workflows in llm-d-infra,
# which are workflow_call:-only and never produce runs of their own, are all reported as
# missing nightlies.
cat > "$LOG_DIR/lastrun.jq" <<'JQ'
if (.total_count // 0) == 0 then "never"
else (.workflow_runs[0] | (.run_started_at // .created_at) | tostring | split("T")[0]) end
JQ
export LR="$LOG_DIR/lastrun.jq" REPO=$repo
# A lane registered inside this window has not reached its first scheduled fire yet. Two days
# covers a daily cron plus the lag before GitHub first honours it.
export TOO_NEW_BEFORE=$(date -u -v-2d +%Y-%m-%d 2>/dev/null || date -u -d '2 days ago' +%Y-%m-%d)

# One NUL-delimited record per lane rather than `xargs -n 5`. xargs splits on *any* whitespace,
# so a workflow path containing a space would shift every field of that row and of the rows
# batched after it, and the misaligned verdicts would look plausible. Same guard as lifetime.sh.
jq -r '.[] | "\(.id)\t\(.path)\t\(.on_branch)\t\(.state)\t\(.created)"' "$LOG_DIR/$slug-gaps.json" \
| tr '\n' '\0' \
| xargs -0 -P 8 -n 1 sh -c '
    id=$(printf "%s" "$0" | cut -f1)
    path=$(printf "%s" "$0" | cut -f2)
    on_branch=$(printf "%s" "$0" | cut -f3)
    state=$(printf "%s" "$0" | cut -f4)
    created=$(printf "%s" "$0" | cut -f5)
    # Last *scheduled* run, not last run: a lane can be dispatched manually after its cron was
    # removed, which would otherwise hide the gap.
    last=$(unset GITHUB_TOKEN; gh api \
      "repos/$REPO/actions/workflows/$id/runs?event=schedule&per_page=1" 2>/dev/null \
      | jq -r -f "$LR")
    # A failed call yields empty, and empty is != "never", so it would be taken for a scheduled
    # lane and land on the STALE arm below — inventing a gap out of a rate limit.
    if [ -z "$last" ]; then
      printf "%s\t%s\t%s\t%s\n" "LOOKUP FAILED" "-" "$state" "${path##*/}"; exit 0
    fi
    if [ "$last" != "never" ]; then :
    elif [ "$on_branch" = "true" ] && unset GITHUB_TOKEN && gh api "repos/$REPO/contents/$path" \
           -H "Accept: application/vnd.github.raw" 2>/dev/null \
           | grep -qE "^[[:space:]]+schedule:"; then :
    else exit 0; fi
    case "$state:$on_branch:$last" in
      # Registered too recently to have fired. Reporting this as a gap turns every lane added
      # yesterday into a false alarm. Match the date shape first: a jq "null" would sort above
      # any real date and mark everything TOO NEW.
      active:*:never) case "$created" in
                        20??-??-??) [ "$created" \> "$TOO_NEW_BEFORE" ] \
                                      && verdict="TOO NEW" || verdict="NEVER RAN" ;;
                        *)          verdict="NEVER RAN" ;;
                      esac ;;
      active:false:*) verdict="REMOVED" ;;     # file deleted, registration lingers
      active:true:*)  verdict="STALE" ;;       # file present, cron stopped firing
      *)              verdict="DISABLED" ;;    # incl. GitHub 60-day inactivity auto-off
    esac
    printf "%s\t%s\t%s\t%s\n" "$verdict" "$last" "$state" "${path##*/}"' \
| sort > "$LOG_DIR/$slug-gap-report.tsv"
