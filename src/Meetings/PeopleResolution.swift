import Foundation

/// Pure lookup over already saved identities. No contact/calendar access,
/// guessed addresses, enrollment, ranking by private meeting history or writes.
enum PeopleResolution {
    struct Record: Codable, Sendable {
        var name: String
        var email: String?
        var source: String
    }
    struct Candidate: Codable, Equatable, Sendable {
        var name: String
        var email: String?
        var sources: [String]
        var match: String
    }
    struct Match: Codable, Equatable, Sendable {
        var input: String
        var status: String
        var candidates: [Candidate]
        var total: Int
        var truncated: Bool
    }
    private struct Identity {
        var names: Set<String>
        var email: String?
        var sources: Set<String>
    }
    static let maximumRecords = 10_000
    static func normalized(_ value: String) -> String {
        value.decomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: #"\p{M}"#, with: "", options: .regularExpression)
            .lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func email(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), value.utf8.count <= 254,
              value.range(of: #"^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]{2,63}$"#, options: .regularExpression) != nil else { return nil }
        let local = value.split(separator: "@")[0]
        guard !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."), local.utf8.count <= 64 else { return nil }
        return value
    }
    static func generic(_ name: String) -> Bool {
        let key = normalized(name)
        return key.isEmpty || ["you", "them", "others", "unknown", "speaker", "owner"].contains(key)
            || key.range(of: #"^speaker \d+$"#, options: .regularExpression) != nil
    }
    static func validate(names: [String], limit: Int) throws {
        guard (1...20).contains(names.count), (1...10).contains(limit), names.allSatisfy({
            !$0.isEmpty && $0.utf16.count <= 200 && $0.rangeOfCharacter(from: .controlCharacters) == nil && !normalized($0).isEmpty
        }) else { throw AgentError("INVALID_ARGUMENTS", "Use 1–20 nonblank names up to 200 characters and a limit from 1 to 10.") }
    }
    static func resolve(names: [String], records: [Record], limit: Int = 5) throws -> [Match] {
        try validate(names: names, limit: limit)
        guard records.count <= maximumRecords else { throw AgentError("PEOPLE_LIMIT_EXCEEDED", "Too many saved people; no partial resolution was returned.") }
        var identities: [String: Identity] = [:]
        for record in records {
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.utf16.count <= 300, name.rangeOfCharacter(from: .controlCharacters) == nil, !generic(name) else { continue }
            let address = email(record.email), key = address.map { "email:" + $0 } ?? "name:" + normalized(name)
            var identity = identities[key] ?? Identity(names: [], email: address, sources: [])
            identity.names.insert(name); identity.sources.insert(record.source); identities[key] = identity
        }
        let kinds = ["exact_email", "exact_name", "name_tokens", "name_prefix"]
        return names.map { input in
            let query = normalized(input), address = email(input), isAddress = input.contains("@")
            var matches: [(Int, Candidate)] = []
            for identity in identities.values {
                var rank: Int?
                if isAddress {
                    if let address, identity.email == address { rank = 0 }
                } else {
                    for alias in identity.names {
                        let name = normalized(alias)
                        let value: Int?
                        if name == query { value = 1 }
                        else if (" " + name + " ").contains(" " + query + " ") { value = 2 }
                        else if query.count >= 2 && (" " + name).contains(" " + query) { value = 3 }
                        else { value = nil }
                        if let value { rank = min(rank ?? value, value) }
                    }
                }
                guard let rank else { continue }
                let name = identity.names.sorted {
                    if $0.utf16.count != $1.utf16.count { return $0.utf16.count > $1.utf16.count }
                    return normalized($0) == normalized($1) ? $0 < $1 : normalized($0) < normalized($1)
                }.first!
                matches.append((rank, Candidate(name: name, email: identity.email, sources: identity.sources.sorted(), match: kinds[rank])))
            }
            matches.sort {
                if $0.0 != $1.0 { return $0.0 < $1.0 }
                let left = normalized($0.1.name), right = normalized($1.1.name)
                if left != right { return left < right }
                return ($0.1.email ?? "") < ($1.1.email ?? "")
            }
            let status: String
            if matches.isEmpty { status = "not_found" }
            else if matches.count > 1 { status = "ambiguous" }
            else if matches[0].1.email == nil { status = "missing_email" }
            else if matches[0].0 == 3 { status = "needs_confirmation" }
            else { status = "resolved" }
            return Match(input: input, status: status, candidates: Array(matches.prefix(limit).map(\.1)), total: matches.count, truncated: matches.count > limit)
        }
    }
}
