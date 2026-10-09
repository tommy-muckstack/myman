import Foundation
import GRDB

/// Related past context that follows a live meeting: seeded from the title
/// and the people on the call, then refreshed as the transcript moves on to
/// new topics. Owned by `LiveMeetingTranscript` so it keeps working while
/// the person looks at another tab. Quiet by design: a refresh needs both
/// enough new words and enough elapsed time, and a card is shown once.
@MainActor final class MeetingContextStream: ObservableObject {
    struct Session: Equatable, Sendable {
        var meetingID: String?
        var startedAt: Date
        var title: String
        var attendees: [MeetingContextPerson]
        var ownerName: String
    }

    static let minimumNewWords = 40
    static let minimumInterval: TimeInterval = 30
    static let maxCards = 12
    static let visibleCount = 3
    static let windowWords = 350

    @Published private(set) var cards: [MeetingContextCard] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var hiddenForMeeting = false
    @Published var enabled = true

    private let provider: any MeetingContextProvider
    private let now: () -> Date
    private var database: DatabaseQueue?
    private var session: Session?
    private var latestText = ""
    private var wordsAtRefresh = 0
    private var lastRefresh: Date?
    private var shown = Set<String>()
    private var dismissed = Set<String>()
    private var refreshTask: Task<Void, Never>?
    private var delayedTask: Task<Void, Never>?
    private var generation = UUID()

    init(provider: any MeetingContextProvider = LocalMeetingContextProvider(), now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    var isActive: Bool { session != nil && enabled && !hiddenForMeeting }

    func start(session: Session, database: DatabaseQueue) {
        stop()
        self.session = session
        self.database = database
        guard enabled else { return }
        var terms = MeetingVocabulary.properNouns(in: session.title)
        for word in CaptureText.words(session.title) where word.count >= 4 && !terms.contains(where: { $0.lowercased() == word }) {
            terms.append(word)
        }
        refresh(seed: true, terms: Array(terms.prefix(6)))
    }

    /// Rows are rebuilt on every transcript change, so the delta is against
    /// the count at the last refresh, never negative.
    func update(rows: [LiveMeetingTranscript.Row]) {
        guard isActive else { return }
        latestText = rows.map(\.text).joined(separator: " ")
        let words = CaptureText.words(latestText).count
        let delta = max(0, words - wordsAtRefresh)
        guard delta >= Self.minimumNewWords else { return }
        let elapsed = lastRefresh.map { now().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.minimumInterval {
            refresh(seed: false, terms: nil)
        } else if delayedTask == nil {
            // Enough was said; wait out the interval so a burst followed by
            // silence still gets its refresh.
            let wait = Self.minimumInterval - elapsed
            let generation = generation
            delayedTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.delayedTask = nil
                guard self.isActive else { return }
                self.refresh(seed: false, terms: nil)
            }
        }
    }

    /// Names read off the call window arrive after the seed; a new person
    /// means new history worth a look.
    func updateAttendees(_ attendees: [MeetingContextPerson]) {
        guard var session, session.attendees != attendees else { return }
        let fresh = attendees.filter { person in !session.attendees.contains { LiveMeetingTranscript.sameName($0.name, person.name) } }
        session.attendees = attendees
        self.session = session
        guard !fresh.isEmpty, isActive else { return }
        refresh(seed: false, terms: [])
    }

    func dismiss(_ card: MeetingContextCard) {
        dismissed.insert(card.id)
        cards.removeAll { $0.id == card.id }
        Analytics.track("context_card_dismissed", ["kind": card.item.kind, "basis": card.basis.rawValue])
    }

    func hideForMeeting() {
        hiddenForMeeting = true
        cancelWork()
        Analytics.track("context_stream_hidden", ["shown": shown.count])
    }

    func open(_ card: MeetingContextCard) {
        Analytics.track("context_card_opened", ["kind": card.item.kind, "basis": card.basis.rawValue])
        CaptureActions.open(card.item)
    }

    func stop() {
        cancelWork()
        session = nil
        database = nil
        latestText = ""
        wordsAtRefresh = 0
        lastRefresh = nil
        shown = []
        dismissed = []
        cards = []
        hiddenForMeeting = false
        isRefreshing = false
    }

    private func cancelWork() {
        refreshTask?.cancel()
        refreshTask = nil
        delayedTask?.cancel()
        delayedTask = nil
        generation = UUID()
        isRefreshing = false
    }

    /// - Parameter terms: nil derives terms from the latest transcript window;
    ///   an empty list runs the people query only.
    private func refresh(seed: Bool, terms: [String]?) {
        guard let session, let database, isActive else { return }
        refreshTask?.cancel()
        delayedTask?.cancel()
        delayedTask = nil
        let exclude = Set((session.attendees.map(\.name) + [session.ownerName]).filter { !$0.isEmpty })
        let resolvedTerms: [String]
        if let terms {
            resolvedTerms = terms
        } else {
            let words = latestText.split(whereSeparator: \.isWhitespace)
            let window = words.suffix(Self.windowWords).joined(separator: " ")
            resolvedTerms = provider.terms(in: window, exclude: exclude, limit: 8)
        }
        wordsAtRefresh = CaptureText.words(latestText).count
        lastRefresh = now()
        let request = MeetingContextRequest(meetingID: session.meetingID, startedAt: session.startedAt, title: session.title,
                                            attendees: session.attendees, terms: resolvedTerms, seed: seed,
                                            excludedIDs: shown.union(dismissed), now: now())
        let generation = UUID()
        self.generation = generation
        let provider = self.provider
        isRefreshing = true
        refreshTask = Task { [weak self] in
            let ranked = await Task.detached(priority: .utility) { () -> [MeetingContextCard] in
                (try? provider.rank(request, database: database)) ?? []
            }.value
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.isRefreshing = false
            let fresh = ranked.filter { !self.shown.contains($0.id) && !self.dismissed.contains($0.id) }
            guard !fresh.isEmpty else { return }
            self.shown.formUnion(fresh.map(\.id))
            self.cards = Array((fresh + self.cards).prefix(Self.maxCards))
            Analytics.track("context_card_shown", ["count": fresh.count, "seed": seed,
                                                   "kinds": Set(fresh.map(\.item.kind)).sorted().joined(separator: ",")])
        }
    }
}
