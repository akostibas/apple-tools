import Contacts
import Foundation

public struct ContactsTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "contacts",
        description: "Access Apple Contacts. Actions: 'search' (find contacts by name, email, phone, or group name; returns summaries only — street addresses, birthdays, and any additional emails/phones are NOT included), 'get' (full details for a contact by ID; the only way to see addresses and other non-summary fields), 'update' (edit a contact by ID: set single fields, or add/remove one phone, email, URL, or address at a time; other entries are left alone).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "search, get, or update"),
                "given_name": PropertySchema(type_: "string", description: "First name (update; empty string clears)", summary: "First name", actions: ["update"]),
                "middle_name": PropertySchema(type_: "string", description: "Middle name (update; empty string clears)", summary: "Middle name", actions: ["update"]),
                "family_name": PropertySchema(type_: "string", description: "Last name (update; empty string clears)", summary: "Last name", actions: ["update"]),
                "nickname": PropertySchema(type_: "string", description: "Nickname (update; empty string clears)", summary: "Nickname", actions: ["update"]),
                "prefix": PropertySchema(type_: "string", description: "Name prefix, e.g. Dr. (update; empty string clears)", summary: "Name prefix", actions: ["update"]),
                "suffix": PropertySchema(type_: "string", description: "Name suffix, e.g. Jr. (update; empty string clears)", summary: "Name suffix", actions: ["update"]),
                "organization": PropertySchema(type_: "string", description: "Company (update; empty string clears)", summary: "Company", actions: ["update"]),
                "job_title": PropertySchema(type_: "string", description: "Job title (update; empty string clears)", summary: "Job title", actions: ["update"]),
                "department": PropertySchema(type_: "string", description: "Department (update; empty string clears)", summary: "Department", actions: ["update"]),
                "birthday": PropertySchema(type_: "string", description: "Birthday as YYYY-MM-DD, or MM-DD when the year is unknown; 'none' clears (update)", summary: "YYYY-MM-DD or MM-DD ('none' clears)", actions: ["update"]),
                "add_phone": PropertySchema(type_: "string", description: "Phone number to add (update)", summary: "Phone to add", actions: ["update"]),
                "add_email": PropertySchema(type_: "string", description: "Email to add (update)", summary: "Email to add", actions: ["update"]),
                "add_url": PropertySchema(type_: "string", description: "URL to add (update)", summary: "URL to add", actions: ["update"]),
                "add_address": PropertySchema(type_: "string", description: "Address to add as 'street; city; state; postal code; country' (trailing parts optional; update)", summary: "'street; city; state; postal code; country'", actions: ["update"]),
                "label": PropertySchema(type_: "string", description: "Label for whatever is added: home, work, mobile, iphone, main, school, other, or a custom label (update; default other)", summary: "Label for added entries (home, work, mobile, …)", actions: ["update"]),
                "remove_phone": PropertySchema(type_: "string", description: "Phone number to remove; matched by digits, so formatting doesn't matter (update)", summary: "Phone to remove", actions: ["update"]),
                "remove_email": PropertySchema(type_: "string", description: "Email to remove, case-insensitive (update)", summary: "Email to remove", actions: ["update"]),
                "remove_url": PropertySchema(type_: "string", description: "URL to remove (update)", summary: "URL to remove", actions: ["update"]),
                "remove_address": PropertySchema(type_: "string", description: "Address to remove: its street line, or the full address as 'get' shows it (update)", summary: "Address (street line) to remove", actions: ["update"]),
                "query": PropertySchema(type_: "string", description: "Search term — matches name, email, phone, or group name (required for search). A multi-word query requires each word to match some field (name/email/phone) of the same contact, so 'Mike Walter' finds 'Michael Walter' when a field carries each word",
                    summary: "Search term matched across name, email, phone, group", actions: ["search"]),
                "limit": PropertySchema(type_: "integer", description: "Max results to return (for search, default 20)",
                    summary: "Max results (default 20)", actions: ["search"]),
                "id": PropertySchema(type_: "string", description: "Contact identifier from search results (required for get, update)",
                    summary: "Contact ID from search results", actions: ["get", "update"]),
            ],
            required: ["action"]
        ),
        cliSummary: "Search, read, and edit Apple Contacts.",
        actions: [
            ActionHelp(name: "search", summary: "Find contacts by name, email, phone, or group",
                example: "apple-tools contacts search --query <text> [--limit <n>]", required: ["query"]),
            ActionHelp(name: "get", summary: "Get full details for a contact by ID",
                example: "apple-tools contacts get --id <id>", required: ["id"]),
            ActionHelp(name: "update", summary: "Edit a contact: set fields, add or remove one phone/email/URL/address",
                example: "apple-tools contacts update --id <id> [--job_title <t>] [--add_phone <n> --label mobile] [--remove_email <e>] [--birthday 1990-04-15]", required: ["id"]),
        ]
    )

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "search": .read,
        "get":    .read,
        "update": .readWrite,
    ])

    public init() {}

    public func handle(params: [String: AnyCodable]?) -> (result: String, isError: Bool) {
        guard ContactsIntegration.requestAccess() else {
            return (ContactsIntegration.ContactsError.accessDenied.description, true)
        }

        guard let action = params?["action"]?.value as? String else {
            return ("missing required parameter: action", true)
        }

        switch action {
        case "search":
            guard let query = params?["query"]?.value as? String, !query.isEmpty else {
                return ("missing required parameter: query", true)
            }
            let limit = params?["limit"]?.value as? Int ?? 20
            return search(query: query, limit: limit)
        case "get":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            return get(id: id)
        case "update":
            guard let id = params?["id"]?.value as? String, !id.isEmpty else {
                return ("missing required parameter: id", true)
            }
            return update(id: id, params: params ?? [:])
        default:
            return ("unknown action: \(action) (use search, get, or update)", true)
        }
    }

    public func preflight() -> (ok: Bool, message: String) {
        return ContactsIntegration.preflight()
    }

    // MARK: - Search

    private func search(query: String, limit: Int) -> (String, Bool) {
        let searchKeys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        let groupContactIDs = ContactsIntegration.contactIDsInMatchingGroups(query: query)
        // Whole-query passes first. Only when BOTH whiff do we try the
        // multi-token AND-of-fields intersection (issue #46), so any direct hit
        // ranks ahead of an intersection hit.
        var nameMatches = ContactsIntegration.searchByName(query: query, keys: searchKeys)
        let emailPhoneMatches = ContactsIntegration.searchByEmailOrPhone(query: query, keys: searchKeys)
        if nameMatches.isEmpty && emailPhoneMatches.isEmpty {
            nameMatches = ContactsIntegration.searchByNameTokens(query: query, keys: searchKeys)
        }

        var seen = Set<String>()
        var results: [[String: Any]] = []

        for contact in nameMatches + emailPhoneMatches {
            guard !seen.contains(contact.identifier) else { continue }
            seen.insert(contact.identifier)
            results.append(contactSummary(contact))
            if results.count >= limit { break }
        }

        if results.count < limit && !groupContactIDs.isEmpty {
            let remaining = Array(groupContactIDs.subtracting(seen))
            let groupContacts = ContactsIntegration.contactsByIdentifiers(remaining, keys: searchKeys)
            for contact in groupContacts {
                guard !seen.contains(contact.identifier) else { continue }
                seen.insert(contact.identifier)
                results.append(contactSummary(contact))
                if results.count >= limit { break }
            }
        }

        let response: [String: Any] = [
            "count": results.count,
            "contacts": results,
        ]
        return (jsonEncode(response), false)
    }

    // MARK: - Get

    private func get(id: String) -> (String, Bool) {
        let contact: CNContact
        do {
            contact = try ContactsIntegration.contact(byIdentifier: id, keys: Self.allKeys)
        } catch let error as ContactsIntegration.ContactsError {
            return (error.description, true)
        } catch {
            return ("failed to fetch contact: \(error.localizedDescription)", true)
        }

        return (jsonEncode(contactFull(contact)), false)
    }

    // MARK: - Update

    private static let singleFields: [(param: String, key: ReferenceWritableKeyPath<CNMutableContact, String>)] = [
        ("given_name", \.givenName), ("middle_name", \.middleName), ("family_name", \.familyName),
        ("nickname", \.nickname), ("prefix", \.namePrefix), ("suffix", \.nameSuffix),
        ("organization", \.organizationName), ("job_title", \.jobTitle), ("department", \.departmentName),
    ]
    private static let multiKinds = ["phone", "email", "url", "address"]

    private func update(id: String, params p: [String: AnyCodable]) -> (String, Bool) {
        func str(_ key: String) -> String? { p[key]?.value as? String }

        let editable = Self.singleFields.map(\.param) + ["birthday"]
            + Self.multiKinds.flatMap { ["add_\($0)", "remove_\($0)"] }
        guard editable.contains(where: { p[$0] != nil }) else {
            return ("nothing to update: pass at least one of " + editable.joined(separator: ", "), true)
        }

        let found: CNContact
        do {
            found = try ContactsIntegration.contact(byIdentifier: id, keys: Self.allKeys)
        } catch {
            return ("\(error)", true)
        }
        guard let contact = found.mutableCopy() as? CNMutableContact else {
            return ("couldn't edit contact \(id)", true)
        }

        for field in Self.singleFields {
            if let v = str(field.param) { contact[keyPath: field.key] = v }
        }
        if let b = str("birthday") {
            if b.lowercased() == "none" {
                contact.birthday = nil
            } else if let dc = Self.parseBirthday(b) {
                contact.birthday = dc
            } else {
                return ("birthday must be YYYY-MM-DD, MM-DD, or none", true)
            }
        }

        let label = Self.label(str("label"))
        // Removes run before adds so "replace a number" is one call.
        if let v = str("remove_phone") {
            let target = PhoneFormatting.normalized(v)
            guard let i = contact.phoneNumbers.firstIndex(where: { PhoneFormatting.normalized($0.value.stringValue) == target }) else {
                return ("this contact has no phone \(v)", true)
            }
            contact.phoneNumbers.remove(at: i)
        }
        if let v = str("remove_email") {
            guard let i = contact.emailAddresses.firstIndex(where: { ($0.value as String).caseInsensitiveCompare(v) == .orderedSame }) else {
                return ("this contact has no email \(v)", true)
            }
            contact.emailAddresses.remove(at: i)
        }
        if let v = str("remove_url") {
            guard let i = contact.urlAddresses.firstIndex(where: { ($0.value as String) == v }) else {
                return ("this contact has no URL \(v)", true)
            }
            contact.urlAddresses.remove(at: i)
        }
        if let v = str("remove_address") {
            let formatter = CNPostalAddressFormatter()
            let want = Self.squash(v)
            guard let i = contact.postalAddresses.firstIndex(where: {
                Self.squash($0.value.street) == want || Self.squash(formatter.string(from: $0.value)) == want
            }) else {
                return ("this contact has no address \(v)", true)
            }
            contact.postalAddresses.remove(at: i)
        }
        if let v = str("add_phone"), !v.isEmpty {
            contact.phoneNumbers.append(CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: v)))
        }
        if let v = str("add_email"), !v.isEmpty {
            contact.emailAddresses.append(CNLabeledValue(label: label, value: v as NSString))
        }
        if let v = str("add_url"), !v.isEmpty {
            contact.urlAddresses.append(CNLabeledValue(label: label, value: v as NSString))
        }
        if let v = str("add_address"), !v.isEmpty {
            let parts = v.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let address = CNMutablePostalAddress()
            address.street = parts[0]
            if parts.count > 1 { address.city = parts[1] }
            if parts.count > 2 { address.state = parts[2] }
            if parts.count > 3 { address.postalCode = parts[3] }
            if parts.count > 4 { address.country = parts[4] }
            contact.postalAddresses.append(CNLabeledValue(label: label, value: address))
        }

        do {
            try ContactsIntegration.update(contact)
            let saved = try ContactsIntegration.contact(byIdentifier: id, keys: Self.allKeys)
            return (jsonEncode(contactFull(saved)), false)
        } catch {
            return ("\(error)", true)
        }
    }

    static func parseBirthday(_ s: String) -> DateComponents? {
        let parts = s.split(separator: "-").map { Int($0) }
        guard !parts.contains(nil) else { return nil }
        let n = parts.compactMap { $0 }
        var dc = DateComponents()
        switch n.count {
        case 3: (dc.year, dc.month, dc.day) = (n[0], n[1], n[2])
        case 2: (dc.month, dc.day) = (n[0], n[1])
        default: return nil
        }
        guard (1...12).contains(dc.month!), (1...31).contains(dc.day!) else { return nil }
        return dc
    }

    static func label(_ s: String?) -> String {
        switch s?.lowercased() {
        case nil, "", "other": return CNLabelOther
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "school": return CNLabelSchool
        case "mobile": return CNLabelPhoneNumberMobile
        case "iphone": return CNLabelPhoneNumberiPhone
        case "main": return CNLabelPhoneNumberMain
        default: return s!
        }
    }

    private static func squash(_ s: String) -> String {
        s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let allKeys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNamePrefixKey as CNKeyDescriptor,
            CNContactNameSuffixKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactDatesKey as CNKeyDescriptor,
            CNContactRelationsKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor,
    ]

    // MARK: - LLM payload formatting

    private func contactSummary(_ contact: CNContact) -> [String: Any] {
        var entry: [String: Any] = [
            "id": contact.identifier,
        ]

        let name = buildName(contact)
        if !name.isEmpty {
            entry["name"] = name
        }

        if !contact.organizationName.isEmpty {
            entry["organization"] = contact.organizationName
        }

        if let email = contact.emailAddresses.first {
            entry["email"] = email.value as String
        }

        if let phone = contact.phoneNumbers.first {
            entry["phone"] = PhoneFormatting.normalized(phone.value.stringValue)
        }

        return entry
    }

    private func contactFull(_ contact: CNContact) -> [String: Any] {
        var entry: [String: Any] = [
            "id": contact.identifier,
        ]

        let name = buildName(contact)
        if !name.isEmpty { entry["name"] = name }
        if !contact.nickname.isEmpty { entry["nickname"] = contact.nickname }
        if !contact.namePrefix.isEmpty { entry["prefix"] = contact.namePrefix }
        if !contact.nameSuffix.isEmpty { entry["suffix"] = contact.nameSuffix }

        if !contact.organizationName.isEmpty { entry["organization"] = contact.organizationName }
        if !contact.departmentName.isEmpty { entry["department"] = contact.departmentName }
        if !contact.jobTitle.isEmpty { entry["job_title"] = contact.jobTitle }

        if !contact.emailAddresses.isEmpty {
            entry["emails"] = contact.emailAddresses.map { labeled($0) }
        }

        if !contact.phoneNumbers.isEmpty {
            entry["phones"] = contact.phoneNumbers.map { lv -> [String: String] in
                var d: [String: String] = ["value": PhoneFormatting.normalized(lv.value.stringValue)]
                if let label = lv.label {
                    d["label"] = CNLabeledValue<NSString>.localizedString(forLabel: label)
                }
                return d
            }
        }

        if !contact.postalAddresses.isEmpty {
            let formatter = CNPostalAddressFormatter()
            entry["addresses"] = contact.postalAddresses.map { lv -> [String: String] in
                var d: [String: String] = ["value": formatter.string(from: lv.value)]
                if let label = lv.label {
                    d["label"] = CNLabeledValue<NSString>.localizedString(forLabel: label)
                }
                return d
            }
        }

        if !contact.urlAddresses.isEmpty {
            entry["urls"] = contact.urlAddresses.map { labeled($0) }
        }

        if let birthday = contact.birthday {
            var parts: [String] = []
            if let year = birthday.year { parts.append(String(format: "%04d", year)) }
            if let month = birthday.month { parts.append(String(format: "%02d", month)) }
            if let day = birthday.day { parts.append(String(format: "%02d", day)) }
            entry["birthday"] = parts.joined(separator: "-")
        }

        if !contact.dates.isEmpty {
            entry["dates"] = contact.dates.map { lv -> [String: String] in
                let dc = lv.value as DateComponents
                var parts: [String] = []
                if let year = dc.year { parts.append(String(format: "%04d", year)) }
                if let month = dc.month { parts.append(String(format: "%02d", month)) }
                if let day = dc.day { parts.append(String(format: "%02d", day)) }
                var d: [String: String] = ["value": parts.joined(separator: "-")]
                if let label = lv.label {
                    d["label"] = CNLabeledValue<NSString>.localizedString(forLabel: label)
                }
                return d
            }
        }

        if !contact.contactRelations.isEmpty {
            entry["relations"] = contact.contactRelations.map { lv -> [String: String] in
                var d: [String: String] = ["name": lv.value.name]
                if let label = lv.label {
                    d["label"] = CNLabeledValue<NSString>.localizedString(forLabel: label)
                }
                return d
            }
        }

        if !contact.socialProfiles.isEmpty {
            entry["social_profiles"] = contact.socialProfiles.map { lv -> [String: String] in
                var d: [String: String] = [
                    "service": lv.value.service,
                    "username": lv.value.username,
                ]
                if !lv.value.urlString.isEmpty {
                    d["url"] = lv.value.urlString
                }
                return d
            }
        }

        if !contact.instantMessageAddresses.isEmpty {
            entry["instant_message"] = contact.instantMessageAddresses.map { lv -> [String: String] in
                return [
                    "service": lv.value.service,
                    "username": lv.value.username,
                ]
            }
        }

        entry["type"] = contact.contactType == .person ? "person" : "organization"

        return entry
    }

    private func buildName(_ contact: CNContact) -> String {
        var parts: [String] = []
        if !contact.givenName.isEmpty { parts.append(contact.givenName) }
        if !contact.middleName.isEmpty { parts.append(contact.middleName) }
        if !contact.familyName.isEmpty { parts.append(contact.familyName) }
        return parts.joined(separator: " ")
    }

    private func labeled(_ lv: CNLabeledValue<NSString>) -> [String: String] {
        var d: [String: String] = ["value": lv.value as String]
        if let label = lv.label {
            d["label"] = CNLabeledValue<NSString>.localizedString(forLabel: label)
        }
        return d
    }

    private func jsonEncode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
