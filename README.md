# Overcast Transcript Exporter

Exports transcript text files for episodes in your current Overcast feed (macOS app DB), with configurable date window, limits, and file deduping.

## Files

- `overcast_export_transcripts.sh` - main export script
- `.env.example` - optional config file template

## How DB detection works

- The script auto-detects your Overcast `db.sqlite` by scanning `~/Library/Containers/*/Data/Documents/db.sqlite`.
- It verifies the matching container by checking for `Library/Preferences/fm.overcast.overcast.plist`.
- This is fast local filesystem work and usually completes in a moment.
- You can always override with `--db` or `DB=...`.

## Quick start

```bash
cd /Users/ryanmcdonough/Desktop/overcast-transcript-exporter
bash ./overcast_export_transcripts.sh
```

## Configure via flags

```bash
bash ./overcast_export_transcripts.sh --days 7 --max 50 --skip-existing 1
```

## Configure via environment variables

```bash
export DAYS=7
export MAX=50
export SKIP_EXISTING=1
bash ./overcast_export_transcripts.sh
```

## Optional: use a local .env file

```bash
cd /Users/ryanmcdonough/Desktop/overcast-transcript-exporter
cp .env.example .env
# edit values in .env
set -a; source ./.env; set +a
bash ./overcast_export_transcripts.sh
```

## Helpful options

- `--days N` look back N days
- `--max N` max number of episodes
- `--include-deleted 0|1` include/exclude locally deleted episodes
- `--skip-existing 0|1` skip already-downloaded transcript files
- `--dry-run 0|1` preview without downloading
- `--curl-max-time N` per-file timeout (seconds)
- `--curl-retries N` retries on transient download errors
- `--out PATH` output folder override
- `--db PATH` database path override

## Hardening notes

- Validates all numeric/boolean config values before execution.
- Uses atomic writes (`.part` then move) to avoid partial output files.
- Includes episode ID in filename to avoid collisions between similarly titled episodes.
- Supports configurable retry/timeout behavior for network reliability.

## Notes

- Script only exports episodes with a non-null `transcriptURL`.
- Output files are named: `Podcast - Episode - YYYY-MM-DD [episodeID].txt`.
