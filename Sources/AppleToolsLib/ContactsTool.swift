import Contacts
import Foundation

public struct ContactsTool: ProbeTool {
    public let definition = ToolDefinition(
        name: "contacts",
        description: "Access Apple Contacts. Actions: 'search' (find contacts by name, email, phone, or group name; returns summaries only — street addresses, birthdays, and any additional emails/phones are NOT included), 'get' (full details for a contact by ID; the only way to see addresses and other non-summary fields).",
        parameters: ParameterSchema(
            type_: "object",
            properties: [
                "action": PropertySchema(type_: "string", description: "search or get"),
                "query": PropertySchema(type_: "string", description: "Search term — matches name, email, phone, or group name (required for search)",
                    summary: "Search term matched across name, email, phone, group", actions: ["search"]),
                "limit": PropertySchema(type_: "integer", description: "Max results to return (for search, default 20)",
                    summary: "Max results (default 20)", actions: ["search"]),
                "id": PropertySchema(type_: "string", description: "Contact identifier from search results (required for get)",
                    summary: "Contact ID from search results", actions: ["get"]),
            ],
            required: ["action"]
        ),
        cliSummary: "Search Apple Contacts and read full contact details.",
        actions: [
            ActionHelp(name: "search", summary: "Find contacts by name, email, phone, or group",
                example: "apple-tools contacts search --query <text> [--limit <n>]", required: ["query"]),
            ActionHelp(name: "get", summary: "Get full details for a contact by ID",
                example: "apple-tools contacts get --id <id>", required: ["id"]),
        ]
    )

    public let accessPolicy: ToolAccessPolicy = .perAction([
        "search": .read,
        "get":    .read,
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
        default:
            return ("unknown action: \(action) (use search or get)", true)
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
        let nameMatches = ContactsIntegration.searchByName(query: query, keys: searchKeys)
        let emailPhoneMatches = ContactsIntegration.searchByEmailOrPhone(query: query, keys: searchKeys)

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
        let allKeys: [CNKeyDescriptor] = [
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

        let contact: CNContact
        do {
            contact = try ContactsIntegration.contact(byIdentifier: id, keys: allKeys)
        } catch let error as ContactsIntegration.ContactsError {
            return (error.description, true)
        } catch {
            return ("failed to fetch contact: \(error.localizedDescription)", true)
        }

        return (jsonEncode(contactFull(contact)), false)
    }

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
