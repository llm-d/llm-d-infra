# usage: printf '<owner/repo>\t<workflow file>\t<lane>\n' … | sh lifetime.sh
# -> streak \t last green \t decisive runs \t first run \t lane, sorted worst first
#
# The seven-day window cannot tell a lane that regressed last month from one red since spring
# from one that has never passed once. They want opposite actions: a revert, a decision about
# whether to keep the lane, and the lane's author respectively.
#
# The workflow file must carry its extension — .yaml, .yml and .lock.yml all occur and the
# workflows API needs the real basename. per_page=100 is the API maximum and the point: at a
# smaller page most llm-d lanes come back capped, and a capped streak is indistinguishable
# from "never passed".
#
# One NUL-delimited record per row rather than `xargs -n 3`. xargs splits its input on *any*
# whitespace, and a lane passed as its display name — "Nightly - Optimized Baseline E2E (GKE
# GPU)" — becomes eight arguments, so the repo and file for every row after the first are
# whatever words happened to land in $0 and $1. That failed loudly here only because the stray
# words were not valid repos; a caller whose lane names merely contain one space would get
# silently misaligned rows instead.
tr '\n' '\0' \
| xargs -0 -P 6 -n 1 sh -c '
    repo=$(printf "%s" "$0" | cut -f1)
    file=$(printf "%s" "$0" | cut -f2)
    lane=$(printf "%s" "$0" | cut -f3)
    [ -n "$repo" ] && [ -n "$file" ] || exit 0
    unset GITHUB_TOKEN
    row=$(gh api "repos/$repo/actions/workflows/$file/runs?event=schedule&per_page=100" \
            --paginate --slurp 2>/dev/null \
          | jq -r --arg l "$lane" "
              # Keep every ?. A wrong or renamed file 404s, and --slurp wraps the error body
              # rather than the run pages, so an unguarded .workflow_runs[] aborts the row with
              # \"Cannot iterate over null\" on stderr and prints nothing. The lane then
              # vanishes from the table rather than reporting that it could not be read.
              [.[]? | .workflow_runs? // empty] as \$pages
              | if (\$pages | length) == 0 then \"0\tLOOKUP FAILED\t0\t-\t\(\$l)\"
                else
                  # Decisive runs only, matching lanes.jq. Counting cancellations as failures
                  # inflates a mostly-cancelled lane into the oldest breakage in the fleet, and
                  # the run count in column 3 is then a count of nothing.
                  [\$pages[][]
                    | select(.conclusion == \"success\" or .conclusion == \"failure\"
                             or .conclusion == \"timed_out\"
                             or .conclusion == \"startup_failure\")] as \$runs
                  # A registered lane whose every run so far was cancelled or skipped has no
                  # streak and no dates; .[-1] on [] is null and raises before any fallback.
                  | if (\$runs | length) == 0 then \"0\tNO DECISIVE RUN\t0\t-\t\(\$l)\"
                    else
                      # Runs come back newest first, so the index of the first success is the
                      # lifetime failure streak, and no success at all means the whole list.
                      ((([\$runs[].conclusion] | index(\"success\")) // (\$runs | length)) as \$streak
                       | \"\(\$streak)\t\([\$runs[] | select(.conclusion == \"success\")] | first
                             | (.run_started_at[0:10] // \"NEVER PASSED\"))\t\(\$runs | length)\t\(\$runs[-1].run_started_at[0:10])\t\(\$l)\")
                    end
                end")
    # gh failing outright leaves jq with empty stdin, which prints nothing at all.
    if [ -n "$row" ]; then printf "%s\n" "$row"
    else printf "0\tLOOKUP FAILED\t0\t-\t%s\n" "$lane"; fi' \
  | sort -rn
