import Foundation

/// In-memory derived evidence. Commit a prepared state only after its database
/// snapshot is validated, so concurrent edits can never poison the cache.
struct CaptureRelationships {
    struct Version: Equatable {
        let revision: Int
        let title: String
        let kind: String
        let capturedAt: Date
        init(_ item: CaptureItem) {
            revision = item.revision; title = item.title
            kind = item.kind; capturedAt = item.capturedAt
        }
    }
    struct Edge: Equatable {
        let source: String
        let target: String
        let score: Double
        let kind: String
        let reason: String
    }
    private struct Evidence {
        let version: Version
        let terms: Set<String>
        let domains: Set<String>
    }
    struct Update {
        let next: CaptureRelationships
        let reset: Bool
        let sources: Set<String>
        let edges: [Edge]
        let scoredPairs: Int
        let analyzedItems: Int
    }
    private var evidence: [String: Evidence] = [:]
    private var candidates: [String: [String: Version]] = [:]
    private var initialized = false

    static func versions(_ items: [CaptureItem]) -> [String: Version] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, Version($0)) })
    }

    func prepare(_ items: [CaptureItem]) -> Update? {
        let versions = Self.versions(items)
        if initialized, evidence.mapValues(\.version) == versions { return nil }
        var next = CaptureRelationships()
        next.initialized = true
        var analyzed = 0
        var inverted: [String: Set<String>] = [:]
        var domainPeers: [String: Set<String>] = [:]
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in items {
            let value: Evidence
            if let cached = evidence[item.id], cached.version == versions[item.id] {
                value = cached
            } else {
                value = Evidence(version: Version(item), terms: CaptureSignals.terms(item), domains: CaptureSignals.domains(item.text))
                analyzed += 1
            }
            next.evidence[item.id] = value
            for term in value.terms { inverted[term, default: []].insert(item.id) }
            for domain in value.domains { domainPeers[domain, default: []].insert(item.id) }
        }
        var sources = Set(evidence.keys).subtracting(versions.keys)
        var edges: [Edge] = []
        var scored = 0
        for item in items {
            guard let value = next.evidence[item.id] else { continue }
            var counts: [String: Int] = [:]
            for domain in value.domains {
                for peer in domainPeers[domain] ?? [] where peer != item.id { counts[peer, default: 0] += 2 }
            }
            for term in value.terms {
                guard let peers = inverted[term], peers.count <= max(20, items.count / 3) else { continue }
                for peer in peers where peer != item.id { counts[peer, default: 0] += 1 }
            }
            let peers = counts.filter { $0.value >= 2 }.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.prefix(30).map(\.key)
            let signature = Dictionary(uniqueKeysWithValues: peers.compactMap { id in versions[id].map { (id, $0) } })
            next.candidates[item.id] = signature
            if initialized, evidence[item.id]?.version == value.version, candidates[item.id] == signature { continue }
            sources.insert(item.id)
            for peer in peers {
                guard let target = byID[peer], let other = next.evidence[peer] else { continue }
                scored += 1
                if let (score, kind, reason) = RelatedItems.score(item, target,
                    sharedTerms: value.terms.intersection(other.terms), sharedDomains: value.domains.intersection(other.domains)) {
                    edges.append(Edge(source: item.id, target: peer, score: score, kind: kind, reason: reason))
                }
            }
        }
        return Update(next: next, reset: !initialized, sources: sources, edges: edges,
                      scoredPairs: scored, analyzedItems: analyzed)
    }
}
