# imessage — Messages (iMessage/SMS)

Read your Messages history and send new iMessages/SMS. Reading queries the
Messages `chat.db` directly (conversations, message bodies, attachments);
sending drives Messages.app via AppleScript and routes over iMessage or SMS
automatically. Phone numbers and emails are auto-resolved to Contacts names on
output.

**Access:** read/write (send is supported — it actually delivers, unlike
`email`, which only drafts)
**Permissions:** Full Disk Access to read `~/Library/Messages/chat.db`
(`preflight` opens it `SQLITE_OPEN_READONLY`); Automation → Messages to send
(`preflight` runs an AppleScript `tell application "Messages"` that triggers the
automation-consent dialog). Reading attachments off iCloud also needs the file
downloaded locally.

## Actions

- **recent** — conversations with recent activity, newest first (`limit`,
  optional `since`; `exclude_spam`/`humans_only` to drop flagged senders).
  Each entry carries an unread count, last-message preview, and `is_likely_spam`
  / `is_shortcode` flags.
- **stats** — rank conversations by message volume with a sent/received split
  over an optional `since` window (`limit`, `since`, `exclude_spam`).
- **read** — messages from one conversation (`chat` = phone/email/group
  name/`chat_id`; `limit`, `before`). Paginates via an opaque `next_before`
  cursor; ambiguous `chat` returns `multiple_matches` for you to pick a
  `chat_id`.
- **search** — find messages by text content (`query`; optional `chat` filter,
  `since`, `before`, `limit`). Matches the message `text` column with `LIKE`.
- **send** — send a message (`to` = phone/email/`chat_id`, `text`; optional
  `attachments` = absolute file paths, `~` expanded, each ≤100MB, max 10).
- **fetch_attachment** — retrieve one attachment's bytes from a message
  (`message_id` from a read/search result; optional `filename` to pick among
  multiple). Images are resized for LLM vision.

Run `apple-tools imessage --help` for the exact parameters of each action.

## Examples

```bash
apple-tools imessage recent --limit 10 --humans-only
apple-tools imessage read --chat "+16502530000" --limit 20
apple-tools imessage search --query "dinner reservation" --since 2026-07-01
apple-tools imessage send --to "+16502530000" --text "On my way" --attachments ~/map.png
```

## Shortcomings

- **No group-chat creation, and no participant management.** `send` addresses an
  *existing* thread or a 1:1 handle; there's no way to create a new group, name
  one, or add/remove members. Sending to a group requires an already-existing
  `chat_id` (resolved via its GUID).
- **No reactions/tapbacks, edits, unsends, or delete.** The write surface is a
  single `send`. You can't react to a message, edit or unsend one, mark a thread
  read, or delete anything — those Messages features have no action.
- **`send` confirms acceptance, not delivery.** AppleScript returns success the
  moment Messages.app *accepts* the message; the response is `status: "sending"`.
  A background check reads `chat.db` ~4s later and only surfaces a failure when
  the `error` column is non-zero. A missing delivery receipt (`is_delivered = 0`)
  is deliberately *not* treated as a failure (recipient asleep, receipts off,
  network lag), so "sent" here does not guarantee the recipient got it.
- **iMessage vs SMS routing is automatic and not user-controllable.** The
  transport is chosen for you (iMessage, falling back to SMS for phone numbers).
  You can't force a channel — and **attachments are iMessage-only**: a send with
  attachments to an SMS-only recipient is refused (SMS fallback is disabled when
  attachments are present).
- **`search` only scans the plain `text` column.** Its `WHERE` requires
  `m.text IS NOT NULL AND m.text != ''`, so messages whose body lives *only* in
  the `attributedBody` blob (e.g. some formatted or edited messages) are
  invisible to search — even though `read`/`recent` decode that blob for display.
- **`attributedBody` decoding is a best-effort byte scan.** Bodies are recovered
  by locating an `NSString` marker and reading a typedstream varint length; if
  the layout doesn't match, `text` comes back empty rather than raising an error.
- **`read`/`search` don't filter out associated (reaction) rows by `item_type`.**
  `recent`'s unread count and `stats` restrict to `item_type = 0`, but `read` and
  `search` have no such filter, so tapback/system rows can appear in a
  conversation's message list.
- **Attachments not downloaded from iCloud can't be fetched.** `fetch_attachment`
  reads the on-disk file at the stored path; if the attachment has no local file
  (iCloud-only, never downloaded), it fails with a "may be stored in iCloud"
  error.
- **Spam filtering is opt-in and heuristic.** `is_likely_spam`/`is_shortcode`
  flags are always present, but nothing is dropped unless you pass
  `--exclude-spam`/`--humans-only`, and the classifier keys off undocumented
  `(smsfp)`/`(smsft)` SMS-filter suffixes plus 5–6 digit short codes — a real
  contact match always wins, so anyone in Contacts is never flagged.
```
