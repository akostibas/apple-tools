# apple-tools — Claude instructions

## Releases — new functionality means a new tag

apple-tools is consumed two ways, and **they update on different triggers**:

1. **CLI binary on `$PATH`** (`bin/install-skill` → `~/bin/apple-tools`).
   Rebuilds from whatever is checked out. A reinstall picks up `main`
   immediately — no tag needed.
2. **`AppleToolsLib` as a SwiftPM dependency** (e.g. Shannon's
   `probe-macos`, `.package(url: ".../apple-tools.git", from: "0.x.0")`).
   SwiftPM resolves on **git tags, not commits.** Merging to `main` is
   **invisible** to library consumers until a *version tag* is pushed —
   `swift package update` will sit on the old tag because there's nothing
   newer to find.

**Policy: any new functionality merged to `main` → cut and push a release
tag.** A merge that doesn't move a tag silently strands every library
consumer on the old API. Treat "merged but untagged" as unfinished.

### Versioning (pre-1.0 semver)

- `0.MINOR.0` — new features **or** breaking schema/field changes. Pre-1.0,
  breaking changes bump the **minor**, not a major.
- `0.MINOR.PATCH` — bug fixes with no API/schema change.

### Cutting a release

Use the script — it enforces the preconditions and keeps the tag and source
in lockstep:

```
bin/release 0.2.0          # preview: shows what it will do, asks to confirm
bin/release 0.2.0 --push   # bump Version.swift, commit, tag, push main + tag
```

The tag (`vX.Y.Z`) is what SwiftPM resolves; `Sources/AppleToolsLib/Version.swift`
is what `--version` reports — **they must match.** The script bumps both
together so they can't drift.

After pushing, library consumers update with:

```
swift package update apple-tools
```

If the release renamed or removed schema fields, expect consumer call sites
to break on update — that's the intended forcing function; fix them in the
same change.
