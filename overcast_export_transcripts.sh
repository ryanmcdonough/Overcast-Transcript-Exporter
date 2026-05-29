#!/usr/bin/env bash
set -euo pipefail

OUT_DEFAULT="$HOME/Desktop/overcast_transcripts_named"
CURL_MAX_TIME_DEFAULT=60
CURL_RETRIES_DEFAULT=3

find_overcast_db() {
  local db
  for db in "$HOME"/Library/Containers/*/Data/Documents/db.sqlite; do
    [[ -f "$db" ]] || continue
    local container_root
    container_root="$(dirname "$(dirname "$db")")"
    if [[ -f "$container_root/Library/Preferences/fm.overcast.overcast.plist" ]]; then
      printf '%s\n' "$db"
      return 0
    fi
  done
  return 1
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_bool01() { [[ "$1" == "0" || "$1" == "1" ]]; }

sanitize_filename_part() {
  local s="$1"
  s="$(printf '%s' "$s" | tr '/:' '-' | sed 's/[[:cntrl:]]//g; s/[[:space:]]\+/ /g; s/^ *//; s/ *$//')"
  s="$(printf '%s' "$s" | tr -d '"<>|?*')"
  if [[ -z "$s" || "$s" == "." || "$s" == ".." ]]; then s="untitled"; fi
  printf '%s' "$s"
}

decode_generated_blob_to_text() {
  local episode_id="$1"
  local out_file="$2"
  local tmp_blob
  tmp_blob="$(mktemp "/tmp/oc_generated_${episode_id}.XXXX.bin")"

  sqlite3 -readonly "$DB" "SELECT writefile('$tmp_blob', generatedTranscriptData) FROM OCEpisode WHERE id=${episode_id} AND length(generatedTranscriptData)>0;" >/dev/null

  if [[ ! -s "$tmp_blob" ]]; then
    rm -f "$tmp_blob"
    return 1
  fi

  if python3 - "$tmp_blob" "$out_file" <<'PY'
import json
import re
import sys
import zlib

blob_path, out_path = sys.argv[1], sys.argv[2]
raw = open(blob_path, "rb").read()
payload = zlib.decompress(raw, -15)

obj = json.loads(payload.decode("utf-8"))
segments = obj.get("t", []) if isinstance(obj, dict) else []

lines = []
for seg in segments:
    if not isinstance(seg, dict):
        continue
    words = seg.get("w", [])
    if not isinstance(words, list):
        continue
    cleaned = []
    for tok in words:
        if not isinstance(tok, str) or not tok:
            continue
        # Overcast stores a one-char token prefix before visible text.
        cleaned.append(tok[1:] if len(tok) > 1 else "")
    line = "".join(cleaned).strip()
    if line:
        lines.append(line)

if not lines:
    text = payload.decode("utf-8", errors="ignore").strip()
else:
    text = "\n".join(lines).strip()

text = re.sub(r"\n{3,}", "\n\n", text)

with open(out_path, "w", encoding="utf-8") as f:
    f.write(text + "\n")
PY
  then
    rm -f "$tmp_blob"
    return 0
  fi

  rm -f "$tmp_blob"
  return 1
}

decode_external_blob_to_text() {
  local episode_id="$1"
  local out_file="$2"
  local tmp_blob
  tmp_blob="$(mktemp "/tmp/oc_external_${episode_id}.XXXX.bin")"

  sqlite3 -readonly "$DB" "SELECT writefile('$tmp_blob', externalTranscriptData) FROM OCEpisode WHERE id=${episode_id} AND length(externalTranscriptData)>0;" >/dev/null

  if [[ ! -s "$tmp_blob" ]]; then
    rm -f "$tmp_blob"
    return 1
  fi

  if python3 - "$tmp_blob" "$out_file" <<'PY'
import re
import sys
import zlib

blob_path, out_path = sys.argv[1], sys.argv[2]
raw = open(blob_path, "rb").read()
payload = zlib.decompress(raw, -15)
text = payload.decode("utf-8", errors="ignore")

# If this is SRT, strip cue indices/timestamps into plain transcript text.
lines = []
for line in text.splitlines():
    s = line.strip()
    if not s:
        lines.append("")
        continue
    if re.fullmatch(r"\d+", s):
        continue
    if "-->" in s:
        continue
    lines.append(s)

collapsed = []
prev_blank = True
for line in lines:
    if line == "":
        if not prev_blank:
            collapsed.append(line)
        prev_blank = True
    else:
        collapsed.append(line)
        prev_blank = False

out = "\n".join(collapsed).strip()
with open(out_path, "w", encoding="utf-8") as f:
    f.write(out + "\n")
PY
  then
    rm -f "$tmp_blob"
    return 0
  fi

  rm -f "$tmp_blob"
  return 1
}

DB_DEFAULT="$(find_overcast_db || true)"
DB="${DB:-${DB_DEFAULT:-}}"
OUT="${OUT:-$OUT_DEFAULT}"
DAYS="${DAYS:-14}"
MAX="${MAX:-0}"                        # 0 means no limit
INCLUDE_DELETED="${INCLUDE_DELETED:-1}"
ON_DEVICE_ONLY="${ON_DEVICE_ONLY:-1}"  # default: only downloaded episodes
SKIP_EXISTING="${SKIP_EXISTING:-1}"
DRY_RUN="${DRY_RUN:-0}"
CURL_MAX_TIME="${CURL_MAX_TIME:-$CURL_MAX_TIME_DEFAULT}"
CURL_RETRIES="${CURL_RETRIES:-$CURL_RETRIES_DEFAULT}"
USE_DEVICE_BLOBS="${USE_DEVICE_BLOBS:-1}"
ALLOW_URL_FALLBACK="${ALLOW_URL_FALLBACK:-1}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --days N
  --max N                    (0 = no limit)
  --out PATH
  --db PATH
  --include-deleted 0|1
  --on-device-only 0|1
  --skip-existing 0|1
  --dry-run 0|1
  --use-device-blobs 0|1
  --allow-url-fallback 0|1
  --curl-max-time N
  --curl-retries N
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="${2:-}"; shift 2 ;;
    --max) MAX="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --db) DB="${2:-}"; shift 2 ;;
    --include-deleted) INCLUDE_DELETED="${2:-}"; shift 2 ;;
    --on-device-only) ON_DEVICE_ONLY="${2:-}"; shift 2 ;;
    --skip-existing) SKIP_EXISTING="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="${2:-}"; shift 2 ;;
    --use-device-blobs) USE_DEVICE_BLOBS="${2:-}"; shift 2 ;;
    --allow-url-fallback) ALLOW_URL_FALLBACK="${2:-}"; shift 2 ;;
    --curl-max-time) CURL_MAX_TIME="${2:-}"; shift 2 ;;
    --curl-retries) CURL_RETRIES="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

[[ -n "$DB" && -f "$DB" ]] || { echo "DB missing. Use --db /full/path/db.sqlite" >&2; exit 1; }
is_uint "$DAYS" || { echo "Invalid DAYS=$DAYS" >&2; exit 1; }
is_uint "$MAX" || { echo "Invalid MAX=$MAX" >&2; exit 1; }
is_uint "$CURL_MAX_TIME" || { echo "Invalid CURL_MAX_TIME=$CURL_MAX_TIME" >&2; exit 1; }
is_uint "$CURL_RETRIES" || { echo "Invalid CURL_RETRIES=$CURL_RETRIES" >&2; exit 1; }
is_bool01 "$INCLUDE_DELETED" || { echo "Invalid INCLUDE_DELETED=$INCLUDE_DELETED" >&2; exit 1; }
is_bool01 "$ON_DEVICE_ONLY" || { echo "Invalid ON_DEVICE_ONLY=$ON_DEVICE_ONLY" >&2; exit 1; }
is_bool01 "$SKIP_EXISTING" || { echo "Invalid SKIP_EXISTING=$SKIP_EXISTING" >&2; exit 1; }
is_bool01 "$DRY_RUN" || { echo "Invalid DRY_RUN=$DRY_RUN" >&2; exit 1; }
is_bool01 "$USE_DEVICE_BLOBS" || { echo "Invalid USE_DEVICE_BLOBS=$USE_DEVICE_BLOBS" >&2; exit 1; }
is_bool01 "$ALLOW_URL_FALLBACK" || { echo "Invalid ALLOW_URL_FALLBACK=$ALLOW_URL_FALLBACK" >&2; exit 1; }

mkdir -p "$OUT"

DELETED_FILTER=""
[[ "$INCLUDE_DELETED" -eq 0 ]] && DELETED_FILTER="AND e.userDeleted = 0"

DEVICE_FILTER=""
[[ "$ON_DEVICE_ONLY" -eq 1 ]] && DEVICE_FILTER="AND e.downloadState = 1"

LIMIT_CLAUSE=""
[[ "$MAX" -gt 0 ]] && LIMIT_CLAUSE="LIMIT ${MAX}"

echo "Config: DAYS=$DAYS MAX=$MAX ON_DEVICE_ONLY=$ON_DEVICE_ONLY DRY_RUN=$DRY_RUN USE_DEVICE_BLOBS=$USE_DEVICE_BLOBS URL_FALLBACK=$ALLOW_URL_FALLBACK"
echo "DB: $DB"
echo "OUT: $OUT"

considered=0
blob_generated=0
blob_external=0
url_downloaded=0
skipped=0
failed=0
SEP=$'\x1f'

while IFS="$SEP" read -r episode_id podcast_title episode_title pub_date transcript_url generated_len external_len; do
  considered=$((considered + 1))

  safe_podcast="$(sanitize_filename_part "$podcast_title")"
  safe_episode="$(sanitize_filename_part "$episode_title")"
  safe_podcast="${safe_podcast:0:80}"
  safe_episode="${safe_episode:0:120}"
  out_file="$OUT/${safe_podcast} - ${safe_episode} - ${pub_date} [${episode_id}].txt"

  if [[ "$SKIP_EXISTING" -eq 1 && -f "$out_file" ]]; then
    echo "Skip existing: $out_file"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ "$USE_DEVICE_BLOBS" -eq 1 && "$generated_len" -gt 0 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "Would decode generated transcript blob: $out_file"
      continue
    fi
    if decode_generated_blob_to_text "$episode_id" "$out_file"; then
      echo "Decoded generated transcript blob: $out_file"
      blob_generated=$((blob_generated + 1))
      continue
    fi
    echo "Failed generated blob decode: $episode_id"
  fi

  if [[ "$USE_DEVICE_BLOBS" -eq 1 && "$external_len" -gt 0 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "Would decode external transcript blob: $out_file"
      continue
    fi
    if decode_external_blob_to_text "$episode_id" "$out_file"; then
      echo "Decoded external transcript blob: $out_file"
      blob_external=$((blob_external + 1))
      continue
    fi
    echo "Failed external blob decode: $episode_id"
  fi

  if [[ "$ALLOW_URL_FALLBACK" -eq 1 && -n "$transcript_url" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "Would download URL transcript: $out_file"
      continue
    fi
    tmp_file="${out_file}.part"
    if curl -L --fail --silent --show-error --max-time "$CURL_MAX_TIME" --retry "$CURL_RETRIES" --retry-delay 1 --retry-all-errors "$transcript_url" -o "$tmp_file"; then
      mv -f "$tmp_file" "$out_file"
      echo "Downloaded URL transcript: $out_file"
      url_downloaded=$((url_downloaded + 1))
      continue
    fi
    rm -f "$tmp_file"
    echo "Failed URL transcript: $episode_id"
  fi

  echo "No transcript source available: $episode_id"
  failed=$((failed + 1))
done < <(
  sqlite3 -separator "$SEP" "$DB" "
  SELECT
    e.id,
    p.title,
    e.title,
    strftime('%Y-%m-%d', e.publishedTime, 'unixepoch'),
    COALESCE(e.transcriptURL, ''),
    COALESCE(length(e.generatedTranscriptData), 0),
    COALESCE(length(e.externalTranscriptData), 0)
  FROM OCEpisode e
  JOIN OCPodcast p ON p.id = e.podcastID
  WHERE p.userSubscribed = 1
    AND e.noLongerInFeed = 0
    ${DELETED_FILTER}
    ${DEVICE_FILTER}
    AND e.publishedTime >= strftime('%s','now','-${DAYS} days')
  ORDER BY e.publishedTime DESC
  ${LIMIT_CLAUSE};
  "
)

echo "Done. Considered=$considered BlobGenerated=$blob_generated BlobExternal=$blob_external URLDownloaded=$url_downloaded Skipped=$skipped Failed=$failed"
