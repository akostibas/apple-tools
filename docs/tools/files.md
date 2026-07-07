# files — Files

Browse and read files under `~/Documents`. Everything is scoped to that one
directory tree — no other folder on disk is reachable — and the tool only ever
reads: it can search, list, inspect metadata, and copy a file out for delivery.

**Access:** read
**Permissions:** none special beyond ordinary disk read. `search` shells out to
`/usr/bin/mdfind`, so it depends on the **Spotlight** index of `~/Documents`;
the other actions read directly via `FileManager`.

## Actions

- **search** — Spotlight query (`query`) run with `mdfind -onlyin ~/Documents`.
  Returns matching files as relative paths with `size`/`modified`. Pageable via
  `offset`/`limit` (default 20, max 50).
- **list** — directory listing of a relative `path` (defaults to the
  `~/Documents` root). Directories first, then alphabetical; each entry carries
  `type`, `size`, `modified`. Pageable via `offset`/`limit` (default 20, max 50).
- **info** — metadata for one relative `path`: `name`, `type`, `size`,
  `created`, `modified`, and (for files) a `content_type` MIME guess from the
  extension.
- **fetch** — copy the file at a relative `path` into the local output/delivery
  dir and return its path. This is how you retrieve a file's bytes.

Run `apple-tools files --help` for the exact parameters of each action.

## Examples

```bash
apple-tools files search --query "quarterly report" --limit 10
apple-tools files list --path "Projects/2026"
apple-tools files info --path "taxes/w2.pdf"
apple-tools files fetch --path "taxes/w2.pdf"
```

## Shortcomings

- **Read-only — no write, move, rename, delete, or create.** Every action is
  declared `.read` in the tool's access policy; there is simply no code path
  that mutates the filesystem. `fetch` only *copies a file out* for delivery; it
  never changes the original.
- **Scoped to `~/Documents` and nothing else.** The root is hard-coded to
  `NSHomeDirectory() + "/Documents"`, `search` passes `-onlyin` that directory,
  and `list`/`info`/`fetch` reject any resolved path that isn't `~/Documents` or
  strictly inside it (`path escapes ~/Documents`). So `~/Desktop`,
  `~/Downloads`, the iCloud Drive root, external volumes, and even a sibling
  like `~/Documents Backup` are all invisible.
- **`search` is only as good as the Spotlight index.** It is a thin wrapper over
  `mdfind`; files on unindexed volumes, in excluded locations, or created too
  recently to be indexed won't appear, and results reflect Spotlight's matching
  rules, not a literal filename/content scan.
- **Hard page cap of 50.** `limit` is clamped with `min(limit, 50)` for both
  `search` and `list`, so large directories or broad searches must be walked in
  pages via `offset` — you can never pull more than 50 entries in one call.
- **The escape guard is lexical, so symlinks can point outside the scope.**
  `isWithinDocuments` checks the *standardized path string* prefix; it does not
  resolve symlink targets. A symlink whose name lives under `~/Documents` passes
  the guard, and `FileManager` follows it — so a link inside Documents pointing
  elsewhere can list/read/fetch content that physically lives outside the tree.
