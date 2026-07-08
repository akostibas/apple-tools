import Contacts
import Foundation

/// Shared Apple Contacts (CNContactStore) integration. All Contacts framework
/// access lives here.
///
/// Consumers: ContactsTool (LLM tool wrapper) and any future contacts
/// integration point.
///
/// Design: stateless enum with static methods. A single shared CNContactStore
/// is retained internally so callers don't need to manage lifecycle.
public enum ContactsIntegration {

    private static let store = CNContactStore()

    public enum ContactsError: Error, CustomStringConvertible {
        case accessDenied
        case fetchFailed(String)
        case notFound(String)

        public var description: String {
            switch self {
            case .accessDenied:
                return "Contacts access denied. Grant permission in System Settings → Privacy & Security → Contacts."
            case .fetchFailed(let reason):
                return "failed to fetch contact: \(reason)"
            case .notFound(let id):
                return "no contact found with id: \(id)"
            }
        }
    }

    // MARK: - Access

    public static func requestAccess() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false

        store.requestAccess(for: .contacts) { result, _ in
            granted = result
            semaphore.signal()
        }

        semaphore.wait()
        return granted
    }

    public static func preflight() -> (ok: Bool, message: String) {
        let granted = requestAccess()
        return (granted, granted ? "contacts access granted" : "contacts access denied")
    }

    // MARK: - Search

    /// Search contacts by name using the Contacts framework predicate.
    /// Errors during the framework call are swallowed — empty results are
    /// returned so the caller can fall through to other search modes.
    public static func searchByName(query: String, keys: [CNKeyDescriptor]) -> [CNContact] {
        let predicate = CNContact.predicateForContacts(matchingName: query)
        return (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
    }

    /// Keys `searchByNameTokens` must fetch so its identity signature (name +
    /// contact points) can be computed without hitting an unfetched-property
    /// exception. Merged with whatever display keys the caller wants.
    private static let identityFetchKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactMiddleNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
    ]

    /// Multi-token name search: AND-of-terms across a contact's searchable
    /// fields (issue #46). A whole multi-token string like `"Mike Walter"` is
    /// matched literally by `predicateForContacts(matchingName:)` and misses
    /// "Michael Walter". So match **each token independently against name, email,
    /// and phone**, then keep the people every token hit — the same
    /// AND-of-terms model as notes search, applied over a contact's fields
    /// instead of a note's title/body.
    ///
    /// `"Mike Walter" → Michael Walter` works because `"walter"` matches his
    /// family name and `"mike"` matches his email local-part
    /// (`mike@mikewalter.com`) — NOT because of any nickname map. (Apple's name
    /// predicate does *not* expand "Mike"→"Michael"; the issue's premise that it
    /// does was mistaken — the observed single-token hit was the email match.)
    /// **Limitation:** a contact whose diminutive appears in no field at all
    /// (a "Michael Walter" with no "mike" anywhere) still won't be found — true
    /// diminutive expansion would need a nickname dictionary, out of scope here.
    ///
    /// The per-token sets are joined on a **content signature** (resolved name +
    /// merged emails/phones), not on `identifier`, so a person matched via
    /// different passes/cards for different tokens still joins — and different
    /// people stay distinct. Needs ≥2 tokens (a single token is `searchByName`'s
    /// job → returns [] here). Disjoint tokens (`"Mike Karen"`) intersect to
    /// nothing. Errors are swallowed, consistent with `searchByName`.
    ///
    /// Only invoked as a fallback when the direct passes whiff, so the extra
    /// per-token address-book enumeration (via `searchByEmailOrPhone`) is off
    /// the hot path.
    public static func searchByNameTokens(query: String, keys: [CNKeyDescriptor]) -> [CNContact] {
        // No stopwords: names can legitimately be short ("Al", "Bo").
        let tokens = QueryTerms.tokenize(query, stopwords: [])
        guard tokens.count >= 2 else { return [] }

        // Fetch the identity keys (incl. nickname) so identityKey never touches
        // an unfetched property, on top of the caller's display keys.
        var fetchKeys = keys
        for k in identityFetchKeys where !fetchKeys.contains(where: { ($0 as? String) == (k as? String) }) {
            fetchKeys.append(k)
        }

        var bySignature: [String: CNContact] = [:]
        var perToken: [Set<String>] = []
        for token in tokens {
            // "matches this token" = name OR email OR phone, the same fields the
            // single-query search covers.
            let candidates = searchByName(query: token, keys: fetchKeys)
                + searchByEmailOrPhone(query: token, keys: fetchKeys)
            var sigs = Set<String>()
            for c in candidates {
                let sig = identityKey(for: c)
                sigs.insert(sig)
                if bySignature[sig] == nil { bySignature[sig] = c }
            }
            // A token nobody matches makes the intersection empty; bail early.
            if sigs.isEmpty { return [] }
            perToken.append(sigs)
        }

        return intersectAll(perToken).compactMap { bySignature[$0] }
    }

    /// A content-derived identity for a unified contact, stable across separate
    /// name-token queries (see `searchByNameTokens`). Resolved name plus the
    /// sorted, normalized merged emails and phones — the same person yields the
    /// same key whichever token matched them; two different people don't collide
    /// unless they share a name AND every contact point.
    static func identityKey(for c: CNContact) -> String {
        let name = resolvedName(for: c).lowercased()
        let emails = c.emailAddresses
            .map { ($0.value as String).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
        let phones = c.phoneNumbers
            .map { phoneKey($0.value.stringValue.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) }
            .filter { !$0.isEmpty }
            .sorted()
        return ([name] + emails + phones).joined(separator: "|")
    }

    /// Intersect per-token key sets: the entries every token matched. Pure, so
    /// the AND semantics are unit-testable without a live CNContactStore. Empty
    /// input → empty set.
    static func intersectAll(_ sets: [Set<String>]) -> Set<String> {
        guard let first = sets.first else { return [] }
        return sets.dropFirst().reduce(first) { $0.intersection($1) }
    }

    /// Search contacts by email substring or phone-digit substring. CNContact
    /// has no native predicate for these, so we enumerate (capped at 100
    /// matches) and filter.
    public static func searchByEmailOrPhone(query: String, keys: [CNKeyDescriptor]) -> [CNContact] {
        var matches: [CNContact] = []
        let queryLower = query.lowercased()
        let normalizedQuery = query.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()

        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName

        do {
            try store.enumerateContacts(with: request) { contact, stop in
                for email in contact.emailAddresses {
                    if (email.value as String).lowercased().contains(queryLower) {
                        matches.append(contact)
                        if matches.count >= 100 { stop.pointee = true }
                        return
                    }
                }

                if !normalizedQuery.isEmpty {
                    for phone in contact.phoneNumbers {
                        let digits = phone.value.stringValue.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                        if digits.contains(normalizedQuery) {
                            matches.append(contact)
                            if matches.count >= 100 { stop.pointee = true }
                            return
                        }
                    }
                }
            }
        } catch {
            // enumeration failed; return what we have
        }

        return matches
    }

    /// Find contact identifiers belonging to any group whose name contains
    /// the query (case-insensitive). Errors are swallowed.
    public static func contactIDsInMatchingGroups(query: String) -> Set<String> {
        let queryLower = query.lowercased()
        var contactIDs = Set<String>()

        do {
            let groups = try store.groups(matching: nil)
            let matchingGroups = groups.filter { $0.name.lowercased().contains(queryLower) }

            for group in matchingGroups {
                let predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
                let contacts = try store.unifiedContacts(
                    matching: predicate,
                    keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
                )
                for contact in contacts {
                    contactIDs.insert(contact.identifier)
                }
            }
        } catch {
            // group search failed; return empty set
        }

        return contactIDs
    }

    /// Fetch contacts by their identifiers, with the requested key set.
    public static func contactsByIdentifiers(_ ids: [String], keys: [CNKeyDescriptor]) -> [CNContact] {
        guard !ids.isEmpty else { return [] }
        let predicate = CNContact.predicateForContacts(withIdentifiers: ids)
        return (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
    }

    // MARK: - Batched name resolution

    /// Resolve a batch of message handles (E.164 phone numbers or emails) to
    /// contact display names in a single pass over the address book.
    ///
    /// Used to annotate iMessage output with `contact_name` by default. Returns
    /// a map of `identifier → display name` containing only identifiers that
    /// matched a contact; unmatched identifiers are simply absent so callers can
    /// fall back to the raw handle.
    ///
    /// Best-effort: if Contacts access is denied or enumeration fails, returns an
    /// empty map rather than throwing, so output degrades to raw handles.
    ///
    /// Phone matching is country-code tolerant: numbers are compared by their
    /// trailing 10 digits (the US national number) when long enough, so a stored
    /// `(555) 123-4567` matches an E.164 `+15551234567`.
    public static func resolveNames(forIdentifiers identifiers: [String]) -> [String: String] {
        let cleaned = identifiers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [:] }
        guard requestAccess() else { return [:] }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        var emailMap: [String: String] = [:]   // lowercased email → name
        var phoneMap: [String: String] = [:]   // phoneKey(digits) → name

        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = resolvedName(for: contact)
                guard !name.isEmpty else { return }
                for email in contact.emailAddresses {
                    let key = (email.value as String).lowercased()
                    if !key.isEmpty, emailMap[key] == nil { emailMap[key] = name }
                }
                for phone in contact.phoneNumbers {
                    let digits = phone.value.stringValue
                        .components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                    guard !digits.isEmpty else { continue }
                    let key = phoneKey(digits)
                    if phoneMap[key] == nil { phoneMap[key] = name }
                }
            }
        } catch {
            return [:]
        }

        var result: [String: String] = [:]
        for id in cleaned {
            if id.contains("@") {
                if let name = emailMap[id.lowercased()] { result[id] = name }
            } else {
                let digits = id.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                guard !digits.isEmpty else { continue }
                if let name = phoneMap[phoneKey(digits)] { result[id] = name }
            }
        }
        return result
    }

    /// Normalize a digit string to a comparison key: the trailing 10 digits for
    /// long numbers (drops country code), the full string for short codes.
    static func phoneKey(_ digits: String) -> String {
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    /// Build a human display name for a contact, preferring full name, then
    /// nickname, then organization.
    static func resolvedName(for contact: CNContact) -> String {
        var parts: [String] = []
        if !contact.givenName.isEmpty { parts.append(contact.givenName) }
        if !contact.middleName.isEmpty { parts.append(contact.middleName) }
        if !contact.familyName.isEmpty { parts.append(contact.familyName) }
        let full = parts.joined(separator: " ")
        if !full.isEmpty { return full }
        if !contact.nickname.isEmpty { return contact.nickname }
        return contact.organizationName
    }

    // MARK: - Get

    /// Fetch a single contact by identifier. Throws ContactsError on framework
    /// errors or when no match is found.
    public static func contact(byIdentifier id: String, keys: [CNKeyDescriptor]) throws -> CNContact {
        let predicate = CNContact.predicateForContacts(withIdentifiers: [id])
        let contacts: [CNContact]
        do {
            contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        } catch {
            throw ContactsError.fetchFailed(error.localizedDescription)
        }
        guard let contact = contacts.first else {
            throw ContactsError.notFound(id)
        }
        return contact
    }
}
