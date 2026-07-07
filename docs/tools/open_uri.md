# open_uri — Open URIs

Open a URI in whatever app macOS has registered as its default handler — a
web `https://` URL, a `mailto:`, a `tel:`, or an app deep link
(e.g. `shortcuts://run-shortcut?name=…`).

**Access:** action
**Permissions:** none (no TCC prompt). Every open is gated by a confirmation
dialog — the tool calls `host.confirmer.confirm(…)` before handing off, and a
denial returns an error without opening anything.

## Actions

- **open** — open the single required `uri`. The string is parsed with
  `URL(string:)` (empty or unparseable URIs are rejected), the user is asked to
  confirm, then it's passed to `NSWorkspace.shared.open(url)` for the OS to
  route to the default handler. Returns `{"ok": true, "uri": …}` on success.

Run `apple-tools open_uri --help` for the exact parameters.

## Examples

```bash
apple-tools open_uri --uri "https://example.com"
apple-tools open_uri --uri "mailto:user@example.com"
apple-tools open_uri --uri "tel:+15551234567"
```

## Shortcomings

- **No control over which app handles the URI.** The tool calls
  `NSWorkspace.shared.open(url)`, which routes to whatever macOS has registered
  as the default handler for that scheme — you can't target a specific browser,
  mail client, or app.
- **Fire-and-forget: success only means "handed off".** A successful result
  reflects `NSWorkspace.shared.open` returning `true` (the OS accepted the URL),
  not that the target app actually loaded the page, composed the mail, or placed
  the call — there's no confirmation of the end state.
- **Every open is confirmation-gated.** `host.confirmer.confirm(…)` prompts the
  user before opening; if they decline, the call returns
  `"User denied the request to open: …"`. This makes it unsuitable for silent /
  unattended automation.
- **No scheme allow-list, but strict URI parsing.** Any scheme the OS can handle
  is accepted (web, `mailto:`, `tel:`, app deep links, etc.) — there's no
  restriction to "safe" schemes. But the string must parse via `URL(string:)`;
  empty or malformed URIs fail with `invalid URI: …`.
- **Opens exactly one URI, no batching or options.** The only parameter is
  `uri`; there's no way to open multiple links at once or to pass activation
  options (e.g. open in background, hide the window).
