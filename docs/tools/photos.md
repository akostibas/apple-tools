# photos — Photos

Search the Apple Photos library by ML-recognized content, recognized people,
album, date, or filename, and export a single photo to a local file. Read-only:
it never modifies the library.

**Access:** read
**Permissions:** Photos (the first access triggers the system dialog; grant in
System Settings → Privacy & Security → Photos). `fetch` also writes the exported
image into the tool's output directory.

## Actions

- **search** — find photos and return their metadata (id, dimensions, filename,
  created/modified dates, location, favorite flag). Matching is layered:
  - `--query` runs an ML-label ("content") search first — the words Photos has
    recognized in the image (car, dog, beach). Each result is tagged
    `matched: content`.
  - `--person NAME` (or `--match people --query NAME`) restricts to photos *of* a
    recognized person via face recognition; results tagged `matched: person`.
  - `--match people` with no name **lists** the recognized people in the library.
  - `--album NAME` filters to an album (exact title); `--query` inside an album
    matches filenames only.
  - `--match content|filename|people` constrains which matcher runs; with no ML
    hit and no constraint, `--query` falls back to a filename match
    (`matched: filename`).
  - `--start_date` / `--end_date` (ISO 8601) bound by capture date; `--limit`
    caps results (default 20).
- **fetch** — export one photo by `--id` (a local identifier from a search
  result) into the output dir and return its path. Default is a JPEG resized to
  max 1568px (for LLM vision); pass `--full_resolution` for the original.

Run `apple-tools photos --help` for the exact parameters of each action.

## Examples

```bash
apple-tools photos search --query "beach" --start_date 2026-06-01 --limit 10
apple-tools photos search --person "Sandy Ford"
apple-tools photos search --match people
apple-tools photos fetch --id "A1B2C3D4-.../L0/001" --full_resolution
```

## Shortcomings

- **Read-only — no writing of any kind.** Both actions are declared `.read`, so
  the tool cannot add, delete, edit, favorite, tag, or organize photos, and it
  cannot create, rename, or add to albums. It only searches and exports copies.
- **Images only; videos are invisible.** Every fetch predicate is
  `mediaType == image` (`searchAllPhotos`, `searchInAlbum`, PSI, and person
  search all pin it), so videos never appear in results and can't be fetched.
  Live Photos surface as their still image (tagged `media_subtype: live`).
- **`fetch` downscales by default.** Without `--full_resolution` the export is
  resized to a max of 1568px and re-encoded as JPEG (`requestResizedImage`,
  quality 0.85); the returned file is not the original. Full-res HEIC/HEIF
  originals are also transcoded to JPEG (quality 0.95) so downstream consumers
  don't need HEIF support (`requestFullResImage`).
- **Album lookup is exact-match only.** `findAlbum` matches on
  `localizedTitle == name`, so an album name must be typed exactly — no fuzzy or
  partial matching — and keyword search *within* an album is filename-based, not
  content-based (the old content check was dead code and was removed).
- **ML-content and people search read Photos' internal SQLite databases
  directly** (`psi.sqlite` for labels, `Photos.sqlite` for faces). If those
  files are missing or their schema changed under an OS update, the schema
  validation fails and that path silently degrades — content search falls back
  to a filename match, and people search returns an "unavailable" error.
- **Filename fallback scan is capped.** A keyword with no ML hit scans at most
  `max(limit*50, 500)` assets newest-first; a matching filename older than that
  cutoff won't be found (the response flags `truncated: true` when the cap is
  hit).
- **Date filtering deliberately ignores the PSI index's own timestamp.** ML
  results are re-fetched through PhotoKit for correct `creationDate` ordering
  and range filtering, because `psi.sqlite`'s `creationDate` is a quantized index
  timestamp, not capture time (see the #32 regression note in code).
- **iCloud originals are downloaded on `fetch`.** Export sets
  `isNetworkAccessAllowed = true`, so fetching a photo whose original lives only
  in iCloud will pull it over the network (and can be slow or fail offline).
