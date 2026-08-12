# usage: jq --slurpfile sf $LOG_DIR/steps.json '$sf[0] as $steps | '"$(cat cluster.jq)" lanes.json
#
# Grouping on the failed step alone over-merges: Standup and Run each name a whole phase of the
# reusable workflow, so unrelated causes collect under one name. Group by step *and* by when
# each lane broke.
#
# Greedy sweep over lanes sorted by streak: extend a cluster while the next lane broke within
# 2 runs of the cluster's start, otherwise begin a new cluster.
def cluster:
  sort_by(.streak)
  | reduce .[] as $l ([];
      if (length > 0) and (($l.streak - .[-1][0].streak) <= 2)
      then .[0:-1] + [ .[-1] + [$l] ]
      else . + [ [$l] ] end);

$steps as $s
| [ .[] | select(.red)
    | . + {step: ($s[(.last_fail_id | tostring)] // "(unknown)")} ]
| group_by(.step) | map(cluster) | (add // [])   # add on [] is null; an all-green week is valid
| map(select(length >= 2))
| sort_by(-length)
| map({ step:        .[0].step,
        lanes:       length,
        incident:    (length >= 3),   # 3+ lanes breaking together: investigate once
        # Dates rather than "N runs ago". If the members share one date it is a single event;
        # if they are staggered, suspect a fault carried in state rather than a change landing.
        broke_on:    ([.[].broke_on] | unique | sort),
        # URLs, because confirming a cluster takes two members on error text, not step name.
        members:     [.[] | {lane, url: .last_fail_url}] })
