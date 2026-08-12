# usage: sh pull.sh <failures-tsv>   (fields 1, 2 and 5 are repo, run id, lane name)
# Writes one $LOG_DIR/err-<run>.txt per row, then concatenates them into $LOG_DIR/errtext.out.
#
# xargs cannot drive this: lane names contain spaces, so -n splits mid-name and the run ids
# pair with the wrong repos. Bounded background loop instead, 6 at a time.
tsv=$1
: "${LOG_DIR:?export LOG_DIR before calling this script}"
: "${NS:?export NS to this scripts directory before calling this script}"
[ -s "$tsv" ] || { : > "$LOG_DIR/errtext.out"; exit 0; }

n=0
# A literal tab in IFS, not \t — read takes the characters literally.
while IFS='	' read -r repo id concl day name wf; do
  ( out=$(sh "$NS/errtext.sh" "$repo" "$id" 2>&1 | tail -40)
    printf '########## %s | %s | %s\n%s\n\n' "$name" "$repo" "$id" "$out" \
      > "$LOG_DIR/err-$id.txt" ) &
  n=$((n+1)); [ $((n % 6)) -eq 0 ] && wait
done < "$tsv"
wait

# Assembled from the TSV, not from `cat $LOG_DIR/err-*.txt`. The glob cannot tell this window's
# bodies from a previous pass's, so a stale $LOG_DIR silently pads the analysis with lanes that
# did not fail — 60 files for 26 lanes on one run, two-thirds carried over. $LOG_DIR is now
# date-scoped, which closes that across days; driving off the TSV also closes it within one.
: > "$LOG_DIR/errtext.out"
cut -f2 "$tsv" | while read -r id; do cat "$LOG_DIR/err-$id.txt"; done >> "$LOG_DIR/errtext.out"

echo "$(grep -c '^## NO CAUSE IN WINDOW' "$LOG_DIR/errtext.out" | tr -d ' ') of \
$(wc -l < "$tsv" | tr -d ' ') bodies named no cause in the step window and fell back to errsig.sh"
