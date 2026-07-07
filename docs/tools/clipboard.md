# clipboard — Clipboard

Read and write the macOS general pasteboard. Reading returns whatever is
currently on the clipboard (text, a URL, copied files, or an image); writing
only ever sets **plain text**.

**Access:** read/write
**Permissions:** none — the tool uses `NSPasteboard.general`, which needs no TCC
grant.

## Actions

- **read** — return the current clipboard contents. The response is typed:
  `text`/`url` for strings (a `length` is included, and a string that parses as
  an `http(s)` URL — or carries a URL pasteboard type — is reported as `url`),
  `files` for Finder-copied files (a list of `path` + guessed `content_type`),
  `image` for copied images/screenshots (written to a file via the file sink and
  returned as a path/ref, always as PNG), `empty` when nothing is on the
  clipboard, or `unknown` (with raw `pasteboard_types`) when the content can't be
  interpreted.
- **write** — set the clipboard to the string in `text`. Clears existing
  contents first, then writes text only; returns `ok` and the written `length`.

Run `apple-tools clipboard --help` for the exact parameters of each action.

## Examples

```bash
apple-tools clipboard read
apple-tools clipboard write --text "meeting at 3pm"
apple-tools clipboard write --text "https://example.com/page"
```

## Shortcomings

- **`write` sets plain text only — you cannot write images, files, URLs, or
  rich text.** `write()` calls `setString(text, forType: .string)`, so there's no
  way to place an image, a file reference, RTF, or any non-string type onto the
  clipboard.
- **No clear and no history.** There's no `clear` action (the only way to empty
  the clipboard is to `write --text ""`, which leaves an empty string, not a
  truly empty pasteboard), and no access to macOS clipboard history — `read`
  only ever sees the single current pasteboard contents.
- **Image reads are always re-encoded to PNG and offloaded to the file sink.**
  `read` converts TIFF (the usual screenshot format) or PNG data to PNG and
  hands it to `host.fileSink.deliver(...)`; you get a file path/ref, never the
  bytes inline, and if the sink upload fails the whole read returns an error.
- **Read type detection is order-sensitive and can mislabel.** The reader checks
  file URLs first, then images, then text — so a clipboard holding *both* a file
  and text reports only the files, and copied text that merely looks like a URL
  (parses as `http(s)`) is relabeled `type: url` even if you copied it as plain
  text.
- **Non-standard content is opaque.** Anything that isn't a file URL, TIFF/PNG
  image, or `.string` (e.g. RTF-only, custom app pasteboard types) comes back as
  `type: unknown` with just the raw `pasteboard_types` list — no usable content.
```
