# Overcast Transcript Exporter

Exports transcript text files from Overcast on macOS.

## Workaround implemented

Overcast TestFlight transcript content is available on-device in SQLite blobs:

- `OCEpisode.generatedTranscriptData`
- `OCEpisode.externalTranscriptData`

These blobs are raw DEFLATE payloads. This exporter now decodes them directly, so you can extract transcript text even when `transcriptURL` is empty.

## Default behavior

By default, the script does this:

- subscribed podcasts only
- episodes still in feed only
- on-device downloaded episodes only (`downloadState = 1`)
- last 14 days
- no hard max (`MAX=0` means unlimited)
- skip existing files
- decode on-device blobs first
- fallback to `transcriptURL` only if blob decode is unavailable

## Run

```bash
cd /Users/ryanmcdonough/Desktop/overcast-transcript-exporter
./overcast_export_transcripts.sh
```

## Useful options

- `--days N`
- `--max N` (`0` = no limit)
- `--on-device-only 0|1`
- `--include-deleted 0|1`
- `--skip-existing 0|1`
- `--dry-run 0|1`
- `--use-device-blobs 0|1`
- `--allow-url-fallback 0|1`
- `--db PATH`
- `--out PATH`

## Notes

- Filename format: `Podcast - Episode - YYYY-MM-DD [episodeID].txt`
- If no blob and no usable URL, episode is reported as unavailable.
