# screenshot — Screenshots

Capture the Mac's screen and hand back a reference to the saved image. Prompts
for confirmation first, then shells out to `/usr/sbin/screencapture` and delivers
a resized JPEG via the host's file sink.

**Access:** read (captures the screen → image reference).
**Permissions:** Screen Recording (System Settings → Privacy & Security → Screen
Recording). This is a **gated action**: every capture routes through the host's
confirmer (`host.confirmer.confirm`) and is aborted if the user declines.

## Actions

- **(default capture)** — the tool takes **no parameters** (`properties` is
  empty). It runs `screencapture -x` (`-x` = silent, no shutter sound) to a temp
  PNG, resizes the image for LLM consumption, and returns a JSON object with the
  delivered `filename` plus the file sink's reference key/value. There is no
  action to choose, no target to pass.

Run `apple-tools screenshot --help` for the exact parameters.

## Examples

```bash
apple-tools screenshot
apple-tools permissions   # grant Screen Recording first if capture returns empty
```

## Shortcomings

- **No display, region, or window targeting.** The parameter schema is empty and
  the command line is hard-coded to `["-x", tmpPath]` — no `-D` (display),
  `-R`/`-r` (region), or `-w`/`-l` (window) flags are ever passed. You capture
  whatever `screencapture`'s default is; you cannot pick a monitor, crop a
  rectangle, or grab a single window.
- **No interactive capture.** There's no `-i` flag, so you never get the
  drag-to-select crosshair. It's a single non-interactive grab.
- **Every capture requires confirmation.** `handle` calls `requestConfirmation()`
  before doing anything; if `host.confirmer.confirm` returns false it stops with
  `"User denied the screenshot request."` and `isError=true`. In a headless or
  non-interactive host this gate can block the capture entirely.
- **Output is a resized JPEG, not the raw PNG.** Despite capturing to a `.png`
  temp file, the delivered artifact is run through `ImageResizer.resizeForLLM`
  and saved as `screenshot-<timestamp>.jpg`. You get a downscaled,
  vision-optimized image — not full-resolution, and not PNG. The temp PNG is
  deleted (`defer removeItem`), so the original is not retained.
- **You get a reference, not a local path you chose.** The bytes are handed to
  `host.fileSink.deliver`; the response is whatever key/value the sink returns
  plus `filename`. There's no way to direct output to a specific path.
- **Missing Screen Recording permission fails opaquely.** Without the grant,
  `screencapture` exits non-zero or produces no data; the tool surfaces a
  generic "Screen Recording permission may be required" error rather than a
  system prompt. Run `apple-tools permissions` up front to trigger the TCC
  dialog.
