# voicememos — Voice Memos

Browse and search your Voice Memos recordings, export their `.m4a` audio, and
produce on-device transcripts. Read-only: it reads the app's metadata store and
audio files but never records, edits, or deletes anything in Voice Memos.

**Access:** read
**Permissions:** Full Disk Access (to read Voice Memos' on-disk store and audio
under `~/Library/Group Containers/…`). `transcribe` additionally needs Speech
Recognition and **macOS 26+** (on-device `SpeechTranscriber`); on older systems
`transcribe` errors out while the other actions still work.

## Actions

- **list** — recent recordings, newest first. Defaults to the **last 30 days**;
  pass `--all` for the full history. Optional `--folder`, `--start-date` /
  `--end-date`, `--limit`.
- **search** — filter the **full** history by title substring (`--query`),
  `--folder`, and/or date range. No default window — the filters are the scope.
- **export** — copy a recording's `.m4a` into the output dir and return its
  path (by `--id` from list/search). `--with-waveform` also exports the
  `.waveform` sidecar if present.
- **transcribe** — on-device transcript of a recording (by `--id`). Writes a
  `.txt` to the output dir and returns its path plus a short preview; results
  are cached per recording (`--refresh` to re-transcribe). `--inline` returns
  the full text in the response instead of only the preview; `--timestamps`
  also writes a `.json` sidecar of per-segment `{start,end,text}` ranges;
  `--locale` sets the BCP-47 speech model (default `en-US`).

Run `apple-tools voicememos --help` for the exact parameters of each action.

## Examples

```bash
apple-tools voicememos list --all --folder "Tours"
apple-tools voicememos search --query "senior living" --start-date 2026-01-01
apple-tools voicememos export --id "<RECORDING-ID>" --with-waveform
apple-tools voicememos transcribe --id "<RECORDING-ID>" --timestamps --inline
```

## Shortcomings

- **Read-only — no create/edit/delete.** The metadata store is Voice Memos'
  own Core Data + CloudKit-sync SQLite DB, opened strictly
  `SQLITE_OPEN_READONLY` (writing "could corrupt it or conflict with sync").
  So there's no way to record a new memo, rename, retitle, move between
  folders, trim, or delete — all mutation happens only in the Voice Memos app.
- **`list` hides older recordings by default.** With no date bounds and no
  `--all`, `list` silently applies a 30-day window (`defaultWindowDays = 30`)
  to keep output short; the response flags this with a `window`/`note` field.
  Use `--all` or an explicit date range to reach anything older. `search` has
  no such window.
- **Cloud-only recordings can't be exported or transcribed.** A recording is
  `available` only if its `.m4a` exists locally; evicted/cloud-only memos yield
  "not downloaded locally … Open it in Voice Memos to download it first." The
  tool can list their metadata but cannot fetch the audio itself.
- **Transcription is macOS-26-only and on-device.** `transcribe` requires
  macOS 26+ (`SpeechTranscriber`) and Speech Recognition permission; on older
  systems it returns an error. There is no cloud-transcription fallback.
- **Transcripts are cached and keyed to audio content.** A transcript is
  written to a cache validated by the recording's audio digest + locale, so
  repeat calls return the stored text instantly. If a memo is trimmed or
  re-recorded, its digest changes and the cache is bypassed; pass `--refresh`
  to force re-transcription for the same audio.
- **Long transcripts don't come back inline by default.** The full text goes to
  a `.txt` file and only a ~280-char preview (`previewChars`) is returned, to
  avoid flooding an agent's context. Use `--inline` when you actually want the
  whole transcript (and `--timestamps` for segment times) in the response.
- **Schema-fragile.** Column/table names (`ZCLOUDRECORDING`, `ZENCRYPTEDTITLE`,
  etc.) are validated against the known macOS 15 schema; if Apple reorganizes
  it in a future release, `validateSchema` fails and actions degrade to an
  error / empty result rather than returning data.
- **Titles fall back to "Recording."** When a memo has no user title
  (`ZENCRYPTEDTITLE` empty) it's reported and exported as generic "Recording",
  so untitled memos aren't individually distinguishable by title.
