import AppKit
import EventKit
import SwiftUI

// Calendar-aware meeting nudges, the Granola pattern: EventKit sees every
// account macOS Calendar knows (Google, Outlook, iCloud) with no OAuth of our
// own. `.EKEventStoreChanged` is the primary wake signal — notification
// delivery survives App Nap where timers can't (a 5-min timer is only a
// backstop). Reads use a FRESH EKEventStore each time; cached stores go stale.

@MainActor
final class CalendarWatcher {
    /// Fired ~45s before an event with a meeting link: start provisional
    /// capture and show the Use My Man card (with Join). The Quill move.
    var onPreMeeting: (_ title: String?, _ joinURL: URL?, _ startsAt: Date) -> Void = { _, _, _ in }

    private var nudgeTimers: [String: Timer] = [:]
    private var nudgedEventIDs: Set<String> = []
    private var refreshTimer: Timer?

    private var began = false

    func start() {
        // The onboarding checklist owns the one-shot permission prompt.
        // Activate now if access exists; otherwise wake up when the
        // checklist reports a grant — never burn the prompt at launch.
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            begin()
        } else {
            NotificationCenter.default.addObserver(
                forName: .mmPermissionsChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.began,
                          EKEventStore.authorizationStatus(for: .event) == .fullAccess
                    else { return }
                    self.begin()
                }
            }
            // Backstop for grants made directly in System Settings with no
            // checklist open — cheap status read, no prompt.
            let waiter = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self else { timer.invalidate(); return }
                    if !self.began, EKEventStore.authorizationStatus(for: .event) == .fullAccess {
                        self.begin()
                    }
                    if self.began { timer.invalidate() }
                }
            }
            waiter.tolerance = 10
        }
    }

    private func begin() {
        guard !began else { return }
        began = true
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer?.tolerance = 30
        refresh()
    }

    private func refresh() {
        // Fresh store per read — cached EKEventStores serve stale events.
        let store = EKEventStore()
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(12 * 3600), calendars: nil)
        let events = store.events(matching: predicate)

        for event in events {
            guard let id = event.eventIdentifier,
                  !nudgedEventIDs.contains(id),
                  nudgeTimers[id] == nil,
                  Self.meetingLink(in: event) != nil,
                  event.startDate > now.addingTimeInterval(-120)
            else { continue }

            let nudgeAt = event.startDate.addingTimeInterval(-45)
            let delay = nudgeAt.timeIntervalSince(now)
            if delay <= 0 {
                nudge(for: event)
            } else {
                let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.nudgeTimers[id] = nil
                        self?.nudge(for: event)
                    }
                }
                timer.tolerance = 15
                nudgeTimers[id] = timer
            }
        }
    }

    /// Zoom/Meet/Teams/Webex/FaceTime link anywhere in the event.
    static func meetingLink(in event: EKEvent) -> String? {
        meetingURL(in: event) != nil ? "link" : nil
    }

    /// The actual joinable URL, extracted from url/location/notes.
    static func meetingURL(in event: EKEvent) -> URL? {
        let haystack = [
            event.url?.absoluteString,
            event.location,
            event.notes,
        ].compactMap { $0 }.joined(separator: " ")
        let domains = ["zoom.us", "meet.google.com", "teams.microsoft.com",
                       "webex.com", "facetime.apple.com", "meet.jit.si"]
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"]+") else { return nil }
        let ns = haystack as NSString
        for match in regex.matches(in: haystack, range: NSRange(location: 0, length: ns.length)) {
            let candidate = ns.substring(with: match.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: ").,;"))
            if domains.contains(where: { candidate.localizedCaseInsensitiveContains($0) }),
               let url = URL(string: candidate) {
                return url
            }
        }
        return nil
    }

    private func nudge(for event: EKEvent) {
        guard let id = event.eventIdentifier, !nudgedEventIDs.contains(id) else { return }
        nudgedEventIDs.insert(id)
        Analytics.track("meeting_nudge_shown")
        onPreMeeting(event.title, Self.meetingURL(in: event), event.startDate)
    }
}
// (Legacy nudge pill removed — the provisional Use My Man card is the surface.)
