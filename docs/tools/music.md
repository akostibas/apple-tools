# music — Apple Music / Music.app

Read and control the local Music.app: see what's playing, search the local
library, rank it by play history, get "what to play now" picks, drive playback
(play/pause/skip/volume/shuffle/repeat/seek), and curate (favorite, rate,
playlists, AirPlay output). Drives `application "Music"` via AppleScript —
**zero auth** beyond the one-time Automation grant (no Apple Developer account,
MusicKit token, or sign-in popup).

**Access:** read/write — reads (now-playing, search, stats, mix, airplay-list)
are read-only; playback controls, curation writes (love, rate, playlist edits),
and airplay-select mutate player or library state.
**Permissions:** Automation → Music (TCC). The first call triggers the system
dialog; grant in System Settings → Privacy & Security → Automation.
**Verified on:** macOS 26.5.2 (Tahoe), apple-tools 0.24.0 — see
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

### Curation

These edit your **library** (not just player state). Each one issues the write,
then **reads the value back before returning** and reports `verified` — so a
silent no-op or an iCloud/permission rejection shows up as `verified: false`
rather than a false success. `ok: true` means "the command was issued";
`verified` means "the change was there when I looked." (See *Shortcomings* for
the iCloud-revert caveat: a read-back can pass and still revert on a later sync.)

- **love** — `--state on|off` favorites/unfavorites a track. Targets the current
  track, or the top library match for `--query` (+ optional `--field`). Returns
  `loved` (the read-back state) and `verified`.
- **rate** — `--stars 0-5` sets a star rating (0 clears it). Same targeting as
  `love`. Returns `rating` (0–100), `stars`, and `verified`.
- **playlist-create** — `--name <n>` makes a user playlist. **Idempotent by
  name**: if one already exists it makes none and returns `already_existed: true`,
  so repeated calls can't spawn duplicates.
- **playlist-add** — `--name <n> --query <q>` adds the top matching **library**
  track to the playlist; `verified` is the track-count going up. Only tracks
  already in your library can be added (see *Shortcomings*).
- **playlist-remove** — `--name <n> --query <q>` removes the first matching track
  from the playlist; `verified` is the count going down.
- **airplay-list** — list AirPlay output devices (`name`, `selected`, `kind`,
  per-device `volume`). Read-only.
- **airplay-select** — `--device <name>` (exact match) routes output to that
  device; `verified` is the device's `selected` flag reading back true.

> **Streams can't be favorited/rated.** The *current* track is often a `URL
> track` (a pure Apple Music stream not in your library). Music silently ignores
> `love`, and rejects `rate`, on those — both come back `verified: false`. Pass
> `--query` to target a real library track instead.

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
apple-tools music love --state on
apple-tools music rate --stars 5 --query "chariots of fire"
apple-tools music playlist-create --name "Road Trip"
apple-tools music playlist-add --name "Road Trip" --query "hey jude"
apple-tools music playlist-remove --name "Road Trip" --query "hey jude"
apple-tools music airplay-list
apple-tools music airplay-select --device "Living Room"
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
- **Curation writes can be reverted by iCloud.** `love`/`rate`/playlist edits
  return `verified` from an *immediate* read-back, which catches silent no-ops
  and permission rejections. But it only proves Music accepted the edit
  *locally* — for iCloud-synced (`shared`/`subscription`) tracks the cloud is
  authoritative and can revert the change on a later sync (seconds to minutes),
  which a same-call read-back can't see. Local `file track`s are reliable.
- **Playlists take library tracks only.** `playlist-add` can add a track that's
  already in your library, but not a pure Apple Music catalog item you haven't
  added — that needs a catalog add-to-library, an Apple Music API operation
  (issue #55). Do the add in the Music.app UI, then `playlist-add` works on it.
- **No Up Next / queue control, and no EQ.** Music's AppleScript dictionary
  exposes *no* enqueue / "add to Up Next" verb at all (only `duplicate`/`add`
  into playlists), so queue management isn't a deferral — it's a hard platform
  ceiling here. EQ control is deferred (see *Future ideas*).
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

**Shipped (#56 Group C).** `love`, `rate`, `playlist-create/add/remove`, and
`airplay-list`/`airplay-select` are now built (see *Curation* above), each with
the read-back verify these caveats called for. Two items from the original Group
C did **not** ship:

- **queue / up-next** — *not deferred, not possible here.* Music's AppleScript
  dictionary has no enqueue / "add to Up Next" verb (verified against the sdef),
  so there's nothing to build against. Would need the Apple Music API.
- **eq** — enable/disable + select an equalizer preset. Deferrable and
  low-priority; left out by request. Straightforward to add later (`current EQ
  preset` / `EQ enabled`) if wanted.

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
