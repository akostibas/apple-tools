# media — recent media engagement

See what you've recently listened to or read, newest first, merged across
**Apple Podcasts** and **Apple Books**. Reads the apps' local databases
directly (read-only) — the same approach apple-tools uses for Notes, Messages,
and Voice Memos.

Because Podcasts and Books sync over iCloud, this reflects activity from your
**other devices** too — notably podcasts you listened to on your phone show up
here, which is the main reason the tool is useful.

**Access:** read-only
**Permissions:** none (the databases live under your own `~/Library`).
**Verified on:** macOS 27.0 (26A428) — see [COMPATIBILITY.md](./COMPATIBILITY.md).

> **macOS 27 note.** Podcasts moved episode duration out of `ZMTEPISODE` into a
> separate `ZMTMEDIAENCLOSURE` row. Duration is now probed wherever it lives, and
> a missing one no longer suppresses the whole podcast source — it only drops the
> `percent` field.

## Actions

- **recent** — everything played or opened in the last `--hours` (default 24),
  newest first, capped by `--limit` (default: all). Each item carries its
  `source` (podcast/book), `title`, `creator` (show or author), `last_engaged`
  (ISO-8601 UTC), `percent` (how far through), and — for podcasts —
  `duration_seconds` (episode length).

```bash
apple-tools media recent
apple-tools media recent --hours 168 --limit 10
```

## Shortcomings

- **Podcasts and Books only.** Music has its own richer tool (`music`); use that
  for songs. TV and movies are **not** covered — Apple TV keeps watch history on
  its servers and on the TV-connected device, with no local read path.
- **Read-only.** This tool only reports; it can't start playback (Podcasts.app
  isn't automatable at all).
- **Cross-device depends on iCloud sync.** An item only appears once its source
  app has synced it to this Mac; there's normal lag, and if Sync is off for an
  app, that app's activity won't show.
- **Books is often sparse** in practice even when it has content — reading
  activity just isn't frequent for most people.
- **Streaming music wouldn't appear anyway** (and isn't included here): Apple
  Music streams don't update local play history. That's a `music`-tool concern,
  noted only so the "why isn't X here" is clear.
