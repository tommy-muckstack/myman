import Foundation
import GRDB

/// Serial, coalesced enrichment. Capture/search never wait for a language model.
actor ConceptThemeWorker {
    static let shared = ConceptThemeWorker()
    @MainActor static var foregroundBusy: () -> Bool = { !MeetingNotesService.shared.stages.isEmpty }
    private var running = false
    private var requested = false
    private var lastSnapshot = ""
    private var cached: [String: ConceptThemes.Proposal] = [:]
    private var rejected = Set<String>()
    private var vectors: [String: Data] = [:]
    private var enabled: Bool { UserDefaults.standard.object(forKey: "automaticCaptureThemes") as? Bool ?? true }

    func schedule() async {
        requested = true
        guard !running else { return }
        running = true
        defer { running = false }
        while requested {
            requested = false
            guard enabled else { cached.removeAll(); rejected.removeAll(); vectors.removeAll(); lastSnapshot = ""; return }
            // Give foreground audio and note generation priority. Only one
            // conceptual label is generated at a time, between busy checks.
            await waitForIdle()
            guard enabled, !Task.isCancelled else { return }
            do { try await rebuild() }
            catch { NSLog("Man: theme enrichment will retry after the next capture") }
        }
    }

    private func waitForIdle() async {
        while enabled && !Task.isCancelled {
            let busy = await MainActor.run { Self.foregroundBusy() }
            if !busy { return }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    static func snapshotKey(_ items: [CaptureItem], names: [String], available: Bool) -> String {
        var parts = [available ? "local-model" : "explicit-titles"] + names.sorted()
        for item in items.sorted(by: { $0.id < $1.id }) {
            parts.append(contentsOf: [item.id, item.rawTitle, item.userTitle, item.body, item.summary, String(item.revision)])
        }
        return ConceptThemes.digest(parts)
    }

    private func rebuild() async throws {
        let (items, names, persisted) = try await Database.shared.read { db in
            let items = try CaptureItem.filter(Column("excluded") == false).fetchAll(db)
            let names = try String.fetchAll(db, sql: "SELECT name FROM person UNION SELECT ownerName FROM meeting WHERE ownerName != ''") + [NSFullUserName()]
            var persisted: [String: ConceptThemes.Proposal] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM captureTheme WHERE conceptDigest != '' AND dismissed = 0") {
                let members = Set(try String.fetchAll(db, sql: "SELECT itemID FROM captureThemeMember WHERE themeID = ?", arguments: [row["id"] as String]))
                let digest: String = row["conceptDigest"]
                persisted[digest] = ConceptThemes.Proposal(title: row["title"], description: row["description"], members: members, digest: digest)
            }
            return (items, names, persisted)
        }
        let available = ConceptThemes.modelAvailable
        let key = Self.snapshotKey(items, names: names, available: available)
        guard key != lastSnapshot else { return }
        var proposals: [ConceptThemes.Proposal] = []
        var complete = true
        if available {
            var usedVectors = Set<String>()
            let evidence = ConceptThemes.evidence(items, names: names) { text in
                let hash = ConceptThemes.digest([text]); usedVectors.insert(hash)
                if let vector = vectors[hash] { return vector }
                let vector = SearchService.embedding(for: text)
                vectors[hash] = vector
                return vector
            }
            vectors = vectors.filter { usedVectors.contains($0.key) }
            let groups = ConceptThemes.groups(evidence)
            let fingerprints = Set(groups.map(ConceptThemes.fingerprint))
            cached = cached.filter { fingerprints.contains($0.key) }
            rejected.formIntersection(fingerprints)
            for group in groups {
                await waitForIdle()
                guard enabled, !Task.isCancelled else { return }
                let fingerprint = ConceptThemes.fingerprint(group)
                if rejected.contains(fingerprint) { continue }
                if let existing = cached[fingerprint] ?? persisted[fingerprint] {
                    proposals.append(existing); continue
                }
                guard let label = await ConceptThemes.label(group) else { complete = false; continue }
                if let proposal = ConceptThemes.proposal(label, group: group, names: names) {
                    cached[fingerprint] = proposal; proposals.append(proposal)
                } else { rejected.insert(fingerprint) }
            }
        } else { proposals = ConceptThemes.fallback(items, names: names) }
        guard enabled, !Task.isCancelled else { return }
        let finalProposals = proposals, finalComplete = complete
        let didApply = try await Database.shared.write { db -> Bool in
            let current = try CaptureItem.filter(Column("excluded") == false).fetchAll(db)
            guard Self.snapshotKey(current, names: names, available: available) == key,
                  UserDefaults.standard.object(forKey: "automaticCaptureThemes") as? Bool ?? true else { return false }
            try ThemeStore.infer(in: db, items: current, enabled: true, prepared: finalProposals,
                                 retireUnmatched: finalComplete, preserveConcepts: !available)
            return true
        }
        if didApply {
            if complete { lastSnapshot = key }
            ThemeStore.notify()
        } else { requested = true }
    }
}
