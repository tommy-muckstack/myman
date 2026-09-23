import AppKit
import Foundation

enum DictationCorrection {
    static let preference = "learnDictationCorrections"

    /// One small word replacement, not appended prose, punctuation, or a rewrite.
    static func term(original: String, corrected: String) -> String? {
        guard original.count <= 50_000, corrected.count <= 50_000 else { return nil }
        func words(_ text: String) -> [String] {
            text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).map(String.init)
        }
        let before = words(original), after = words(corrected)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        let old = Array(before[prefix..<(before.count - suffix)])
        let new = Array(after[prefix..<(after.count - suffix)])
        guard (1...3).contains(old.count), (1...3).contains(new.count) else { return nil }
        let term = new.joined(separator: " ")
        let a = old.joined().lowercased(), b = new.joined().lowercased()
        let common: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "and", "the", "that", "this", "with", "for", "you", "your", "not", "yes", "now", "then"]
        guard (3...60).contains(term.count), a.first == b.first, !common.contains(b) else { return nil }
        if a == b {
            // Lowercasing a sentence is a style edit, not a new spelling.
            if old.count == new.count, term == term.lowercased() { return nil }
            return term
        }
        let x = Array(a), y = Array(b)
        guard abs(x.count - y.count) <= 3, max(x.count, y.count) <= 60 else { return nil }
        var row = Array(0...y.count)
        for (i, char) in x.enumerated() {
            var next = [i + 1]
            for (j, other) in y.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (char == other ? 0 : 1))) }
            row = next
        }
        return row[y.count] <= min(3, max(1, max(x.count, y.count) / 3)) ? term : nil
    }

    static func add(_ term: String, at file: URL = Brain.root.appendingPathComponent("vocabulary.md")) throws -> Bool {
        let existing = DictationCleanup.userVocabulary(at: file)
        guard existing.count < 150, !existing.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("# Vocabulary\n" + (existing + [term]).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    static func remove(_ term: String, at file: URL = Brain.root.appendingPathComponent("vocabulary.md")) throws {
        let existing = DictationCleanup.userVocabulary(at: file).filter { $0 != term }
        try ("# Vocabulary\n" + existing.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

@MainActor final class DictationCorrectionLearner {
    private let enabled: () -> Bool
    private let save: (String) throws -> Bool
    private let notify: (String) -> Void
    private let now: () -> Date
    private var original = ""
    private var latest = ""
    private var started = Date.distantPast
    private var pending: Task<Void, Never>?

    init(enabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: DictationCorrection.preference) },
         save: @escaping (String) throws -> Bool = { try DictationCorrection.add($0) },
         notify: ((String) -> Void)? = nil, now: @escaping () -> Date = Date.init) {
        self.enabled = enabled; self.save = save; self.now = now
        self.notify = notify ?? { term in
             Toast.show("Added “\(term)” to dictionary", systemImage: "text.book.closed",
                        actionLabel: "Undo", action: { try? DictationCorrection.remove(term) }, duration: 5, position: .bottomRight)
        }
    }

    func begin(_ text: String) {
        cancel()
        guard enabled() else { return }
        original = text; latest = text; started = now()
    }

    func edited(_ text: String) {
        guard text != latest else { return }
        pending?.cancel(); pending = nil
        latest = text
        guard enabled(), !original.isEmpty, now().timeIntervalSince(started) <= 45,
              let term = DictationCorrection.term(original: original, corrected: text) else { return }
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            guard let self, !Task.isCancelled, self.enabled(), self.latest == text,
                  self.now().timeIntervalSince(self.started) <= 45 else { return }
            do {
                if try self.save(term) { self.notify(term) }
            } catch { /* A failed write must never claim the word was learned. */ }
            self.original = ""
        }
    }

    func cancel() { pending?.cancel(); pending = nil; original = ""; latest = "" }
}

/// Watches only the verified dictation's original field for at most 45 seconds.
/// No keystroke contents or surrounding text are stored.
@MainActor final class DictationCorrectionWatch {
    static let shared = DictationCorrectionWatch()
    private var task: Task<Void, Never>?
    private var monitor: Any?
    private var lastKey = Date.distantPast
    private var generation = UUID()
    private let learner = DictationCorrectionLearner()

    func start(text: String, read: @escaping () -> String?) {
        stop()
        guard UserDefaults.standard.bool(forKey: DictationCorrection.preference) else { return }
        learner.begin(text)
        lastKey = .distantPast
        let current = generation
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor in if self?.generation == current { self?.lastKey = Date() } }
        }
        task = Task { @MainActor [weak self] in
            let end = Date().addingTimeInterval(45)
            while !Task.isCancelled, Date() < end {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self, self.generation == current,
                      UserDefaults.standard.bool(forKey: DictationCorrection.preference), let value = read() else { break }
                if Date().timeIntervalSince(self.lastKey) < 3 { self.learner.edited(value) }
            }
            if self?.generation == current { self?.stop() }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        learner.cancel()
    }
}
