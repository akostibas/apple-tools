# ADR-0001: Adopt PhoneNumberKit for E.164 phone normalization

- Status: Accepted
- Date: 2026-06-27

## Context

Phone numbers in tool output were emitted in whatever shape the source stored
(issue #12): Contacts returned the raw `CNContact` string (`(555) 123-4567`,
`+1 555-123-4567`, `555.123.4567` — all the same number), Messages surfaced raw
handles. An agent reading across Contacts + Messages couldn't treat "the same
number" as equal. We want one canonical output format (E.164) routed through a
single `PhoneFormatting` helper, mirroring the `DateFormatting` fix from #11 /
v0.3.0.

Correct E.164 requires real numbering-plan knowledge: valid lengths per region,
which prefixes exist, how to expand a bare national number, and rejecting
non-numbers (emails, marketing short codes, fictional 555-line numbers). This is
exactly what libphonenumber encodes and what naive digit-munging gets wrong.

`AppleToolsLib` is consumed as a SwiftPM library by other projects (e.g.
Shannon's `probe-macos`), so any dependency we add is inherited by those
consumers. Before this, the library had **zero** external dependencies.

## Decision

Add **PhoneNumberKit** (a Swift port of libphonenumber) as the single
phone-parsing dependency, wrapped behind `PhoneFormatting` so call sites never
touch the library directly.

Track the **maintained 5.x line at the canonical repo**
`github.com/PhoneNumberKit/PhoneNumberKit` (`from: "5.0.0"`, resolves to 5.0.3).

Default region for expanding bare national numbers is the system region,
overridable once at startup via `PhoneFormatting.defaultRegion` (mirrors
`DateFormatting.outputTimeZone` — `AppleToolsLib` may run on a probe whose
machine region differs from the user's).

## Alternatives considered

### Digit-based normalization, no dependency
Strip non-digits, keep a leading `+`, prepend the default country code for bare
national numbers.
- **Pros:** zero dependencies; tiny; fast; keeps the library dependency-free.
- **Cons:** can't validate. Would coerce short codes and fictional/invalid
  numbers into plausible-but-wrong E.164, violating the "never corrupt a value"
  acceptance criterion. No international correctness. We'd be reimplementing a
  worse libphonenumber.

### Original repo `marmelroy/PhoneNumberKit` (4.x line)
- **Pros:** "previous stable major" per the new-but-not-bleeding-edge guideline;
  longest track record.
- **Cons:** the project split on 2026-05-25 — `marmelroy` shipped a final 4.3.0
  and is now **deprecated/unmaintained** (the compiler emits a deprecation
  warning pointing at the new org). An abandoned major gets no security patches,
  which defeats the *reason* the "previous major" rule exists. Rejected:
  maintained beats merely-older. The 5.x API is source-identical, so there is no
  migration cost to taking the maintained line.

### Canonical repo 5.x (chosen)
- **Pros:** actively maintained; receives fixes/security patches; same project,
  same API.
- **Cons:** ~1 month old at adoption (released 2026-05-25). Mitigated: the 5.x
  surface we use (`PhoneNumberUtility.parse`, `.format(_, toType: .e164)`) is
  unchanged from the long-proven 4.x, and we pin a floor of 5.0.0.

## Consequences

- `AppleToolsLib` now has its first external dependency; consumers inherit
  PhoneNumberKit (metadata bundle adds build time and binary size).
- All phone output flows through `PhoneFormatting`; format can't drift per-tool.
- Hard validation is left ON: invalid/fictional numbers and short codes are
  passed through unchanged rather than coerced — conservative by design.
- This is a schema/format change → minor version bump (v0.4.0) and a release tag
  per the project release policy.
- If PhoneNumberKit is ever abandoned again or becomes a liability, the blast
  radius is one file (`PhoneFormatting.swift`); swapping the engine doesn't touch
  call sites.
