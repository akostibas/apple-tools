# apple-tools

Local macOS/Apple integrations as a single CLI, plus a Claude Code skill that
drives it. Read and write Calendar, Reminders, Notes, Contacts, Mail, Messages
(iMessage/SMS), Photos, read Voice Memos, plus files, the clipboard,
screenshots, and open URIs — all on the machine it runs on, with no server.

## Quick start

```bash
make install               # build the release binary, link it onto PATH, install the skill
apple-tools permissions    # grant macOS access (Calendar, Contacts, Photos, Full Disk Access, …)
apple-tools list           # see the tools
apple-tools calendar list --start 2026-06-15T00:00:00Z --end 2026-06-16T00:00:00Z
```

## Upgrading

`make install` symlinks `~/bin/apple-tools` into this source checkout, so the
installed binary only changes when you rebuild it — pulling new commits or
cutting a release tag does **not** update it on its own. To upgrade:

```bash
cd <your apple-tools checkout>
git pull
make install               # rebuild and refresh the symlinks (idempotent)
```

The CLI performs a best-effort check at most once per week and prints a one-line
nudge to **stderr** when a newer release tag exists (stdout — the JSON tool
contract — is never touched). It fails silent when offline and never blocks a
command. Disable it entirely with `APPLE_TOOLS_NO_UPDATE_CHECK=1`.

## CLI shape

```
apple-tools <tool> <action> [--flag value ...]
apple-tools <tool> --json '{"action":"...", ...}'   # raw params
apple-tools <tool> --help                            # parameters for a tool
apple-tools permissions                              # preflight all tools (trigger TCC dialogs)
```

The CLI is **schema-driven**: every tool publishes a `ToolDefinition` (a JSON
schema), and the driver maps `action` → subcommand and each property → a
`--flag`, coercing values to the declared type. There is no per-tool argument
parsing — adding a tool to the library adds it to the CLI automatically.

## Output schema conventions

Every tool emits JSON. Field names are kept consistent across tools so an agent
can read calendar + email + imessage + photos together without re-learning
names. The rules:

- **Timestamps** are always ISO-8601 strings in **UTC** (`...Z`), named for the
  moment they capture: `created`, `modified`, `date` (the item's own time),
  `start`/`end` (spans), `due_date`, `first_date`/`last_date` (rollup span),
  `last_message_date`. Every tool routes through one formatter
  (`DateFormatting`), so the format can't drift between actions. UTC is the
  portable default — a library consumer that knows the user's actual location
  can set `DateFormatting.outputTimeZone` once at startup to render every
  timestamp in that zone instead (no per-call argument).
- **Phone numbers** are emitted in canonical **E.164** (`+15551234567`) wherever
  a value is known to be a phone number. Every tool routes through one helper
  (`PhoneFormatting`), so the format can't drift between tools. Contacts phone
  values are canonicalized in place; Messages adds an E.164 `phone_e164` field
  *beside* the raw handle (the raw `chat_id` is never rewritten). A value that
  isn't confidently a phone number — an email, a marketing short code, or
  anything libphonenumber rejects — is left exactly as-is, never coerced. A bare
  national number (no `+`) is interpreted using the system region by default; a
  library consumer that knows the user's region can set
  `PhoneFormatting.defaultRegion` once at startup (mirrors `outputTimeZone`).
- **Identifiers**: the opaque primary id of a record is `id` (events,
  reminders, contacts, notes, photos, email messages). Raw routing handles keep
  their qualified names (`chat_id`, participant `identifier`) — these are
  addresses, not record ids, and are never renamed to `id`.
- **Resolved names live beside their raw id, never replace it.** A handle/address
  field (`from`, `chat_id`, participant `identifier`) is preserved as-is, and the
  Contacts-resolved display name is added as `contact_name` (or
  `last_message_from_name` for the last-message sender). Calendar/Contacts
  primary names use `name`.
- **Counts** use `*_count` (`message_count`, `unread_count`, `attachment_count`).
  The response-level number of returned items is `count`; `total` is the full
  count available behind pagination.
- **Booleans** use `is_`/`has_` (`is_organizer`, `is_likely_spam`,
  `is_shortcode`). A few domain-standard flags predate the convention and keep
  their plain adjective names (`all_day`, `read`, `completed`, `favorite`).

## Files

File-producing actions (`photos fetch`, `screenshot`, `files fetch`, clipboard
images, attachment fetches) write to a local output dir and return the absolute
`path` in their JSON. Control the location with `--output-dir` or
`$APPLE_TOOLS_OUTPUT_DIR` (default: a private per-user temp dir, `0700`).

## Architecture

```
Sources/
  AppleToolsObjC/   # ObjC shim (safe NSUnarchiver for iMessage attributedBody)
  AppleToolsLib/    # tools, integrations, ToolHost seam, CLI arg mapper
  apple-tools/      # the CLI executable (thin; delegates to the lib)
Tests/AppleToolsTests/
skills/apple-tools/  # the Claude skill (SKILL.md)
```

`AppleToolsLib` is a published `.library` product: this CLI is one consumer,
and a server-backed host can be another. All consumers depend on
the same tool implementations and inject their own backend through a small
**`ToolHost`** (`Sources/AppleToolsLib/ToolHost.swift`):

- **`fileSink`** — where file-producing tools deliver output.
  `deliver(filename:data:)` returns a keyed `FileReference {key, value}`, so the
  host controls both halves of the result: this CLI injects `LocalFileSink`
  (`{"path": "/abs/path"}`); a server host injects an uploader
  (`{"file_id": "…"}`).
- **`confirmer`** — how sensitive actions (screenshot, open-URI) are gated.
  `AllowAllConfirmer` (the CLI default, for non-interactive agent use),
  `AppleScriptConfirmer` (a blocking Allow/Deny dialog), or a host's own.
- **`appName`** — the identity shown in those confirmation dialogs.

Pure read-only tools (Calendar, Contacts, Reminders, Notes) need no host.
`Log.subsystem` is host-overridable so each host's logs land under its own
OSLog subsystem.

## Develop

```bash
make build      # release build
make test       # unit tests (live Notes tests gated behind APPLE_TOOLS_NOTES_LIVE=1)
```
