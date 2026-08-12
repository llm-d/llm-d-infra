# usage: awk -f successor.awk -v cur=<stems file> -v ran=<ran paths file> <gap-report.tsv>
# -> verdict \t lane \t proposed successor(s), for each REMOVED / STALE / NEVER RAN row.
#
# REMOVED almost always means renamed, not deleted. The anti-join in gaps.sh cannot see that:
# the old path stops appearing in runs, the new path is a different row that is running fine,
# and nothing links them. Reported raw, a single naming migration reads as a fleet of lost
# lanes.
#
# Match on token overlap rather than a prefix. Lanes moved to the -acc- convention both gained
# and dropped tokens — wide-ep-lws-gke became wide-ep-lws-gke-acc-gpu-vllm-x, but
# tiered-prefix-cache-cpu-offloading-gke became tiered-prefix-cache-gke-cpu-gpu-vllm-native,
# which shares no usable prefix.
#
# `cur` must already be filtered by $EXCLUDE_RE. Unfiltered, the consolidate-status-<lane>
# bookkeeping workflows shadow every real lane: each carries the whole lane name plus two
# tokens, so it wins the overlap and every row proposes a successor that tests nothing.

# nightly and e2e are in every lane name, so they are evidence of nothing.
function distinctive(w) { return w != "" && w != "nightly" && w != "e2e" }

function label(c, s, tot) {
  return c " (" s "/" tot ", " ((c in ranstem) ? "ran" : "no run in window") ")  "
}

BEGIN {
  FS = "\t"
  if (cur == "" || ran == "") { print "usage: -v cur=… -v ran=…" > "/dev/stderr"; exit 2 }
  while ((getline l < cur) > 0) {
    ncand++; name[ncand] = l
    n = split(l, a, "-")
    for (i = 1; i <= n; i++) if (distinctive(a[i])) ctok[ncand SUBSEP a[i]] = 1
  }
  close(cur)
  while ((getline l < ran) > 0) {
    sub(/^.*\//, "", l); sub(/\.ya?ml$/, "", l); ranstem[l] = 1
  }
  close(ran)
}

$1 != "REMOVED" && $1 != "STALE" && $1 != "NEVER RAN" { next }

{
  lane = $4; stem = lane; sub(/\.ya?ml$/, "", stem)
  delete t; total = 0
  n = split(stem, a, "-")
  for (i = 1; i <= n; i++)
    if (distinctive(a[i]) && !(a[i] in t)) { t[a[i]] = 1; total++ }

  # Two candidates, not one: the top score is often a tie and the tie-break is arbitrary. Token
  # overlap is blind to platform synonyms in particular — …-cpu-offloading-ocp scores equally
  # against the gke and the ibm lane, and ibm- is the OpenShift-GPU prefix, so the right answer
  # is the one the score cannot distinguish. Both rows get printed; read both.
  s1 = -1; s2 = -1; b1 = ""; b2 = ""
  for (c = 1; c <= ncand; c++) {
    if (name[c] == stem) continue
    sc = 0
    for (k in t) if ((c SUBSEP k) in ctok) sc++
    if (sc > s1)      { s2 = s1; b2 = b1; s1 = sc; b1 = name[c] }
    else if (sc > s2) { s2 = sc; b2 = name[c] }
  }

  # A majority of the old name's distinctive tokens, and never on one token alone — "gke" in
  # common is not evidence of anything.
  min = int((total + 1) / 2); if (min < 2) min = 2
  out = ""
  if (s1 >= min) out = out label(b1, s1, total)
  if (s2 >= min) out = out label(b2, s2, total)
  print $1 "\t" lane "\t" (out == "" ? "NO CANDIDATE — verify by hand" : out)
}
