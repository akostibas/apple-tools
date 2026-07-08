# ADR-0003: Shared query-term matching for free-text search tools

- Status: Accepted
- Date: 2026-07-08

## Context

Every apple-tools "keyword search" grew its own query-matching, and they
diverged. An audit of all search paths found two levels of sophistication:

- **Email** tokenizes the query (`EmailSearch.tokenize` + stopwords) and
  requires every term to match — AND-of-terms with per-term word-boundary
  precision.
- **Everything else** — Notes, Calendar, iMessage, Voice Memos, Photos labels,
  Contacts names — matches the *whole query as one literal string* (SQL `LIKE`,
  `.contains`, or an Apple framework predicate).

That divergence surfaced as two filed bugs, both from Shannon's unified search
(Shannon-Assistant#886):

- **#45 (notes):** `"Kostibas neighbors"` returns 0 hits even when both words
  are in the same note, because the query is one `body.contains(needle)`
  substring — the words must be adjacent and in order.
- **#46 (contacts):** `"Mike Walter"` returns 0 hits though "Michael Walter"
  exists, because `CNContact.predicateForContacts(matchingName:)` matches the
  whole multi-token string literally and no single field holds "Mike Walter".
  (The issue theorized Apple's *single*-token predicate is nickname-aware —
  live testing disproved this: `"Mike"` finds Michael Walter via his **email**
  `mike@mikewalter.com`, not a "Mike"→"Michael" name expansion. The predicate
  does no such expansion. The fix below follows the corrected mechanism.)

They are the same defect at the concept level — *a multi-term query is never
decomposed into per-term matching* — but they live in different mechanisms
(in-memory substring vs. Apple name predicate). The only code shared across any
search tool today is `SQLEscaping.escapeLIKE`.

## Decision

Extract the **shared principle** — "tokenize a multi-term query, match each term
independently, then AND/intersect" — into a small primitive, and let each tool
keep the **matcher** that makes it correct.

New `QueryTerms` (`Sources/AppleToolsLib/QueryTerms.swift`):

- `tokenize(_:stopwords:)` — lowercase, whitespace-split, drop empties and
  stopwords. Stopwords are a **parameter**, not baked in: `commonStopwords`
  holds only generic English filler (`the/a/of/…`); domain words layer on at the
  call site.
- `allTermsMatch(_:inAnyOf:)` — every term is a case-insensitive **substring**
  of at least one field. AND-of-terms, OR-across-fields.

Adoption:

- **Notes (#45):** default (title) path emits one `LIKE` per token, AND'd;
  `full_text` path matches with `allTermsMatch` over title+body. Snippet centers
  on the first matching term. If stopword stripping empties the query (a bare
  `"the"`), it re-tokenizes with no stopwords, so single-word behavior is
  unchanged.
- **Contacts (#46):** new `searchByNameTokens` matches **each token against
  name, email, and phone** (reusing `searchByName` + `searchByEmailOrPhone`),
  then intersects — the same AND-of-terms model as notes, applied over a
  contact's fields. `"Mike Walter" → Michael Walter` works because `"walter"`
  hits his family name and `"mike"` hits his email local-part; there is no
  nickname expansion, and a contact whose diminutive appears in no field is not
  found. The intersection joins on a **content signature** (resolved name +
  merged emails/phones), not `identifier`, so a person matched via different
  fields for different tokens still joins. Invoked only when the whole-query
  name and email/phone passes both return empty, so direct hits rank first.
  Tokenized with `QueryTerms.tokenize(_, stopwords: [])` (names can be short).
- **Email:** refactored onto `QueryTerms.tokenize`; keeps its `WordBoundary`
  matcher. No behavior change (its tokenize tests pass unmodified).

Contacts and email deliberately share only the tokenizer, not the matcher.

## Alternatives considered

### Fix #45 and #46 in place, no shared code
- **Pros:** smallest diff; each fix is self-contained.
- **Cons:** leaves the same latent bug uncoded in Calendar, iMessage, and Voice
  Memos, and leaves five tools' worth of divergent matching to drift further.
  The next free-text tool inherits nothing. Rejected — treats two symptoms of a
  structural gap as unrelated.

### One universal `QueryMatcher` across every tool
- **Pros:** maximal unification; single place to change matching.
- **Cons:** over-unification. The tools genuinely differ: email needs
  word-boundary matching (so `"mark"` doesn't match `marketing@…`) and
  role-address filtering; contacts matches per token over *structured fields*
  (name/email/phone) and joins on a content signature; notes/messages want plain
  substring over text. A single matcher would break at least one of these
  behaviors, or accrete flags until it is a matcher per tool wearing a trench
  coat. Rejected — force-fitting one mechanism onto three correct-but-different
  behaviors.

### Shared tokenizer + per-tool matcher (chosen)
- **Pros:** fixes both bugs; kills the divergence at the layer that is actually
  common (tokenization + AND combinator); each tool keeps the matcher it needs;
  the primitive is small and fully unit-testable without any live store; the
  next free-text tool gets AND-of-terms for one line.
- **Cons:** two tools still hold matcher-specific code (email's `WordBoundary`,
  contacts' per-token field match + signature join). That is the point, not a
  defect — but it means "search behavior" is not answerable in exactly one file.

## Consequences

- Notes multi-word queries are now AND-of-terms; single-word queries are
  byte-for-byte unchanged (verified by the never-empty stopword fallback). Notes
  output schema is unchanged; snippets may now be mid-note excerpts (leading `…`)
  rather than always the opening line.
- Contacts multi-token queries now match each token across name/email/phone and
  intersect, so `"Mike Walter"` finds "Michael Walter". This is field-tolerance,
  not nickname expansion — a diminutive present in no field is still not found.
  A single-token query is unaffected (the pass declines <2 tokens). Two tokens
  matching different people intersect to nothing, as intended.
- Email is unchanged in behavior; it now sources its tokenizer from `QueryTerms`.
- **Calendar, iMessage, and Voice Memos still match the whole query literally** —
  the same latent bug as #45. They are out of scope here and tracked in #47 to
  adopt `QueryTerms.allTermsMatch`. This ADR is the record that the gap is known
  and deliberately staged, not overlooked.
- Per the release policy, the notes and contacts behavior changes are new
  functionality → minor version bump + release tag.
