# apple-tools — tool reference

One page per tool. Each documents what the tool does, its actions, a few
examples, and — importantly — its **known shortcomings**. For the exact
parameters of any action, run `apple-tools <tool> --help`; to see the set built
into your installed version, run `apple-tools list`.

- [`calendar`](calendar.md) — Calendar (read/write)
- [`reminders`](reminders.md) — Reminders (read/write)
- [`notes`](notes.md) — Notes (read/write)
- [`contacts`](contacts.md) — Contacts (read)
- [`email`](email.md) — Mail (read + draft)
- [`imessage`](imessage.md) — Messages, iMessage/SMS (read/write)
- [`photos`](photos.md) — Photos (read)
- [`voicememos`](voicememos.md) — Voice Memos (read)
- [`documents`](documents.md) — the user's documents, under configurable named roots (default `~/Documents`) (read)
- [`clipboard`](clipboard.md) — Clipboard (read/write)
- [`screenshot`](screenshot.md) — Screenshots (read)
- [`open_uri`](open_uri.md) — Open URLs / `mailto:` / `tel:` / deep links

## Page template

Every tool page follows the same shape. Keep it concise; link to `--help` for
parameter detail rather than duplicating it.

```markdown
# <tool> — <App>

<1–2 sentence summary of what it does.>

**Access:** read | read/write | read + draft | action
**Permissions:** <TCC permissions needed, or "none">.

## Actions

- **<action>** — <what it does; note key params inline>.
  …

Run `apple-tools <tool> --help` for the exact parameters of each action.

## Examples

​```bash
apple-tools <tool> <action> …
​```

## Shortcomings

- <Honest, concrete limitations and gotchas — the failure modes a user or agent
  will actually hit. This section is required and should never be empty; if a
  tool genuinely has none worth noting, say so explicitly.>
```

## Permissions

Tools use macOS TCC permissions: Calendar, Contacts, Photos, Full Disk Access
(Mail/Messages), Screen Recording (screenshots), Speech Recognition
(`voicememos transcribe`). The first access to each triggers a system dialog —
run `apple-tools permissions` once up front to surface them all, then grant in
System Settings → Privacy & Security.
