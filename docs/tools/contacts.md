# contacts — Contacts

Look up people in Apple Contacts. Search finds contacts by name, email, phone,
or group name and returns brief summaries; `get` returns the full record for a
single contact by id; `create` and `update` add and edit contacts.

**Access:** read/write
**Permissions:** Contacts (TCC). First access triggers the system dialog; grant
in System Settings → Privacy & Security → Contacts.

## Actions

- **search** — find contacts by `query`, which matches name, email substring,
  phone-digit substring, or group name. Returns **summaries only** — `id`,
  `name`, `organization`, and the *first* email and phone. `limit` caps results
  (default 20).
- **get** — full details for one contact by `id` (from a search result): all
  emails/phones with labels, postal addresses, URLs, birthday and other dates,
  relations, social profiles, IM handles, job/department, nickname, prefix/suffix,
  and type (person/organization), plus `accounts`: every account (iCloud,
  Google, Exchange, …) holding a card for this person, since Contacts merges
  linked cards into one.
- **create** — add a contact using the same fields as `update` (`add_phone`,
  `add_email`, … for its first entries). Goes to the default account, or the
  one named by `account`. Refused when an existing contact has the same full
  name, any of the same phones (compared ignoring formatting), or any of the same
  emails; the error names that contact's id so the caller can update it instead.
  Needs at least a name, company, phone, or email.
- **update** — edit a contact by `id`. Set or clear (empty string) name parts,
  nickname, organization, job title, and department; set `birthday` (YYYY-MM-DD,
  MM-DD, or `none`). Phones, emails, URLs, and addresses change one entry at a
  time with `add_*` / `remove_*`; every other entry is left alone. `label` names
  what's added (home, work, mobile, …). Removing a value the contact doesn't have
  is an error. Returns the updated contact.

Run `apple-tools contacts --help` for the exact parameters of each action.

## Examples

```bash
apple-tools contacts search --query "Sam"
apple-tools contacts search --query "acme.com" --limit 5
apple-tools contacts search --query "Family"
apple-tools contacts get --id "<CONTACT-ID>"
apple-tools contacts create --given_name Priya --family_name Shah --add_phone "415 555 0199" --label mobile
apple-tools contacts update --id "<CONTACT-ID>" --remove_phone "415 555 0101" --add_phone "415 555 0199" --label mobile
```

## Shortcomings

- **No delete, merge, photo, or group edits.**
- **`accounts` costs a scan.** Apple has no direct lookup, so `get` checks each
  account's member list; fast for hundreds of contacts per account.
- **Notes and relations/dates/social profiles can't be edited.** Apple gates the
  contact note behind a special entitlement; the others just aren't wired up.
- **One add and one remove per kind per call.** To add two phones, call twice.
- **Read-only accounts fail at save.** Contacts from an account you can't edit
  (e.g. a company directory) return the save error with a hint to edit them there.
- **`search` returns summaries only — one email and one phone.** `contactSummary`
  emits only `emailAddresses.first` and `phoneNumbers.first`, and omits postal
  addresses, birthdays, additional emails/phones, and all other fields entirely.
  Use `get` (the only path through `contactFull`) to see the complete record.
- **Email/phone search is capped at 100 matches and scanned live.** CNContact has
  no native email/phone predicate, so `searchByEmailOrPhone` enumerates the whole
  address book and stops at 100 matches. In a large address book, a match past
  the 100th enumerated hit won't surface.
- **Phone matching is raw digit-substring.** The query's digits must appear
  contiguously in a stored number's digits (`digits.contains(normalizedQuery)`) —
  there's no country-code normalization here, so searching a bare 10-digit number
  won't match a stored value only if the digit sequences differ. (The E.164-tolerant
  trailing-10-digit matching in `resolveNames` is used elsewhere, not by `search`.)
- **Group matches are lowest priority and can be dropped by `limit`.** Contacts in
  a group whose *name* matches the query are appended only after name and
  email/phone matches, and only if the result count is still under `limit`. If
  name/email/phone matches already fill `limit`, group-only members never appear.
- **Failures are silent, returning empty results.** `searchByName`,
  `searchByEmailOrPhone`, and `contactIDsInMatchingGroups` all swallow framework
  errors and return empty — a failed name predicate or group lookup looks
  identical to "no matches" rather than surfacing an error.
