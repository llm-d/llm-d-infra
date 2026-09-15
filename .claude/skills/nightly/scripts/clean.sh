# usage: … | sh clean.sh — strips ANSI sequences and the runner's timestamp column
# The class is [a-zA-Z], not [m]. A colour code is m-terminated, but the smoketest progress
# ticker redraws with ESC[2K (erase line), and a sed that only removes colour leaves `[2K`
# embedded in the text — where it has to be filtered by name in every consumer, and was, in
# three places that each had to be kept in step. Terminating on any final byte removes both.
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | cut -c30-
