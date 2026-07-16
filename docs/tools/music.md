# music — Apple Music / Music.app

Read and control the local Music.app: see what's playing, search the local
library, rank it by play history, get "what to play now" picks, and drive
playback (play/pause/skip/volume/shuffle/repeat/seek). Drives `application
"Music"` via AppleScript — **zero auth** beyond the one-time Automation grant
(no Apple Developer account, MusicKit token, or sign-in popup).

**Access:** read/write — reads (now-playing, search, stats, mix) are read-only;
playback controls (play, pause, next, volume, …) mutate player state.
**Permissions:** Automation → Music (TCC). The first call triggers the system
dialog; grant in System Settings → Privacy & Security → Automation.
**Verified on:** macOS 26.5.2 (Tahoe), apple-tools 0.19.0 — see
[COMPATIBILITY.md](./COMPATIBILITY.md) for the pinned commit and caveats. Music's
AppleScript terminology drifts across macOS releases (Tahoe renamed `loved` to
`favorited` and made transport commands settle asynchronously), so a newer macOS
— or newer apple-tools commit — is unverified until re-checked.

## Actions

- **now-playing** — the current track and player `state` (`playing` / `paused`
  / `stopped`) plus `position` (seconds elapsed). Works for a streamed Apple
  Music track too, which shows up as `kind: "URL track"` with no `cloud_status`.
- **search** — find tracks in the local library. `query` is a case-insensitive
  substring; `field` selects what it matches — `any` (default: name, artist, or
  album), `title`, `artist`, or `album`. Bounded by `limit` (default 25).
- **stats** — rank the whole library by a local play statistic (`by`, required):
  - `most-played` — highest `played_count` first (unplayed tracks excluded).
  - `recently-played` — most recent `played_date` first (never-played excluded).
  - `most-loved` — favorited/loved tracks, highest `played_count` first.

  Bounded by `limit` (default 20).

- **mix** — derived "what should I play right now" picks (`by`, required). Where
  `stats` reports raw facts, `mix` blends recency, play count, ratings, and
  library age into actionable suggestions:
  - `neglected-favorites` — loved / 4★+ tracks not heard in the last `months`
    (default 6). *The* "rediscover something you love" query; self-clearing
    (playing a track drops it until the window lapses again).
  - `rediscover` — heavily played (≥ 8 lifetime plays) but not heard in
    `months` — like neglected-favorites, but earned by plays, so it catches
    things you clearly loved yet never rated.
  - `velocity` — `played_count ÷ days-since-added`, highest first. The honest
    local stand-in for "trending" / "on rotation": a track added last week and
    played 8 times beats one added five years ago and played 8 times.
  - `fresh` — added in the last `days` (default 30) and barely played — new
    music you haven't given a fair hearing yet.
  - `unplayed-gems` — loved / 4★+ but never played — flagged gems still in the
    backlog.

  Bounded by `limit` (default 20). Tune windows with `--months` (neglected /
  rediscover) and `--days` (fresh).

  **Why `mix` and not just `stats`?** "Most-played all-time" is a *fact*, but
  usually not what you want to hear *now* — it's dominated by songs you loved
  years ago. `mix` answers the actual question. Note the hard limit: Music
  stores only a lifetime play count and a *single* last-played timestamp per
  track — there's no local play-by-play log — so a true "top plays in the last
  30 days" is impossible here (that needs the Apple Music API; see issue #55).
  These queries approximate it from what's local.

### Playback control

These mutate player state (not your library). Each returns `{ "ok": true }`
with the resulting `state` and current `track`.

- **play** — resume playback, or start something specific: `--playlist <name>`
  plays the first user playlist whose name contains it; `--query <text>`
  (with optional `--field`) plays the top matching library track. With no
  target, resumes what's cued.
- **pause** / **playpause** / **stop** — pause, toggle, or stop.
- **next** / **previous** — skip forward / back.
- **volume** — `--level 0-100` sets the app volume (clamped).
- **shuffle** — `--state on|off`.
- **repeat** — `--mode off|one|all`.
- **seek** — `--position <seconds>` jumps within the current track.

Run `apple-tools music --help` for the exact parameters of each action.

## Track fields

Every track carries: `name`, `artist`, `album`, `duration` (seconds),
`played_count`, `played_date` (ISO-8601 UTC, omitted if never played), `rating`
(0–100) and `stars` (0–5), `loved` (favorite state), `database_id`, and two
fields that reveal which "world" the track belongs to:

- **`kind`** — `file track` (a real file on disk), `shared track` (added from
  Apple Music, not downloaded), or `URL track` (a pure catalog stream, only ever
  seen as the current track).
- **`cloud_status`** — `subscription` (streamed-in Apple Music content),
  `purchased`, `matched`, `uploaded`, or omitted. Use it to tell your own files
  apart from Apple Music content.

## Examples

```bash
apple-tools music now-playing
apple-tools music search --query "kid a" --field album
apple-tools music search --query radiohead --field artist --limit 10
apple-tools music stats --by most-played --limit 10
apple-tools music stats --by recently-played
apple-tools music mix --by neglected-favorites --months 12
apple-tools music mix --by velocity --limit 15
apple-tools music mix --by fresh --days 14
apple-tools music play --playlist "Road Trip"
apple-tools music play --query "hey jude"
apple-tools music pause
apple-tools music next
apple-tools music volume --level 60
apple-tools music shuffle --state on
apple-tools music repeat --mode all
```

## Shortcomings

- **Play stats are local, not your true Apple Music history.** `stats` output is
  labeled `"source": "local"` for a reason: it reflects what *this Mac* recorded.
  Streamed plays don't reliably increment `played_count`, and for iCloud-synced
  (`shared`) tracks the cloud is authoritative — so this is not a faithful
  cross-device listening history. The real recent-played feed lives behind the
  Apple Music API (out of scope — see issue #55).
- **Library only — no catalog.** `search` matches the local library. It can't
  reach the Apple Music streaming catalog; a song you've never added won't
  appear. Catalog search needs MusicKit / the Apple Music API and its auth.
- **No curation writes yet.** Playback control works, but rating/favoriting,
  playlist edits, queue management, and AirPlay/EQ are a later phase (#56 Group
  C). Reads never mutate; playback controls only change *player* state, never
  your library.
- **Transport commands settle asynchronously.** Music applies `pause`/`play`/
  `next`/`seek` just after returning control, so the tool waits a brief moment
  before reading back the resulting `state`/`position`. Expect a ~0.3s pause on
  those actions; it's what makes the confirmation accurate.
- **iCloud sync volatility.** A track added from Apple Music becomes visible here
  once it syncs to the local library (as a `shared`/`file track`), but that add
  can also silently revert on a later sync — so a track present one moment may be
  absent the next. Not a tool bug; it's how iCloud Music Library behaves.
- **macOS version drift.** The "Love" → "Favorite" rename in macOS 26 (Tahoe)
  broke the old `loved` AppleScript property; the tool tries `favorited` first
  and falls back to `loved` on older macOS. Apple has broken Music AppleScript
  terms across releases before, so expect occasional drift.

## Future ideas

Deferred, not built. Tracked under [issue #56](https://github.com/akostibas/apple-tools/issues/56)
(local, zero-auth) and [#55](https://github.com/akostibas/apple-tools/issues/55)
(the Apple Music API engine).

**Curation writes (zero-auth, but caveated).** These mutate the library rather
than just player state, so each would need a read-back "did it persist?" check:

- **love / rate** — set favorite + star rating. Reliable for local `file
  track`s, but iCloud is authoritative for `shared`/`subscription` tracks and
  can silently revert the edit on next sync.
- **playlist create / add / remove** — manage user playlists. Note the ceiling:
  via AppleScript you can only add tracks *already in the library*. The
  compelling case — "add that Apple Music song I just found to a playlist" —
  needs adding a catalog item to the library first, which is an Apple Music API
  operation (see below), not AppleScript. So playlist building is limited until
  catalog-add exists. Some user playlists also silently reject AppleScript edits.
- **queue / up-next** — add to Up Next; the AppleScript dictionary exposes this
  only thinly.
- **airplay** — list output devices and choose one; set per-device volume.
- **eq** — enable/disable and select an equalizer preset.

**Apple Music API engine (heavy — needs auth).** Everything the local world
can't reach, behind an Apple Developer account, a signing key, and a one-time
interactive Music-User-Token bootstrap (a GUI popup for an otherwise-headless
CLI):

- **catalog search / play** — find and play songs not in your library.
- **add-to-library** — the bridge that pulls catalog picks into the local world,
  after which every zero-auth read/control above works on them.
- **true recent-played history** — the authoritative cross-device listening feed
  (`/v1/me/recent/played`), which is what makes real "top plays in the last N
  days" possible (impossible locally — Music keeps only a lifetime count and one
  last-played timestamp per track).
- **recommendations / charts / editorial**.
