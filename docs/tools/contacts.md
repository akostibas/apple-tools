# contacts — Contacts

Look up people in Apple Contacts. Search finds contacts by name, email, phone,
or group name and returns brief summaries; `get` returns the full record for a
single contact by id.

**Access:** read
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
  and type (person/organization).

Run `apple-tools contacts --help` for the exact parameters of each action.

## Examples

```bash
apple-tools contacts search --query "Sam"
apple-tools contacts search --query "acme.com" --limit 5
apple-tools contacts search --query "Family"
apple-tools contacts get --id "<CONTACT-ID>"
```

## Shortcomings

- **Read-only — no create, edit, or delete.** The access policy is `.read` for
  both actions (`ContactsTool.accessPolicy`); there is no add/update/remove path.
  You cannot create a contact, change a field, add to a group, or delete anyone.
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
