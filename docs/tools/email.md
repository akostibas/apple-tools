# email — Mail

Read Apple Mail and stage outgoing messages. Reading spans every account's
mailboxes; writing only ever creates **drafts** (a compose window you review) —
this tool never sends.

**Access:** read + draft
**Permissions:** Full Disk Access (reads Mail's on-disk `.emlx` store and the
Envelope Index; also used by the AppleScript fallback).

## Actions

- **inbox** — recent messages across all accounts' inboxes (previews only).
- **search** — find messages by query / sender / recipient / date across all
  mail (previews only). Matches subject, sender, and body *preview* — not the
  full body.
- **read** — full message by `id`: body, recipients, attachment metadata.
- **fetch_attachment** — retrieve one attachment's bytes from a message (returns
  a local `path`; images are resized for LLM vision).
- **draft** — create a new draft (`to`, `subject`, `body`, `cc`, `attachments`).
  Does not send.
- **reply** — draft a reply to a message by `id`. Builds a "Re:" subject,
  addresses the original sender (`reply_all` folds in the other recipients), and
  quotes the original in a real indented `<blockquote>`. Put **only** your new
  text in `body` — the original is quoted automatically. Does not send.

Run `apple-tools email --help` for the exact parameters of each action.

## Examples

```bash
apple-tools email search --from "sam" --after 2026-07-01
apple-tools email read --id "<MESSAGE-ID>"
apple-tools email reply --id "<MESSAGE-ID>" --body "Sounds great, thanks!"
apple-tools email draft --to a@b.com --subject "Hi" --body "…" --attachments ~/f.pdf
```

## Shortcomings

- **Replies aren't header-threaded.** `reply` composes a *new* message — it
  carries no `In-Reply-To`/`References` headers (AppleScript can't set them), so
  the recipient's client threads it by "Re:" subject only. Outlook/Exchange,
  which thread by conversation id, may show it as a separate message. True
  threading would need Mail's native `reply` (unusable — see below) or IMAP
  APPEND (new per-account auth).
- **`reply` reads the original from the inbox only.** The quote is built from an
  INBOX AppleScript read, so replying to archived/non-inbox mail fails to find
  the original (unlike `read`, which also resolves archived mail).
- **The quoted original is re-rendered, not mirrored.** We quote Mail's
  plain-text rendering of the body; the original's own HTML formatting, inline
  images, and attachments are not reproduced in the quote.
- **`search` doesn't scan full bodies.** Query tokens match subject, sender, and
  the body *preview* only — a word that appears deep in a long body won't match.
- **AppleScript fallbacks are INBOX-only and slow.** `read`/`fetch_attachment`
  fall back to AppleScript for mailbox layouts the Envelope Index fast path
  can't resolve; that fallback scans INBOX only and is impractically slow on
  large IMAP mailboxes (e.g. `[Gmail]/All Mail`).
- **No send / delete / modify.** By design — the tool only reads and drafts.

## Why `reply` doesn't use Mail's native reply

Mail's `reply` command produces a correctly-threaded HTML reply, but its body is
only reachable through the plain `content` property — which, on Exchange/Outlook
HTML replies, reads empty and silently discards writes, so drafted text never
lands. Setting `html content` at *creation* time (our approach) is the reliable
path, at the cost of the threading headers above.
