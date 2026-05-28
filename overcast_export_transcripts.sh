#!/usr/bin/env bash
set -euo pipefail

OUT_DEFAULT="$HOME/Desktop/overcast_transcripts_named"
CURL_MAX_TIME_DEFAULT=60
CURL_RETRIES_DEFAULT=3

find_overcast_db() {
  local db
  for db in "$HOME"/Library/Containers/*/Data/Documents/db.sqlite; do
    [[ -f "$db" ]] || continue

    # Confirm this container is Overcast by checking its preferences plist.
    local container_root
    container_root="$(dirname "$(dirname "$db")")"
    if [[ -f "$container_root/Library/Preferences/fm.overcast.overcast.plist" ]]; then
      printf '%s\n' "$db"
      return 0
    fi
  done
  return 1
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_bool01() {
  [[ "$1" == "0" || "$1" == "1" ]]
}

sanitize_filename_part() {
  local s="$1"
  # Normalize whitespace and remove control chars.
  s="$(printf '%s' "$s" | tr '/:' '-' | sed 's/[[:cntrl:]]//g; s/[[:space:]]\+/ /g; s/^ *//; s/ *$//')"
  # Remove extra filesystem-hostile characters.
  s="$(printf '%s' "$s" | tr -d '"<>|?*')"
  # Avoid hidden/empty names.
  if [[ -z "$s" || "$s" == "." || "$s" == ".." ]]; then
    s="untitled"
  fi
  printf '%s' "$s"
}

DB_DEFAULT="$(find_overcast_db || true)"

# Config (override with env vars or flags below)
DB="${DB:-${DB_DEFAULT:-}}"
OUT="${OUT:-$OUT_DEFAULT}"
DAYS="${DAYS:-14}"                            # lookback window in days
MAX="${MAX:-20}"                              # max episodes to process
INCLUDE_DELETED="${INCLUDE_DELETED:-1}"       # 1 include locally deleted, 0 exclude
SKIP_EXISTING="${SKIP_EXISTING:-1}"           # 1 skip existing files, 0 re-download
DRY_RUN="${DRY_RUN:-0}"                       # 1 print actions only
CURL_MAX_TIME="${CURL_MAX_TIME:-$CURL_MAX_TIME_DEFAULT}"  # seconds per download
CURL_RETRIES="${CURL_RETRIES:-$CURL_RETRIES_DEFAULT}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --days N               Look back N days (default: $DAYS)
  --max N                Max episodes to process (default: $MAX)
  --out PATH             Output folder (default: $OUT)
  --db PATH              Overcast DB path (auto-detected by default)
  --include-deleted 0|1  Include locally deleted episodes (default: $INCLUDE_DELETED)
  --skip-existing 0|1    Skip files that already exist (default: $SKIP_EXISTING)
  --dry-run 0|1          Show what would happen, no downloads (default: $DRY_RUN)
  --curl-max-time N      Per-file timeout in seconds (default: $CURL_MAX_TIME)
  --curl-retries N       Retry count for transient failures (default: $CURL_RETRIES)
  -h, --help             Show this help

Env var overrides also supported:
  DB, OUT, DAYS, MAX, INCLUDE_DELETED, SKIP_EXISTING, DRY_RUN, CURL_MAX_TIME, CURL_RETRIES
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="${2:-}"; shift 2 ;;
    --max) MAX="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --db) DB="${2:-}"; shift 2 ;;
    --include-deleted) INCLUDE_DELETED="${2:-}"; shift 2 ;;
    --skip-existing) SKIP_EXISTING="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="${2:-}"; shift 2 ;;
    --curl-max-time) CURL_MAX_TIME="${2:-}"; shift 2 ;;
    --curl-retries) CURL_RETRIES="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$DB" ]]; then
  echo "Could not auto-detect Overcast DB. Pass --db /full/path/to/db.sqlite" >&2
  exit 1
fi

if [[ ! -f "$DB" ]]; then
  echo "DB not found: $DB" >&2
  exit 1
fi

if ! is_uint "$DAYS"; then
  echo "Invalid DAYS='$DAYS' (expected unsigned integer)." >&2
  exit 1
fi
if ! is_uint "$MAX"; then
  echo "Invalid MAX='$MAX' (expected unsigned integer)." >&2
  exit 1
fi
if ! is_uint "$CURL_MAX_TIME" || [[ "$CURL_MAX_TIME" -eq 0 ]]; then
  echo "Invalid CURL_MAX_TIME='$CURL_MAX_TIME' (expected integer > 0)." >&2
  exit 1
fi
if ! is_uint "$CURL_RETRIES"; then
  echo "Invalid CURL_RETRIES='$CURL_RETRIES' (expected unsigned integer)." >&2
  exit 1
fi
if ! is_bool01 "$INCLUDE_DELETED"; then
  echo "Invalid INCLUDE_DELETED='$INCLUDE_DELETED' (expected 0 or 1)." >&2
  exit 1
fi
if ! is_bool01 "$SKIP_EXISTING"; then
  echo "Invalid SKIP_EXISTING='$SKIP_EXISTING' (expected 0 or 1)." >&2
  exit 1
fi
if ! is_bool01 "$DRY_RUN"; then
  echo "Invalid DRY_RUN='$DRY_RUN' (expected 0 or 1)." >&2
  exit 1
fi

mkdir -p "$OUT"

DELETED_FILTER=""
if [[ "$INCLUDE_DELETED" -eq 0 ]]; then
  DELETED_FILTER="AND e.userDeleted = 0"
fi

echo "Config: DAYS=$DAYS MAX=$MAX INCLUDE_DELETED=$INCLUDE_DELETED SKIP_EXISTING=$SKIP_EXISTING DRY_RUN=$DRY_RUN CURL_MAX_TIME=$CURL_MAX_TIME CURL_RETRIES=$CURL_RETRIES"
echo "DB: $DB"
echo "OUT: $OUT"

downloaded=0
skipped=0
failed=0
considered=0

while IFS=$'\t' read -r episode_id podcast_title episode_title pub_date transcript_url; do
  [[ -z "$transcript_url" ]] && continue
  considered=$((considered + 1))

  safe_podcast="$(sanitize_filename_part "$podcast_title")"
  safe_episode="$(sanitize_filename_part "$episode_title")"

  safe_podcast="${safe_podcast:0:80}"
  safe_episode="${safe_episode:0:120}"

  # Include episode ID to avoid collisions.
  file="$OUT/${safe_podcast} - ${safe_episode} - ${pub_date} [${episode_id}].txt"

  if [[ "$SKIP_EXISTING" -eq 1 && -f "$file" ]]; then
    echo "Skip existing: $file"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Would download: $file"
    continue
  fi

  tmp_file="${file}.part"
  echo "Downloading: $file"
  if curl -L --fail --silent --show-error --max-time "$CURL_MAX_TIME" --retry "$CURL_RETRIES" --retry-delay 1 --retry-all-errors "$transcript_url" -o "$tmp_file"; then
    mv -f "$tmp_file" "$file"
    downloaded=$((downloaded + 1))
  else
    rm -f "$tmp_file"
    echo "Failed: $episode_id"
    failed=$((failed + 1))
  fi
done < <(
  sqlite3 -separator $'\t' "$DB" "
  SELECT
    e.id,
    p.title,
    e.title,
    strftime('%Y-%m-%d', e.publishedTime, 'unixepoch'),
    e.transcriptURL
  FROM OCEpisode e
  JOIN OCPodcast p ON p.id = e.podcastID
  WHERE e.transcriptURL IS NOT NULL
    AND p.userSubscribed = 1
    AND e.noLongerInFeed = 0
    ${DELETED_FILTER}
    AND e.publishedTime >= strftime('%s','now','-${DAYS} days')
  ORDER BY e.publishedTime DESC
  LIMIT ${MAX};
  "
)

echo "Done. Considered=$considered Downloaded=$downloaded Skipped=$skipped Failed=$failed"
echo "Files in: $OUT"
