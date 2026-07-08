import Foundation

/// Shared free-text query decomposition for the "keyword search" tools.
///
/// The problem this solves: a multi-word query like `"Kostibas neighbors"`
/// should match a note that contains *both* words, in any order, not only the
/// exact adjacent phrase. Historically each tool matched the whole query as one
/// literal substring, so only `notes`-style adjacency hit — email was the lone
/// outlier that already tokenized. This is the extracted, shared primitive so
/// every free-text tool gets the same AND-of-terms semantics. See
/// docs/adr/0003-shared-query-term-matching.md.
///
/// Deliberately small: tokenize + an "all terms present" combinator. It does
/// NOT own the per-term matcher — callers choose substring (`allTermsMatch`)
/// vs. word-boundary (email's `WordBoundary`) vs. an Apple framework predicate
/// (contacts' per-token `predicateForContacts`). Forcing one matcher on all of
/// them would break the behaviors that make each tool correct (email's
/// role-address noise filtering, contacts' nickname map).
public enum QueryTerms {

    /// Generic English filler words with no search signal, stripped before
    /// matching. Kept tiny on purpose. Domain-specific stopwords (e.g. email's
    /// "mail"/"message") are layered on by the caller via the `stopwords`
    /// parameter rather than baked in here — a word that is noise in email
    /// ("message") can be signal in notes.
    public static let commonStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "for",
    ]

    /// Split a free-text query into lowercased, AND-able tokens: lowercase,
    /// split on whitespace, drop empties and any stopword. Returns an empty
    /// array when nothing usable remains (all-whitespace, or every token was a
    /// stopword) — callers decide what that means (email treats it as "no query
    /// filter"; notes falls back to matching the raw query literally).
    ///
    /// Pass `stopwords: []` to tokenize without stripping — the right choice for
    /// name matching, where short tokens can be meaningful.
    public static func tokenize(_ query: String, stopwords: Set<String> = commonStopwords) -> [String] {
        return query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty && !stopwords.contains($0) }
    }

    /// True iff **every** term in `terms` appears as a case-insensitive
    /// substring of at least one field in `fields`. This is AND-of-terms with
    /// OR-across-fields: `["kostibas", "neighbor"]` matches a note whose title
    /// holds "Kostibas" and whose body mentions "neighbors".
    ///
    /// Substring (not word-boundary) matching by design — `"neighbor"` should
    /// match "neighbors", and partial-word queries are expected in note/message
    /// search. Callers that need word-boundary precision (email) use their own
    /// matcher. Empty `terms` returns false: an empty query is "no match here",
    /// never "match everything".
    ///
    /// `terms` are assumed already lowercased (as `tokenize` returns them); the
    /// fields are lowercased here.
    public static func allTermsMatch(_ terms: [String], inAnyOf fields: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let haystacks = fields.map { $0.lowercased() }
        return terms.allSatisfy { term in
            haystacks.contains { $0.contains(term) }
        }
    }
}
