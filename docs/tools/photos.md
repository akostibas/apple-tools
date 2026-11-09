# photos — Photos

Search the Apple Photos library by ML-recognized content, recognized people,
album, date, or filename, and export a single photo to a local file. Read-only:
it never modifies the library.

**Access:** read
**Permissions:** Photos (the first access triggers the system dialog; grant in
System Settings → Privacy & Security → Photos). `fetch` also writes the exported
image into the tool's output directory.
**Verified on:** macOS 27.0 (26A428) — see [COMPATIBILITY.md](./COMPATIBILITY.md).

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
  - `--match text` searches the words Photos read *inside* the image (signs,
    receipts, labels; macOS 27+), tagged `matched: text`. Other `--query`
    searches never mix these in; they report `text_match_count` instead.
  - `--match content|filename|people|text` constrains which matcher runs; with
    no ML hit and no constraint, `--query` falls back to a filename match
    (`matched: filename`).
  - `--start` / `--end` (ISO 8601) bound by capture date; `--limit`
    caps results (default 20).
- **fetch** — export one photo by `--id` (a local identifier from a search
  result) into the output dir and return its path. Default is a JPEG resized to
  max 1568px (for LLM vision); pass `--full_resolution` for the original.

Run `apple-tools photos --help` for the exact parameters of each action.

## Examples

```bash
apple-tools photos search --query "beach" --start 2026-06-01 --limit 10
apple-tools photos search --person "Sandy Ford"
apple-tools photos search --match people
apple-tools photos search --query receipt --match text
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
  directly** (`Photos.sqlite` for faces; for labels, `psi.sqlite` on macOS 26
  and earlier or `leo.sqlite` from macOS 27 — whichever is present, detected by
  probing rather than by OS version). If neither index is there or its schema is
  unrecognized, content search returns an explicit "content search is
  unavailable" error and people search returns an "unavailable" error. Neither
  degrades quietly: an empty result is reserved for a search that genuinely
  matched nothing, because a caller cannot otherwise tell "no photos of dogs"
  from "we could not look".
- **Text search is macOS 27+ and one word at a time.** macOS 26's index has no
  scanned text, so `--match text` reports unavailable there. Each scanned word
  is matched separately, so a multi-word query like `trader joe` finds nothing.
- **Filename fallback scan is capped.** A keyword with no ML hit scans at most
  `max(limit*50, 500)` assets newest-first; a matching filename older than that
  cutoff won't be found (the response flags `truncated: true` when the cap is
  hit).
- **Date filtering deliberately ignores the search index's own timestamp.** ML
  results are re-fetched through PhotoKit for correct `creationDate` ordering
  and range filtering, because the index's date column is an *indexing* time,
  not capture time, in both the old and new formats (see the #32 regression note
  in code).
- **iCloud originals are downloaded on `fetch`.** Export sets
  `isNetworkAccessAllowed = true`, so fetching a photo whose original lives only
  in iCloud will pull it over the network (and can be slow or fail offline).
