#!/usr/bin/env bash
# check-upstream-releases.sh — Deterministic pre-check for upstream dependency changes.
# Parses docs/upstream-versions.md, checks each dependency for new releases via GitHub API,
# and outputs a JSON summary. Designed to run BEFORE the agentic workflow agent to avoid
# wasting tokens when nothing has changed.
#
# Exit codes:
#   0 = changes detected (changed_count > 0)
#   1 = no changes detected
#   2 = error (rate limit, parse failure, missing file)
#
# Output: /tmp/upstream-check-results.json

set -euo pipefail

# --- Constants ---
readonly VERSIONS_FILE="docs/upstream-versions.md"
readonly OUTPUT_FILE="/tmp/upstream-check-results.json"
readonly RESULTS_DIR="/tmp/upstream-dep-checks"
readonly MIN_EXPECTED_DEPS=10
readonly MAX_CONCURRENT=10
readonly RATE_LIMIT_THRESHOLD=60

# --- Helpers ---
log() { echo "[upstream-check] $*" >&2; }

# Strip markdown bold (**text**) and backtick formatting
strip_md() {
  echo "$1" | sed 's/\*\*//g' | sed 's/`//g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# Extract GitHub owner/repo from markdown link: [text](https://github.com/owner/repo)
# Returns the FIRST match found in the cell text
extract_github_repo() {
  echo "$1" | grep -oE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | head -1 | sed 's|github\.com/||'
}

# Check if a version string looks like a pre-release (alpha, beta, rc, dev)
is_prerelease() {
  local version="$1"
  # Match common pre-release patterns:
  # - PEP 440: 3.15.0a6, 3.15.0b2, 3.15.0rc1, 3.15.0.dev1
  # - Semver: v1.2.3-alpha, v1.2.3-beta.1, v1.2.3-rc.1
  # - Dev builds: nv_dev_xxx, dev_xxx
  # - Others: pre1, nightly, snapshot
  echo "$version" | grep -qiE '([0-9]a[0-9]|alpha|[0-9]b[0-9]|beta|\brc([._-]?[0-9]+)?\b|\.dev|^nv_dev|^dev_|pre[0-9]|-nightly|-snapshot)'
}

# Check if the current pin looks like a stable version (no pre-release markers)
is_stable_pin() {
  local pin="$1"
  ! is_prerelease "$pin"
}

# Strip a repo/chart name prefix from a tag for comparison.
# e.g., "llm-d-modelservice-v0.4.8" with repo "llm-d-modelservice" → "v0.4.8"
# e.g., "chart-name-1.2.3" with repo "chart-name" → "1.2.3"
strip_repo_prefix() {
  local tag="$1" repo="$2"
  # Extract the repo name (last path component)
  local repo_name="${repo##*/}"
  # Try stripping "reponame-" prefix from the tag
  if [[ "$tag" == "${repo_name}-"* ]]; then
    echo "${tag#"${repo_name}-"}"
  else
    echo "$tag"
  fi
}

# Fetch the latest STABLE release tag from a GitHub repo.
# Skips pre-releases, draft releases, and tags with dev/nightly patterns in their name.
# Falls back to /releases/latest if all else fails.
fetch_latest_stable_release() {
  local repo="$1"
  local tag=""
  # Fetch up to 30 recent releases
  local releases_json
  releases_json=$(gh api "repos/${repo}/releases?per_page=30" 2>/dev/null || echo "[]")
  # Find the first non-prerelease, non-draft release whose tag name also passes our name filter
  tag=$(echo "$releases_json" | jq -r '
    [.[] | select(.prerelease == false and .draft == false)][].tag_name
  ' 2>/dev/null || echo "")
  # Iterate candidates and pick the first that isn't a pre-release by name
  local candidate
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    [[ "$candidate" == "null" ]] && continue
    if ! is_prerelease "$candidate"; then
      tag="$candidate"
      break
    fi
    tag=""  # reset if all candidates are pre-releases
  done <<< "$tag"
  # Validate
  if [[ -z "$tag" ]] || [[ "$tag" == "null" ]] || [[ "$tag" == *"message"* ]] || [[ "$tag" == *"{"* ]]; then
    # Fallback to /releases/latest
    tag=$(gh api "repos/${repo}/releases/latest" --jq '.tag_name' 2>/dev/null || echo "")
    if [[ "$tag" == *"message"* ]] || [[ "$tag" == *"Not Found"* ]] || [[ "$tag" == *"{"* ]]; then
      tag=""
    fi
  fi
  echo "$tag"
}

# --- Rate Limit Check ---
check_rate_limit() {
  local remaining
  remaining=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || echo "0")
  if [ "$remaining" -lt "$RATE_LIMIT_THRESHOLD" ]; then
    log "ERROR: GitHub API rate limit too low: ${remaining} remaining (need ${RATE_LIMIT_THRESHOLD})"
    cat > "$OUTPUT_FILE" <<EOF
{"error":"GitHub API rate limit too low: ${remaining} remaining","check_timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","total_deps":0,"changed_count":0,"changes":[],"errors":["rate_limit_${remaining}"]}
EOF
    exit 2
  fi
  log "Rate limit OK: ${remaining} remaining"
}

# --- Parse upstream-versions.md ---
# Extracts rows from all markdown tables. Each row becomes a line:
#   name|current_pin|pin_type|file_location|upstream_repo
# pin_type is inferred from context if not in the table.
parse_versions_file() {
  if [ ! -f "$VERSIONS_FILE" ]; then
    log "ERROR: ${VERSIONS_FILE} not found"
    cat > "$OUTPUT_FILE" <<EOF
{"error":"${VERSIONS_FILE} not found","check_timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","total_deps":0,"changed_count":0,"changes":[],"errors":["missing_versions_file"]}
EOF
    exit 2
  fi

  local in_table=false
  local has_pin_type=false

  while IFS= read -r line; do
    # Skip empty lines and section headers
    [[ -z "$line" ]] && { in_table=false; continue; }
    [[ "$line" =~ ^#  ]] && { in_table=false; continue; }
    [[ "$line" =~ ^\> ]] && continue
    [[ "$line" =~ ^Pinned ]] && continue

    # Detect table header row
    if [[ "$line" =~ ^\|.*Dependency.*\| ]] || [[ "$line" =~ ^\|.*Variant.*\| ]]; then
      in_table=true
      has_pin_type=false
      [[ "$line" =~ "Pin Type" ]] && has_pin_type=true
      continue
    fi

    # Skip separator row
    [[ "$line" =~ ^\|[-[:space:]:]+\|$ ]] && continue
    [[ "$line" =~ ^\|[-[:space:]|]+$ ]] && continue

    # Parse data rows
    if $in_table && [[ "$line" =~ ^\| ]]; then
      # Split by | and trim
      local name current_pin pin_type file_loc upstream_cell

      # Remove leading/trailing pipes and split
      local trimmed
      trimmed=$(echo "$line" | sed 's/^|//;s/|$//')

      # Use awk to split by | (handles cells with spaces)
      name=$(echo "$trimmed" | awk -F'|' '{print $1}')
      current_pin=$(echo "$trimmed" | awk -F'|' '{print $2}')

      if $has_pin_type; then
        # 5-column table: name | pin | type | file | upstream
        pin_type=$(echo "$trimmed" | awk -F'|' '{print $3}')
        file_loc=$(echo "$trimmed" | awk -F'|' '{print $4}')
        upstream_cell=$(echo "$trimmed" | awk -F'|' '{print $5}')
      else
        # 4-column table: name | pin | file | upstream/notes
        pin_type="tag"  # default assumption
        file_loc=$(echo "$trimmed" | awk -F'|' '{print $3}')
        upstream_cell=$(echo "$trimmed" | awk -F'|' '{print $4}')
      fi

      name=$(strip_md "$name")
      current_pin=$(strip_md "$current_pin")
      pin_type=$(strip_md "$pin_type")
      file_loc=$(strip_md "$file_loc")

      # Extract GitHub repo from upstream cell
      local repo
      repo=$(extract_github_repo "$upstream_cell")

      # Skip rows with no GitHub repo (e.g., CUDA which links to nvidia.com)
      [ -z "$repo" ] && continue
      # Skip rows with "Notes" column that have no upstream repo
      [ -z "$name" ] && continue

      echo "${name}|${current_pin}|${pin_type}|${file_loc}|${repo}"
    fi
  done < "$VERSIONS_FILE"
}

# --- Check a single dependency ---
check_dependency() {
  local name="$1" current_pin="$2" pin_type="$3" file_loc="$4" repo="$5"
  local result_file="${RESULTS_DIR}/${name// /_}.json"
  local latest=""
  local changed=false
  local error=""
  local release_url=""

  # Helper to write a skipped result
  _write_skip() {
    jq -n \
      --arg name "$name" --arg upstream_repo "$repo" --arg pin_type "$pin_type" \
      --arg current_pin "$current_pin" --arg file_location "$file_loc" \
      '{name:$name, upstream_repo:$upstream_repo, pin_type:$pin_type,
        current_pin:$current_pin, latest_version:$current_pin,
        file_location:$file_location, release_url:"", changed:false, error:"", skipped:true}' \
      > "$result_file"
  }

  # Skip floating/unpinned/minimum-version dependencies — no drift to detect
  case "$pin_type" in
    "floating"*|"minimum version"|"minimum") _write_skip; return ;;
  esac
  case "$current_pin" in
    "auto"|"latest"|"stable"|"unpinned"|"main"|"master") _write_skip; return ;;
  esac
  if [[ "$current_pin" == ">="* ]] || [[ "$current_pin" == "~="* ]] || [[ "$current_pin" == "^"* ]]; then
    _write_skip; return
  fi

  case "$pin_type" in
    "commit SHA"|"commit")
      # Check how far behind the pinned SHA is
      local ahead_by
      ahead_by=$(gh api "repos/${repo}/compare/${current_pin}...HEAD" --jq '.ahead_by' 2>/dev/null || echo "error")
      if [ "$ahead_by" = "error" ] || [[ "$ahead_by" == *"message"* ]]; then
        error="Failed to compare SHA for ${repo}"
      elif [ "$ahead_by" -gt 0 ] 2>/dev/null; then
        # Also get the latest stable tag for display
        latest=$(fetch_latest_stable_release "$repo")
        if [ -z "$latest" ]; then
          latest="HEAD+${ahead_by}"
        fi
        release_url="https://github.com/${repo}/releases/latest"
        changed=true
      fi
      ;;

    "tag"|"version")
      # Fetch latest stable release (skips pre-releases and drafts)
      latest=$(fetch_latest_stable_release "$repo")
      if [ -z "$latest" ]; then
        # Fallback: check tags (some repos don't use GitHub Releases)
        if is_stable_pin "$current_pin"; then
          # Current pin is stable — scan tags for the first stable one
          local tag_candidate
          tag_candidate=$(gh api "repos/${repo}/tags?per_page=30" --jq '.[].name' 2>/dev/null || echo "")
          while IFS= read -r candidate; do
            [ -z "$candidate" ] && continue
            if ! is_prerelease "$candidate"; then
              latest="$candidate"
              break
            fi
          done <<< "$tag_candidate"
        else
          latest=$(gh api "repos/${repo}/tags?per_page=1" --jq '.[0].name' 2>/dev/null || echo "")
        fi
      fi
      if [ -z "$latest" ]; then
        error="Failed to fetch latest version for ${repo}"
      elif [ "$latest" != "$current_pin" ]; then
        # Strip repo-name prefix from tag (e.g., "llm-d-modelservice-v0.4.8" → "v0.4.8")
        local stripped_latest
        stripped_latest=$(strip_repo_prefix "$latest" "$repo")
        # Normalize: some pins don't have v prefix but releases do
        local normalized_pin="${current_pin#v}"
        local normalized_latest="${stripped_latest#v}"
        if [ "$normalized_latest" != "$normalized_pin" ]; then
          # Skip if current pin is stable but latest is a pre-release
          if is_stable_pin "$current_pin" && is_prerelease "$stripped_latest"; then
            : # Skip pre-release — not a real change for stable pins
          else
            release_url="https://github.com/${repo}/releases/tag/${latest}"
            changed=true
            # Use the stripped version for display if it differs
            if [ "$stripped_latest" != "$latest" ]; then
              latest="$stripped_latest"
            fi
          fi
        fi
      fi
      ;;

    "branch (fork)"|"branch")
      # For fork branches, the pin is a branch name like "llm-d-release-v0.5.1"
      # while upstream tags look like "v0.5.1". Extract version numbers from both
      # and compare normalized versions to avoid false positives every run.
      latest=$(fetch_latest_stable_release "$repo")
      if [ -n "$latest" ]; then
        local latest_version pin_version
        latest_version=$(echo "$latest" | grep -oE 'v?[0-9]+(\.[0-9]+)*' | head -1 || true)
        pin_version=$(echo "$current_pin" | grep -oE 'v?[0-9]+(\.[0-9]+)*' | head -1 || true)
        if [ -n "$latest_version" ] && [ -n "$pin_version" ]; then
          local norm_latest="${latest_version#v}"
          local norm_pin="${pin_version#v}"
          if [ "$norm_latest" != "$norm_pin" ]; then
            release_url="https://github.com/${repo}/releases/tag/${latest}"
            changed=true
          fi
        elif [ "$latest" != "$current_pin" ]; then
          # No version pattern found in branch name — fall back to raw comparison
          release_url="https://github.com/${repo}/releases/tag/${latest}"
          changed=true
        fi
      fi
      ;;

    *)
      # Unknown pin type — try tag check as fallback
      latest=$(fetch_latest_stable_release "$repo")
      if [ -n "$latest" ] && [ "$latest" != "$current_pin" ]; then
        local stripped_latest
        stripped_latest=$(strip_repo_prefix "$latest" "$repo")
        local normalized_pin="${current_pin#v}"
        local normalized_latest="${stripped_latest#v}"
        if [ "$normalized_latest" != "$normalized_pin" ]; then
          if is_stable_pin "$current_pin" && is_prerelease "$stripped_latest"; then
            : # Skip pre-release
          else
            release_url="https://github.com/${repo}/releases/tag/${latest}"
            changed=true
            if [ "$stripped_latest" != "$latest" ]; then
              latest="$stripped_latest"
            fi
          fi
        fi
      fi
      ;;
  esac

  # Write result JSON — use jq to guarantee valid JSON escaping
  jq -n \
    --arg name "$name" \
    --arg upstream_repo "$repo" \
    --arg pin_type "$pin_type" \
    --arg current_pin "$current_pin" \
    --arg latest_version "${latest:-${current_pin}}" \
    --arg file_location "$file_loc" \
    --arg release_url "$release_url" \
    --arg error "$error" \
    --argjson changed "$changed" \
    '{name:$name, upstream_repo:$upstream_repo, pin_type:$pin_type,
      current_pin:$current_pin, latest_version:$latest_version,
      file_location:$file_location, release_url:$release_url,
      changed:$changed, error:$error}' \
    > "$result_file"
}

# --- Main ---
main() {
  log "Starting upstream dependency check..."

  check_rate_limit

  # Parse dependencies
  local deps
  deps=$(parse_versions_file)
  local dep_count
  dep_count=$(echo "$deps" | grep -c '|' || true)

  if [ "$dep_count" -lt "$MIN_EXPECTED_DEPS" ]; then
    log "ERROR: Only parsed ${dep_count} dependencies (expected >= ${MIN_EXPECTED_DEPS}). Format may have changed."
    cat > "$OUTPUT_FILE" <<EOF
{"error":"Parsed only ${dep_count} deps (expected >= ${MIN_EXPECTED_DEPS})","check_timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","total_deps":${dep_count},"changed_count":0,"changes":[],"errors":["parse_undercount_${dep_count}"]}
EOF
    exit 2
  fi

  log "Parsed ${dep_count} dependencies"

  # Create temp directory for per-dep results
  rm -rf "$RESULTS_DIR"
  mkdir -p "$RESULTS_DIR"

  # Check all dependencies in parallel (up to MAX_CONCURRENT)
  local running=0
  while IFS='|' read -r name current_pin pin_type file_loc repo; do
    [ -z "$name" ] && continue
    log "Checking: ${name} (${repo}, pin=${current_pin})"
    check_dependency "$name" "$current_pin" "$pin_type" "$file_loc" "$repo" &
    running=$((running + 1))
    if [ "$running" -ge "$MAX_CONCURRENT" ]; then
      wait -n 2>/dev/null || true
      running=$((running - 1))
    fi
  done <<< "$deps"
  wait

  # Aggregate results using jq to merge all per-dep JSON files into one output
  local all_results
  all_results=$(jq -s '.' "${RESULTS_DIR}"/*.json 2>/dev/null || echo "[]")

  local changed_count error_count skipped_count
  changed_count=$(echo "$all_results" | jq '[.[] | select(.changed == true)] | length')
  error_count=$(echo "$all_results" | jq '[.[] | select(.error != "" and .error != null)] | length')
  skipped_count=$(echo "$all_results" | jq '[.[] | select(.skipped == true)] | length')

  # Write final output — valid JSON guaranteed by jq
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "$all_results" | jq --arg ts "$timestamp" --argjson total "$dep_count" '{
    check_timestamp: $ts,
    total_deps: $total,
    changed_count: ([.[] | select(.changed == true)] | length),
    unchanged_count: ($total - ([.[] | select(.changed == true)] | length) - ([.[] | select(.error != "" and .error != null)] | length) - ([.[] | select(.skipped == true)] | length)),
    skipped_count: ([.[] | select(.skipped == true)] | length),
    error_count: ([.[] | select(.error != "" and .error != null)] | length),
    changes: [.[] | select(.changed == true)],
    errors: [.[] | select(.error != "" and .error != null) | .error]
  }' > "$OUTPUT_FILE"

  log "Results: ${changed_count} changed, $((dep_count - changed_count - error_count - skipped_count)) unchanged, ${skipped_count} skipped, ${error_count} errors"
  log "Output written to ${OUTPUT_FILE}"

  # Cleanup
  rm -rf "$RESULTS_DIR"

  if [ "$changed_count" -gt 0 ]; then
    exit 0  # Changes detected
  else
    exit 1  # No changes
  fi
}

main "$@"
