# email — Mail

Read Apple Mail and stage outgoing messages. Reading spans every account's
mailboxes; writing only ever creates **drafts**, saved in the Drafts mailbox for
you to review — this tool never sends. Drafting opens no window.

**Access:** read + draft
**Permissions:** Full Disk Access (reads Mail's on-disk `.emlx` store and the
Envelope Index; also used by the AppleScript fallback).

## Actions

- **inbox** — recent messages across all accounts' inboxes (previews only).
  Never opens Mail. With Mail closed the result carries a `warning`: the list
  is as of Mail's last run, and it's the caller's call whether to open Mail.
- **search** — find messages by query / sender / recipient / date across all
  mail (previews only). Matches subject, sender, and body *preview* — not the
  full body. `--has_attachments` keeps only messages with at least one
  attachment, and works as the only filter.
- **read** — full message by `id`: body, recipients, attachment metadata.
- **headers** — a message's headers by `id`, all or only the `names` asked for
  (case-insensitive). Keys come back lowercased, each with every value (repeats
  like `Received` keep all of them). Never downloads the body, so it's cheap
  enough to call per message after a search.
- **fetch_attachment** — retrieve one attachment's bytes from a message (returns
  a local `path`; images are resized for LLM vision).
- **draft** — create a new draft (`to`, `subject`, `body`, `cc`, `attachments`),
  saved in Drafts. Does not send. Returns the draft's `id`, which is only for
  `discard` — it is not a message id, so `read` won't take it.
- **reply** — draft a reply to a message by `id`. Builds a "Re:" subject,
  addresses the original sender (`reply_all` folds in the other recipients), and
  quotes the original in a real indented `<blockquote>`. Put **only** your new
  text in `body` — the original is quoted automatically. Does not send. Returns
  the draft's `id`.
- **discard** — move a draft to its account's Trash by the `id` that `draft` or
  `reply` returned. Only drafts are accepted: a message anywhere but a Drafts
  mailbox (received, sent, archived, already trashed) is refused, so this can't
  delete real mail. Nothing is erased; the draft can be recovered from Trash.
  Once a draft has been sent, its id is refused too. Needs Mail running; it
  never launches Mail.
- **mailboxes** — each account's mailboxes with total/unread counts, and whether
  the account allows `move` (Gmail doesn't). Names are what `--mailbox` takes.
  Accounts whose Mail is switched off in System Settings are left out; pass
  `include_disabled` to list them too (marked `disabled`), or name one with
  `account`.
- **move** — move a message by `id` to `mailbox`, in its own account or another
  one (`account` picks which when the name is ambiguous). Needs Mail running; it
  never launches Mail. Refused for Gmail accounts and for Drafts (see
  Shortcomings).

`search --mailbox <name>` keeps only messages in that mailbox. Gmail stores every
message in All Mail, so for Gmail it matches on labels, and results carry a
`labels` list (e.g. `INBOX`, `Mint`) alongside `mailbox`.

`inbox` and `search` take `exclude_accounts`, a list of account names to leave
out before the limit applies. Names only, because two accounts can share an
address. A name that matches no account is ignored.

`inbox` and `search` rows carry `attachment_count` when a message has
attachments (omitted when it has none), so there's no need to `read` each one
to find the message with the file.

`inbox`, `search` and `read` results name the Mail account each message is in:
`account` (as shown in Mail, e.g. "iCloud") and `account_email` when known.
It comes from the account the message is filed in, not from headers, so it
can't be spoofed by the sender. It's omitted if the system Accounts store
can't be read.

Run `apple-tools email --help` for the exact parameters of each action.

## Examples

```bash
apple-tools email search --from "sam" --start 2026-07-01
apple-tools email search --has_attachments --start 2026-07-01
apple-tools email read --id "<MESSAGE-ID>"
apple-tools email headers --id "<MESSAGE-ID>" --names Sender,X-Google-Calendar-Notification
apple-tools email reply --id "<MESSAGE-ID>" --body "Sounds great, thanks!"
apple-tools email draft --to a@b.com --subject "Hi" --body "…" --attachments ~/f.pdf
apple-tools email discard --id "<ID-RETURNED-BY-DRAFT>"
```

## Shortcomings

- **Gmail messages can't be moved.** Mail's scripting can add a Gmail label but
  can't reliably take one away: Mail shows the move, then Gmail puts the message
  back on the next sync. Removing a label via a round-trip through Trash held
  once and reverted the next time. Moving a Gmail message is refused. Use Mail
  or Gmail directly; a real fix would need the Gmail API and a Google sign-in.
- **Nothing can be moved into or out of Drafts.** Mail keeps saving whatever
  sits in Drafts, so a message moved out showed up there again about a minute
  later. `move` refuses Drafts as a source or a destination. Use `discard` to
  trash a draft, or move it in Mail.
- **A message with copies in several mailboxes can't be moved.** Mail you sent
  yourself sits in both Sent and the inbox under one id, so `move` can't tell
  which copy is meant and refuses, naming the mailboxes. Move it in Mail. Copies
  that share a mailbox (a draft Mail saved twice, then discarded) move together,
  and the result says how many under `copies`.
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
- **Discarding a draft made in the last 45 seconds is slow.** On Gmail and
  iCloud, Mail saves a new draft a second time 10 to 30 seconds after the
  first, which would bring a just-discarded draft back. `discard` waits that
  out and trashes the second copy as well, so both copies end up in Trash and
  the call can take up to 45 seconds. Older drafts are discarded at once.
- **`draft`/`reply` can come back without an `id`.** If Mail is slow to file the
  draft, the result carries a `note` instead, and that draft can only be
  deleted in Mail.
- **`discard` works on iCloud, Gmail and other IMAP accounts only.** Those are
  the kinds it has been shown to hold on, checked again after a sync. Drafts in
  On My Mac or an Exchange account are refused, as is any account set to erase
  deleted messages instead of moving them to Trash. Delete those in Mail.
- **No send, and no deleting or changing real mail.** By design — the tool
  reads, drafts, and discards its drafts.

## Why `reply` doesn't use Mail's native reply

Mail's `reply` command produces a correctly-threaded HTML reply, but its body is
only reachable through the plain `content` property — which, on Exchange/Outlook
HTML replies, reads empty and silently discards writes, so drafted text never
lands. Setting `html content` at *creation* time (our approach) is the reliable
path, at the cost of the threading headers above.

## Testing gaps

What `make test` can't prove for this tool (see [Tests/README.md](../../Tests/README.md)).

- **Received mail can't be planted.** If a read comes back empty, only the remembered messages or a look in Mail can tell "none" from "broken".
- **Attachment fetch is only proven on a draft**, the test's own. Fetching from received mail, where Mail may not have downloaded the attachment yet, is not.
- **Move is only proven within one account**, on the test's own trashed draft: Trash to Archive and back. It needs an account that isn't Gmail, has an Archive mailbox and an address no other account shares; without one the test skips. Moves between accounts are not proven.
- **The reply test drafts a reply to one of your real messages**, since a reply needs one: an inbox message you sent yourself, otherwise one from a no-reply address, otherwise it skips. The original is only read. The draft quotes it, is never sent, and is discarded; if the discard fails the test fails and names the draft.
- **Each test leaves its draft in Trash** and takes about a minute, because a fresh draft can't be discarded quickly. The drafts are labeled `apple-tools live test` in the subject, except the reply, whose subject is `Re:` plus the original's and which carries the label in its body. The reply lands in the Trash of whichever account Mail drafts from, which may not be the account the original is in.
