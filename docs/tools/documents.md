# documents — Documents

Browse and read files under a set of **named roots**. By default there is one
root, `Documents` (`~/Documents`); embedding hosts (or the CLI's repeatable
`--root name=path` flag) can add more — e.g. an iCloud Drive shared folder.
Nothing outside the configured roots is reachable, and the tool only ever
reads: it can search, list, inspect metadata, and copy a file out for delivery.

Every tool path is namespaced by root name: `<root>/<relative-path>`, e.g.
`Documents/taxes/w2.pdf` or `samlexi/financial/2025.pdf`. The tool's schema
description lists the configured roots so callers know what is searchable.

**Access:** read
**Permissions:** none special beyond ordinary disk read. `search` shells out to
`/usr/bin/mdfind`, so it depends on the **Spotlight** index of each root;
the other actions read directly via `FileManager`.

## Actions

- **search** — Spotlight query (`query`) run with one `mdfind -onlyin` per root
  (mdfind unions the scopes). Returns matching files as root-prefixed paths with
  `size`/`modified`. Pageable via `offset`/`limit` (default 20, max 50).
- **list** — directory listing of a `path`. With no `path`, lists the roots
  themselves. Directories first, then alphabetical; each entry carries
  `type`, `size`, `modified`. Pageable via `offset`/`limit` (default 20, max 50).
- **info** — metadata for one `path`: `name`, `type`, `size`,
  `created`, `modified`, and (for files) a `content_type` MIME guess from the
  extension.
- **fetch** — copy the file at a `path` into the local output/delivery
  dir and return its path. This is how you retrieve a file's bytes.

Run `apple-tools documents --help` for the exact parameters of each action.

## Examples

```bash
apple-tools documents search --query "quarterly report" --limit 10
apple-tools documents list                       # lists the roots
apple-tools documents list --path "Documents/Projects/2026"
apple-tools documents info --path "Documents/taxes/w2.pdf"
apple-tools documents fetch --path "Documents/taxes/w2.pdf"

# Add a second root for one invocation:
apple-tools --root "samlexi=$HOME/Library/Mobile Documents/com~apple~CloudDocs/samlexi" \
  documents search --query "passport"
```

## Roots

- Roots are `(name, path)` pairs; paths are tilde-expanded and standardized at
  construction. Names must be unique and must not contain `/`.
- The `Documents` root is always present on the CLI; `--root` is additive.
  Library hosts (`allAppleTools(host:documentsRoots:)`) pass the complete set.
- A path whose first component names no configured root errors with
  `unknown root '<x>' (valid roots: …)`.
- Search hits are mapped back to a root by longest path prefix, so a root
  nested inside another resolves to the more specific name.

## Shortcomings

- **Read-only — no write, move, rename, delete, or create.** Every action is
  declared `.read` in the tool's access policy; there is simply no code path
  that mutates the filesystem. `fetch` only *copies a file out* for delivery; it
  never changes the original.
- **Scoped to the configured roots and nothing else.** `search` passes
  `-onlyin` for each root, and `list`/`info`/`fetch` reject any resolved path
  that isn't a root or strictly inside one (`path escapes root '<name>'`). A
  sibling like `~/Documents Backup` is invisible unless added as its own root.
- **`search` is only as good as the Spotlight index.** It is a thin wrapper over
  `mdfind`; files on unindexed volumes, in excluded locations, or created too
  recently to be indexed won't appear, and results reflect Spotlight's matching
  rules, not a literal filename/content scan. iCloud files that are not
  materialized locally may be missing or name-only in the index.
- **Hard page cap of 50.** `limit` is clamped with `min(limit, 50)` for both
  `search` and `list`, so large directories or broad searches must be walked in
  pages via `offset` — you can never pull more than 50 entries in one call.
- **The escape guard is lexical, so symlinks can point outside the scope.**
  The jail checks the *standardized path string* prefix; it does not
  resolve symlink targets. A symlink whose name lives under a root passes
  the guard, and `FileManager` follows it — so a link inside a root pointing
  elsewhere can list/read/fetch content that physically lives outside the tree.
