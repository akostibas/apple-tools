# apple-tools — supported tools

Every tool and its actions. Run `apple-tools <tool> --help` for the exact
parameters of any tool, or `apple-tools list` to print this set at your
installed version.

Read/write status is noted per tool; file-producing actions return a local
`path` (see the README "Files" section).

| Tool | Access | Actions |
|------|--------|---------|
| **calendar** | read/write | `calendars` (list calendars), `list` (events in a range), `search` (by keyword), `create` (add event; does not send invites) |
| **reminders** | read/write | `lists`, `search`, `get`, `create`, `create-list` (optional `--account`; rejects duplicate names), `complete` |
| **notes** | read/write | `folders`, `search`, `read`, `create`, `append` — content is Markdown; `--folder` takes a name or `/`-separated path |
| **contacts** | read | `search` (name/email/phone/group), `get` (by ID) |
| **email** (Mail) | read + draft | `inbox`, `search`, `read`, `fetch_attachment`, `draft` (does NOT send; supports attachments) |
| **imessage** (Messages, iMessage/SMS) | read/write | `recent`, `read`, `search`, `send` (supports attachments), `fetch_attachment` |
| **photos** | read | `search`, `fetch` (export a photo locally → path) |
| **voicememos** | read | `list` (recent recordings; last 30 days by default, `--all` for full history), `search` (by title/folder/date), `export` (copy a recording's `.m4a` → path), `transcribe` (on-device transcript, cached per recording; `--timestamps`, `--save`; macOS 26+) |
| **files** | read | `search` (Spotlight), `list`, `info`, `fetch` (copy a file locally → path). Scoped to `~/Documents` |
| **clipboard** | read/write | `read`, `write` |
| **screenshot** | read | capture the screen → local PNG path |
| **open_uri** | action | open a URL / `mailto:` / `tel:` / app deep link |
| **echo** | — | connectivity check |

## Permissions

Tools use macOS TCC permissions: Calendar, Contacts, Photos, Full Disk Access
(Mail/Messages), Screen Recording (screenshots), Speech Recognition
(`voicememos transcribe`). The first access to each triggers a system dialog —
run `apple-tools permissions` once up front to surface them all, then grant in
System Settings → Privacy & Security.
