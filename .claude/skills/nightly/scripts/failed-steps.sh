# usage: printf '<owner/repo>\t<run_id>\n' … | sh failed-steps.sh   ->  <run_id>\t<step name>
# One row per input run, always: a run whose jobs API says nothing still needs a row, or the
# join back onto the lane table drops the lane silently.
: "${LOG_DIR:?export LOG_DIR before calling this script}"
: "${NS:?export NS to this scripts directory before calling this script}"
export NS LOG_DIR
xargs -P 8 -n 2 sh -c '
    step=$(sh "$NS/jobmeta.sh" "$0" "$1" 2>/dev/null | cut -f4)
    printf "%s\t%s\n" "$1" "${step:-(jobs unavailable)}"'
