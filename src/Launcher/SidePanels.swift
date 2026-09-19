import AppKit
import EventKit
import GRDB
import SwiftUI

// The ⌥Space heads-up display companions: tasks pinned left, calendar pinned
// right. Both are non-key panels — interacting with them never steals focus
// from the launcher's search field.

// MARK: - Tasks (left)

struct TasksPanelView: View {
    @ObservedObject var store = TasksStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tasks")
                    .font(MM.Fonts.title)
                    .foregroundStyle(MM.Colors.textPrimary)
                Spacer()
                IconView(icon: .addBox, size: 16, color: MM.Colors.textTertiary)
                    .clickable(minSize: 24)
                    .onTapGesture {
                        // This panel never takes keyboard focus (by design) —
                        // typing happens in a real window.
                        TaskComposerController.shared.show()
                    }
                    .help("Add a task")
            }
            .padding(.horizontal, MM.Layout.padding)
            .padding(.top, MM.Layout.padding)
            .padding(.bottom, 8)

            if store.openTasks.isEmpty {
                UtilityEmptyState(icon: .addBox, title: "Nothing on your plate", message: "A little room to breathe.", actionTitle: "Add a task") {
                    TaskComposerController.shared.show()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.openTasks) { task in
                            TaskRow(task: task)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(width: 260, height: 420, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                .fill(MM.Colors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                        .strokeBorder(MM.Colors.border, lineWidth: 1)
                )
        )
        .onAppear { store.refresh() }
    }
}

private struct TaskRow: View {
    let task: TaskItem
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Button { TasksStore.shared.toggle(task) } label: {
                Image(systemName: "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(MM.Colors.textTertiary)
                    .clickable()
            }
            .buttonStyle(.plain)
            .help("Mark done")
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(MM.Fonts.body)
                    .foregroundStyle(MM.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(MM.Fonts.metadata)
                        .foregroundStyle(MM.Colors.textSecondary)
                        .lineLimit(2)
                }
                // Where a task came from matters for extracted ones; a task
                // you typed yourself needs no provenance label.
                if task.source != "manual" || task.dueDate != nil {
                    HStack(spacing: 6) {
                        if task.source != "manual" {
                            Text(task.source)
                                .font(MM.Fonts.metadata)
                                .foregroundStyle(MM.Colors.textTertiary)
                        }
                        if let due = task.dueDate {
                            let overdue = due < Calendar.current.startOfDay(for: Date())
                            Text("due \(due.formatted(.dateTime.month(.abbreviated).day()))")
                                .font(MM.Fonts.metadata)
                                .foregroundStyle(overdue ? Color.red.opacity(0.85) : MM.Colors.textTertiary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button { TaskComposerController.shared.show(editing: task) } label: {
                    IconView(icon: .open, size: 12, color: MM.Colors.textTertiary)
                        .clickable()
                }
                .buttonStyle(.plain)
                .help("Edit task")
                Button { TasksStore.shared.delete(task) } label: {
                    IconView(icon: .trash, size: 12, color: MM.Colors.textTertiary)
                        .clickable()
                }
                .buttonStyle(.plain)
                .help("Delete task")
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: MM.Layout.radiusSmall, style: .continuous)
                .fill(hovering ? MM.Colors.surface : .clear)
        )
        .clickable()
        .onTapGesture { TaskComposerController.shared.show(editing: task) }
        .onHover { h in
            withAnimation(MM.Motion.gentle) { hovering = h }
        }
    }
}

// MARK: - Calendar (right)

struct CalendarPanelView: View {
    struct DayEvents: Identifiable {
        let id: String
        let date: Date
        let events: [EventLite]
    }

    struct EventLite: Identifiable {
        let id: String
        let start: Date
        let end: Date
        let title: String
        let notes: String
        let attendeeNames: [String]
        var joinURL: URL? = nil
        var hasMeetingLink: Bool { joinURL != nil }
        /// A My Man recording whose time overlaps this event → entry point.
        var meetingID: String?
        /// Direct link to THIS event on calendar.google.com, when derivable.
        var googleURL: URL?
    }

    /// Google's web UI addresses events as base64url("<eventID> <accountEmail>").
    /// EventKit exposes the Google event ID via the iCal UID ("…@google.com"),
    /// and the account email is the primary calendar's title. Nil for
    /// non-Google calendars — callers fall back to the day view.
    static func googleEventURL(for event: EKEvent) -> URL? {
        guard let ext = event.calendarItemExternalIdentifier,
              ext.hasSuffix("@google.com") else { return nil }
        let gid = String(ext.dropLast("@google.com".count))
        var email: String?
        if event.calendar.title.contains("@") {
            email = event.calendar.title
        } else if let source = event.calendar.source {
            email = source.calendars(for: .event)
                .map(\.title)
                .first { $0.contains("@") && $0.contains(".") }
        }
        guard let email else { return nil }
        let eid = Data("\(gid) \(email)".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return URL(string: "https://calendar.google.com/calendar/event?eid=\(eid)")
    }

    @State private var days: [DayEvents] = []
    @State private var accessDenied = false
    @State private var needsAccessRequest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Calendar")
                .font(MM.Fonts.title)
                .foregroundStyle(MM.Colors.textPrimary)
                .padding(.horizontal, MM.Layout.padding)
                .padding(.top, MM.Layout.padding)
                .padding(.bottom, 8)

            if days.allSatisfy({ $0.events.isEmpty }) {
                emptyState
            } else {
                // One day fills the panel; swipe/scroll pages between days.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(days) { day in
                            dayColumn(day)
                                .frame(width: 300 - MM.Layout.padding * 2)
                                // Each page fills the panel's full height so a
                                // horizontal scroll ANYWHERE in the section
                                // (including the empty space below events)
                                // switches days.
                                .frame(maxHeight: .infinity, alignment: .top)
                                .padding(.horizontal, MM.Layout.padding)
                                .contentShape(Rectangle())
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 300, height: 420, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                .fill(MM.Colors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: MM.Layout.radius, style: .continuous)
                        .strokeBorder(MM.Colors.border, lineWidth: 1)
                )
        )
        .onAppear(perform: load)
    }

    private var emptyState: some View {
        CalendarEmptyState(needsAccessRequest: needsAccessRequest, accessDenied: accessDenied) {

                if needsAccessRequest {
                    // macOS shows the calendar prompt ONCE per app, ever. If it
                    // was already answered (incl. "Add Events Only"), this call
                    // returns silently — fall through to Privacy Settings so
                    // the button always visibly does something.
                    EKEventStore().requestFullAccessToEvents { granted, _ in
                        DispatchQueue.main.async {
                            load()
                            if !granted, let url = URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    return
                }
                let pane = accessDenied
                    ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                    : "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension"
                if let url = URL(string: pane) {
                    NSWorkspace.shared.open(url)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dayColumn(_ day: DayEvents) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dayLabel(day.date))
                .font(MM.Fonts.secondary)
                .foregroundStyle(MM.Colors.textSecondary)
            let isToday = Calendar.current.isDateInToday(day.date)
            let pastCount = day.events.filter { $0.start <= Date() }.count
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(day.events.enumerated()), id: \.element.id) { index, event in
                            if isToday, index == pastCount { nowLine }
                            eventCard(event)
                                .id(index)
                        }
                        if isToday, pastCount == day.events.count, !day.events.isEmpty {
                            nowLine
                        }
                    }
                    .padding(.bottom, 4)
                }
                .overlay {
                    if day.events.isEmpty {
                        UtilityEmptyState(icon: .calendar, title: "A little breathing room", message: "No events this day.")
                    }
                }
                .onAppear {
                    // Land with NOW near the top: at most one finished event
                    // stays visible above the red line; the future fills the rest.
                    guard isToday, pastCount > 1 else { return }
                    proxy.scrollTo(pastCount - 1, anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The red "you are here" marker, sitting between what's done and what's
    /// next in today's list.
    private var nowLine: some View {
        HStack(spacing: 6) {
            Text(Date().formatted(date: .omitted, time: .shortened))
                .font(MM.Fonts.metadata)
                .foregroundStyle(Color.red.opacity(0.85))
            Rectangle()
                .fill(Color.red.opacity(0.7))
                .frame(height: 1)
        }
        .padding(.vertical, 2)
    }

    private func eventCard(_ event: EventLite) -> some View {
        CalendarEventCard(event: event,
            onOpen: { openInGoogleCalendar(event) },
            onJoin: {
                guard let url = event.joinURL else { return }
                NSWorkspace.shared.open(url)
            },
            onBrief: { openBrief(event) },
            onNotes: {
                guard let id = event.meetingID else { return }
                MeetingDocumentController.shared.open(meetingID: id)
            })
    }

    private func openBrief(_ event: EventLite) {
        Analytics.track("meeting_brief_requested")
        Toast.show("Preparing your brief…", systemImage: "sparkles")
        Task { @MainActor in
            let brief = await MeetingBrief.make(for: event)
            NotesPanelController.shared.show(draft: brief)
        }
    }

    /// The event itself when the Google link is derivable; otherwise the
    /// day view. Either way, tell the meeting detector this browser trip is
    /// OURS — it must not read it as a meeting starting.
    private func openInGoogleCalendar(_ event: EventLite) {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: event.start)
        let dayURL = parts.year.flatMap { y in
            URL(string: "https://calendar.google.com/calendar/r/day/\(y)/\(parts.month ?? 1)/\(parts.day ?? 1)")
        }
        guard let url = event.googleURL ?? dayURL else { return }
        Analytics.track("calendar_event_opened", ["direct": event.googleURL != nil])
        NotificationCenter.default.post(name: MeetingDetector.suppressNotification, object: nil)
        NSWorkspace.shared.open(url)
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func load() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            accessDenied = status == .denied || status == .restricted
            // .notDetermined (prompt never answered) or .writeOnly (the
            // lesser option on the macOS prompt) — both fixable in-app.
            needsAccessRequest = status == .notDetermined || status == .writeOnly
            days = []
            return
        }
        accessDenied = false
        needsAccessRequest = false
        // Fresh store per read — cached stores serve stale events.
        let store = EKEventStore()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        // Recorded meetings, for matching events to their My Man notes.
        let recordings: [(id: String, start: Date, end: Date)] =
            ((try? Database.shared.read { db in
                try Meeting
                    .filter(Column("transcript") != "")
                    .order(Column("startedAt").desc).limit(100).fetchAll(db)
            }) ?? []).map { ($0.id, $0.startedAt, $0.endedAt ?? $0.startedAt.addingTimeInterval(3600)) }

        var collected: [DayEvents] = []
        for offset in 0..<7 {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            // Today includes what already happened — that's where the notes are.
            let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
            let events = store.events(matching: predicate)
                .filter { !$0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
                .map { event -> EventLite in
                    // A recording overlapping the event window (±10 min slack).
                    let matched = recordings.first { rec in
                        rec.start <= (event.endDate ?? event.startDate).addingTimeInterval(600)
                            && rec.end >= event.startDate.addingTimeInterval(-600)
                    }
                    return EventLite(
                        id: event.eventIdentifier ?? UUID().uuidString,
                        start: event.startDate,
                        end: event.endDate ?? event.startDate.addingTimeInterval(1800),
                        title: event.title ?? "Untitled",
                        notes: event.notes ?? "",
                        attendeeNames: (event.attendees ?? []).filter { !$0.isCurrentUser }
                            .compactMap(\.name),
                        joinURL: CalendarWatcher.meetingURL(in: event),
                        meetingID: matched?.id,
                        googleURL: Self.googleEventURL(for: event)
                    )
                }
            collected.append(DayEvents(id: "day-\(offset)", date: dayStart, events: Array(events)))
        }
        days = collected
    }
}

/// Shared previewable empty surface; permission behavior stays in CalendarPanelView.
struct CalendarEmptyState: View {
    let needsAccessRequest: Bool
    let accessDenied: Bool
    var action: () -> Void = {}
    private var needsConnection: Bool { needsAccessRequest || accessDenied }
    var body: some View {
        UtilityEmptyState(icon: .calendar,
                          title: needsConnection ? "Your day, at a glance" : "A little breathing room",
                          message: needsConnection ? "Bring your calendar along." : "No events coming up.",
                          actionTitle: needsAccessRequest ? "Connect calendar" : accessDenied ? "Allow calendar access" : "Add a calendar",
                          action: action)
    }
}
