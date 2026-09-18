# usage: awk -f bench-steps.awk -v out=<category tsv> reusable-ci-nightly-benchmark.yaml | sort
#
# One pass over the benchmark workflow, producing both things Phase 3c needs:
#   $out    <category>\t<step name>, for every step whose id carries a category prefix
#   stdout  step ids that can fail *without* setting a category
#
# The pipeline classifies its own failures — do not invent a taxonomy and do not map step names
# to one by hand. reusable-ci-nightly-benchmark.yaml assigns every run a failure_category of
# prepare, prereqs, infra, guide or benchmark, chosen by which step id failed, and the step ids
# carry the category as a prefix. Deriving the map from the source keeps it correct as steps
# are renamed, added and removed.
#
# The second output exists because the two disagree on a known set of steps. The map is derived
# from id prefixes, but `detect_failure` tests an explicit elif list, and that list is a subset
# of the steps carrying a prefix. If a step outside it fails, the pipeline emits an empty
# category and the badge reads a bare `failing` while the map here assigns one from the prefix.
# An unexplained `failing` badge against a populated row is that gap rather than a miscount.

BEGIN { if (out == "") { bad = 1; print "usage: -v out=<file>" > "/dev/stderr"; exit 2 } }

# Step entries sit at six spaces. Nested `- name:` keys inside `with:` and the matrix sit deeper
# and are not steps, so the match has to anchor on the indent. The END guard below fires if a
# reformat ever breaks that assumption.
/^      - name:/ { n = $0; sub(/^ *- name: */, "", n); nname++; indetect = 0 }

# `id:` needs no indent anchor: every id in the file is a step id, and the prefix test below
# discards anything whose first token is not a category.
/^[[:space:]]+id: / {
  id = $2; allid[id] = 1; nid++
  if (id ~ /^detect_/) indetect = 1
  split(id, a, "_"); c = a[1]
  sub(/^prereq$/, "prereqs", c)          # both prereq_ and prereqs_ land on prereqs
  if (c ~ /^(prepare|prereqs|infra|guide|benchmark)$/) { print c "\t" n > out; ncat++ }
}

# Everything from the detect_ step to the next step entry is the elif chain. The class is
# [a-z0-9_], not [a-z_]: the grep this replaced stopped at the first digit, so
# prepare_skip_tpu_v7_run was compared as `prepare_skip_tpu_v` on both sides and reported under
# a step id that does not exist.
indetect {
  s = $0
  while (match(s, /steps\.[a-z0-9_]+\./)) {
    elif[substr(s, RSTART + 6, RLENGTH - 7)] = 1
    s = substr(s, RSTART + RLENGTH)
  }
}

END {
  if (bad) exit 2
  if (nid + 0 == 0 || ncat + 0 == 0)
    print "!! parsed " nid + 0 " ids and " nname + 0 " step names but mapped " ncat + 0 \
          " — check the indentation assumptions against the file" > "/dev/stderr"
  for (i in allid) if (!(i in elif) && i != "detect_failure") print i
}
