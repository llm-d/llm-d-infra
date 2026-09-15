# One classified row per lane, from a window of scheduled runs. See nightly/report/SKILL.md
# Phase 1 for what each status means and what it asks the reader to do.
#
# A run still in flight has conclusion: null. The window always ends at "now", so this is the
# common case and every lookup that touches .conclusion needs a guard. {...}[null] raises
# "Cannot index object with null" *before* a // "?" fallback can apply, so the fallback that
# looks like it handles this does not. `decisive` is already safe because IN() returns false
# on null.
def glyph: if . == null then "?" else                    # ? = still running
           {success:"P", failure:"F", timed_out:"T", startup_failure:"X",
            cancelled:"-", skipped:"s"}[.] // "?" end;
def decisive: IN("success","failure","timed_out","startup_failure");
def rank: . as $s
  | ["NEW BREAK","DEGRADED","CHRONIC","UNRELIABLE","NO VERDICT","FLAKY","HEALTHY"]
  | index($s) // 99;

[ group_by(.path)[]
  | sort_by(.run_started_at) as $runs
  # cancelled and skipped are excluded from the denominator: they record no verdict, and
  # counting them as failures reports a clean lane as 87%.
  | [$runs[] | select(.conclusion | decisive)] as $d
  | ($d | length) as $n
  | ([$d[] | select(.conclusion == "success")] | length) as $p
  | ([$d[].conclusion] | reverse) as $rev
  | (([$rev | to_entries[] | select(.value == "success") | .key] | first)
     // ($rev | length)) as $streak
  | ([$runs[] | select(.conclusion == "cancelled" or .conclusion == "skipped")]
     | length) as $nv
  | (if   $n == 0      then "NO VERDICT"          # only cancelled/skipped runs
     # One stray failure among seven cancellations must not read as CHRONIC 0/1.
     elif ($nv * 2) > ($runs | length) then "NO VERDICT"
     elif $p == $n     then "HEALTHY"
     elif $streak == 0 then (if ($p * 100 / $n) > 50 then "FLAKY" else "UNRELIABLE" end)
     elif $p == 0      then "CHRONIC"             # red for the whole window
     elif ($streak <= 2 and ($n - $streak) >= 3
           and ($p * 100 / ($n - $streak)) >= 85) then "NEW BREAK"
     else "DEGRADED" end) as $status
  | {
      lane:     ($runs[0].path | sub("^\\.github/workflows/";"") | sub("\\.ya?ml$";"")),
      # lane has the extension stripped and cannot be fed back to the workflows API.
      # Keep the real basename for lifetime.sh: .yaml, .yml and .lock.yml all occur.
      file:     ($runs[0].path | sub("^\\.github/workflows/";"")),
      name:     $runs[-1].name,
      runs:     ($runs | length),
      decisive: $n,
      passes:   $p,
      rate:     (if $n > 0 then ($p * 100 / $n | floor) else 0 end),
      streak:   $streak,
      seq:      ([$runs[] | .conclusion | glyph] | join("")),
      last_run: ($runs[-1].run_started_at | split("T")[0]),
      # The night the current red streak began. "6 runs ago" is not something a reader can act
      # on; a date is, and it is what lines a lane up against a merge or a cluster change.
      # Null when the lane is green, and when it is red throughout: the streak then starts at
      # the window edge, which is an artefact of the window rather than the night it broke.
      # Phase 3b has the real date for those.
      broke_on: (if $streak > 0 and $streak < $n
                 then ($d[-$streak].run_started_at | split("T")[0]) else null end),
      # Mean wall-clock minutes per failing run, over the whole run rather than the failing
      # step, so it includes debug collection and teardown. Separates a lane that bails during
      # standup from one that holds accelerators through a readiness timeout.
      fail_min: ([$d[] | select(.conclusion != "success")
                  | ((.updated_at | fromdateiso8601)
                     - (.run_started_at | fromdateiso8601)) / 60]
                 | if length == 0 then 0 else (add / length | floor) end),
      last_fail_id:  ([$d[] | select(.conclusion != "success")] | last | .id),
      last_fail_url: ([$d[] | select(.conclusion != "success")] | last | .html_url),
      status: $status,
      # Every later phase wants the same set, and each one that spelled the predicate out was
      # one edit away from selecting on .streak alone. A lane can be NO VERDICT and still
      # carry a nonzero streak — seven cancellations with one older failure among them — and
      # selecting on .streak pulls it into attribution, clustering and lifetime lookup, where
      # its stale failure is presented as the current one. Select on .red.
      red:      ($streak > 0 and $status != "NO VERDICT")
    }
]
| sort_by((.status | rank), -.streak, .lane)
