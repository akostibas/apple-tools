---
name: apple-tools
description: Read and write the local Mac's Apple apps via the `apple-tools` CLI. Use whenever you need to act on the user's own macOS data — e.g. make or check reminders, read/search/draft email, view or add calendar events, look up contacts, send an iMessage/SMS, read/write/append notes, find or fetch files, search/export photos, read or write the clipboard, take a screenshot, or open a URL/mailto/tel link. Covers Calendar, Reminders, Notes, Contacts, Mail, Messages (iMessage/SMS), Photos, Files, clipboard, screenshots, and opening URIs. Prefer this over ad-hoc osascript/AppleScript for these tasks — osascript can return incomplete results (e.g. a partial Reminders list); this does NOT apply when osascript itself is the thing being developed.
---

# apple-tools

A single CLI, `apple-tools`, exposes the Mac's Apple integrations. Each tool is
a subcommand; most dispatch on an `action`. Run it via Bash.

## Invocation

```
apple-tools <tool> <action> [--flag value ...]
apple-tools <tool> --json '{"action":"...", ...}'   # raw escape hatch
apple-tools <tool> --help                            # parameters for a tool
apple-tools list                                     # all tools
apple-tools permissions                              # preflight / trigger TCC prompts
```

- Flags map to the tool's parameters; `--calendar-name` and `--calendar_name`
  are equivalent. Array params (e.g. `--attachments`) accept repeats or commas.
- Output is JSON on stdout (pretty-printed). Exit code is non-zero on error,
  with a message on stderr.
- ISO 8601 for dates/times (e.g. `2026-06-15T09:00:00Z`).
- Every invocation posts a macOS notification summarizing what ran (e.g.
  "reminders lists → 14 result(s)"), so the user sees each action. Pass
  `--quiet` (or set `APPLE_TOOLS_QUIET=1`) to suppress it — e.g. for a burst of
  read calls where one banner per call would be noisy.

## Permissions (first run)

Tools use macOS TCC permissions (Calendar, Contacts, Photos, Full Disk Access
for Mail/Messages, Screen Recording for screenshots). The **first** access to
each triggers a system dialog. Run `apple-tools permissions` once up front to
surface them all, then grant in System Settings → Privacy & Security. If a tool
returns an access/permission error, tell the user which permission to grant.

## Files

File-producing actions (`photos fetch`, `screenshot`, `files fetch`,
`clipboard read` on an image, `email`/`imessage fetch_attachment`) write the
file to a local output dir and return its **absolute `path`** in the JSON. Read
that path directly with the Read tool. Override the location with
`--output-dir <dir>` or `$APPLE_TOOLS_OUTPUT_DIR` (default: a private per-user
temp dir).

## Writes and sends — confirm first

These actions change state or are visible to others. Confirm with the user in
chat before running them: `imessage send`, `email draft` (creates a draft),
`calendar create`, `reminders create`/`complete`, `notes create`/`append`,
`clipboard write`, `open_uri`. (`--confirm` additionally pops a native
Allow/Deny dialog; off by default.)

## Tools

- **calendar** — `calendars` (list calendars), `list` (events in a range),
  `search` (by keyword), `create` (add event; does not send invites).
- **reminders** — `lists`, `search`, `get`, `create`, `create-list` (new list,
  optional `--account`; rejects duplicate names), `complete`.
- **notes** — `folders`, `search`, `read`, `create`, `append`. Content is
  Markdown (headings, bold/italic/strike/mono, lists round-trip).
- **contacts** — `search` (name/email/phone/group), `get` (by ID).
- **email** — `inbox`, `search`, `read`, `fetch_attachment`, `draft` (does NOT
  send; supports attachments by absolute path).
- **imessage** — `recent`, `read`, `search`, `send` (iMessage/SMS; supports
  attachments), `fetch_attachment`.
- **photos** — `search`, `fetch` (export a photo locally → path).
- **files** — `search` (Spotlight), `list`, `info`, `fetch` (copy a file locally
  → path). Scoped to ~/Documents.
- **clipboard** — `read`, `write`.
- **screenshot** — capture the screen → local PNG path.
- **open_uri** — open a URL / mailto: / tel: / app deep link.
- **echo** — connectivity check.

Run `apple-tools <tool> --help` for the exact parameters of any tool.

## Examples

```
apple-tools calendar list --start 2026-06-15T00:00:00Z --end 2026-06-16T00:00:00Z
apple-tools reminders create --list "Today" --title "Call plumber" --due 2026-06-16T17:00:00Z
apple-tools reminders create-list --name "Shannon" --account iCloud
apple-tools contacts search --query "Jane"
apple-tools notes read --title "Trip plan"
apple-tools email search --query "invoice" --limit 10
apple-tools imessage send --to "+15551234567" --text "on my way"
apple-tools screenshot --output-dir /tmp/shots
```

## Setup

If `apple-tools` is not found, build and install it from the project repo:
`bin/install-skill` (builds the release binary and links it onto PATH).
