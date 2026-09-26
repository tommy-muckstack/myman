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
    var inline = false

    var body: some View {
        Group {
            if inline {
                InlineTasksView(tasks: store.openTasks)
            } else { companion }
        }.onAppear { store.refresh() }
    }

    private var companion: some View {
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
    }
}

struct InlineTasksView: View {
    let tasks: [TaskItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tasks.isEmpty ? "No open tasks" : "\(tasks.count) open tasks")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                Spacer()
                Button { TaskComposerController.shared.show() } label: {
                    HStack(spacing: MM.Layout.spacing / 2) {
                        IconView(icon: .addBox)
                        Text("Add task").font(MM.Fonts.secondary)
                    }.clickable()
                }.buttonStyle(.plain)
            }.padding(MM.Layout.padding)
            if !tasks.isEmpty {
                AdaptiveResultScroll {
                    VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                        ForEach(tasks) { TaskRow(task: $0) }
                    }.padding(.horizontal, MM.Layout.spacing / 2).padding(.bottom, MM.Layout.spacing)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TaskRow: View {
    let task: TaskItem
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Button { TasksStore.shared.toggle(task) } label: {
                IconView(icon: task.done ? .checklistChecked : .checklistUnchecked,
                         color: task.done ? MM.Colors.accent : MM.Colors.textTertiary)
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
    var inline = false
    var request: LauncherCalendarRequest = .today
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
        var isAllDay = false
        var location: String? = nil
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
        Group {
            if inline {
                InlineCalendarView(days: days, needsAccessRequest: needsAccessRequest, accessDenied: accessDenied,
                                   onAccess: requestAccess, request: request, eventContent: { eventCard($0) })
            } else { companion }
        }.onAppear(perform: load)
            .onChange(of: request) { _, _ in load() }
    }

    private var companion: some View {
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
    }

    private var emptyState: some View {
        CalendarEmptyState(needsAccessRequest: needsAccessRequest, accessDenied: accessDenied, action: requestAccess)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func requestAccess() {
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
            }, inline: inline)
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
        let rangeStart = request.startDate(calendar: calendar)

        // Recorded meetings, for matching events to their My Man notes.
        let recordings: [(id: String, start: Date, end: Date)] =
            ((try? Database.shared.read { db in
                try Meeting
                    .filter(Column("transcript") != "")
                    .order(Column("startedAt").desc).limit(100).fetchAll(db)
            }) ?? []).map { ($0.id, $0.startedAt, $0.endedAt ?? $0.startedAt.addingTimeInterval(3600)) }

        var collected: [DayEvents] = []
        for offset in 0..<7 {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: rangeStart),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            // Today includes what already happened — that's where the notes are.
            let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
            let events = store.events(matching: predicate)
                .sorted { left, right in
                    if left.isAllDay != right.isAllDay { return left.isAllDay }
                    return left.startDate < right.startDate
                }
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
                        googleURL: Self.googleEventURL(for: event),
                        isAllDay: event.isAllDay,
                        location: event.location
                    )
                }
            collected.append(DayEvents(id: "day-\(offset)", date: dayStart, events: Array(events)))
        }
        days = collected
    }
}

/// The same projection drives day, week and next-event requests and day clicks.
struct InlineCalendarAgenda {
    let days: [CalendarPanelView.DayEvents]
    var request: LauncherCalendarRequest = .today
    var selectedDay: Int? = nil
    var now = Date()
    var calendar = Calendar.current

    var nextEvent: CalendarPanelView.EventLite? {
        days.flatMap(\.events).filter { !$0.isAllDay && $0.start >= now }
            .min { $0.start < $1.start }
    }

    var activeDay: Int? {
        if let selectedDay, days.indices.contains(selectedDay) { return selectedDay }
        if request == .week || request == .upcoming { return nil }
        let date = request == .next ? nextEvent?.start : request.selectedDate(now: now, calendar: calendar)
        return date.flatMap { date in days.firstIndex { calendar.isDate($0.date, inSameDayAs: date) } }
    }

    var sections: [CalendarPanelView.DayEvents] {
        if selectedDay == nil, request == .next {
            guard let event = nextEvent, let index = activeDay else { return [] }
            return [.init(id: days[index].id, date: days[index].date, events: [event])]
        }
        if let index = activeDay { return [days[index]] }
        if request == .week { return days.filter { !$0.events.isEmpty } }
        if request == .upcoming {
            return days.compactMap { day in
                let events = day.events.filter { $0.end > now }
                return events.isEmpty ? nil : .init(id: day.id, date: day.date, events: events)
            }
        }
        return []
    }

    var isOverview: Bool { selectedDay == nil && (request == .week || request == .upcoming) }
}

struct InlineCalendarView<EventContent: View>: View {
    let days: [CalendarPanelView.DayEvents]
    let needsAccessRequest: Bool
    let accessDenied: Bool
    var onAccess: () -> Void
    var request: LauncherCalendarRequest = .today
    @ViewBuilder var eventContent: (CalendarPanelView.EventLite) -> EventContent
    @State private var selectedDay: Int?

    private var agenda: InlineCalendarAgenda { .init(days: days, request: request, selectedDay: selectedDay) }
    private var monthDate: Date { agenda.activeDay.map { days[$0].date } ?? days.first?.date ?? .now }
    private var heading: String {
        if selectedDay == nil {
            if request == .week { return "This week" }
            if request == .upcoming { return "Coming up" }
            if request == .next { return "Next event" }
        }
        guard let index = agenda.activeDay else { return "Your schedule" }
        return dayTitle(days[index].date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if needsAccessRequest || accessDenied {
                CalendarEmptyState(needsAccessRequest: needsAccessRequest, accessDenied: accessDenied, compact: true, action: onAccess)
                    .padding(MM.Layout.padding)
            } else {
                monthHeader
                dayStrip
                agendaContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: request) { _, _ in selectedDay = nil }
    }

    private var monthHeader: some View {
        HStack {
            Text(monthDate.formatted(.dateTime.month(.wide).year()))
                .font(MM.Fonts.bodyInput).foregroundStyle(MM.Colors.textPrimary)
            Spacer()
            Button {
                selectedDay = days.firstIndex { Calendar.current.isDateInToday($0.date) }
            } label: {
                Text("Today").font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
                    .padding(.horizontal, MM.Layout.spacing)
                    .background(MM.Colors.surface, in: Capsule()).clickable()
            }.buttonStyle(.plain).accessibilityLabel("Show today's events")
        }.padding(.horizontal, MM.Layout.paddingLarge).padding(.top, MM.Layout.padding)
    }

    private var dayStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                dayButton(day, index: index)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, MM.Layout.padding)
        .padding(.vertical, MM.Layout.spacing)
    }

    private func dayButton(_ day: CalendarPanelView.DayEvents, index: Int) -> some View {
        let selected = agenda.activeDay == index && !agenda.isOverview
        let today = Calendar.current.isDateInToday(day.date)
        return Button { selectedDay = index } label: {
            VStack(spacing: MM.Layout.spacing / 2) {
                Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(MM.Fonts.metadata)
                    .foregroundStyle(today ? MM.Colors.accent : MM.Colors.textSecondary)
                Text(day.date.formatted(.dateTime.day()))
                    .font(MM.Fonts.bodyInput).monospacedDigit()
                    .foregroundStyle(selected ? MM.Colors.onAccent : MM.Colors.textPrimary)
                    .frame(width: MM.Layout.padding * 2, height: MM.Layout.padding * 2)
                    .background(selected ? MM.Colors.accent : .clear, in: Circle())
                    .overlay(Circle().strokeBorder(today && !selected ? MM.Colors.accent : .clear))
                Circle().fill(day.events.isEmpty ? .clear : MM.Colors.textTertiary)
                    .frame(width: MM.Layout.spacing / 3, height: MM.Layout.spacing / 3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle()).clickable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
        .accessibilityValue("\(day.events.count) events")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var agendaContent: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
            HStack {
                Text(heading).font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
                Spacer()
                let count = agenda.sections.reduce(0) { $0 + $1.events.count }
                if count > 0 {
                    Text("\(count) \(count == 1 ? "event" : "events")")
                        .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                }
            }.padding(.horizontal, MM.Layout.paddingLarge)
            if agenda.sections.allSatisfy({ $0.events.isEmpty }) {
                Text(request == .next && selectedDay == nil ? "No upcoming events in the next 7 days" : "No events scheduled")
                    .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textTertiary)
                    .padding(.horizontal, MM.Layout.paddingLarge).padding(.bottom, MM.Layout.padding)
            } else {
                AdaptiveResultScroll {
                    VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                        ForEach(agenda.sections) { day in
                            if agenda.isOverview {
                                Text(dayTitle(day.date)).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
                                    .padding(.horizontal, MM.Layout.spacing).padding(.top, MM.Layout.spacing)
                            }
                            ForEach(day.events) { eventContent($0) }
                        }
                    }.padding(.horizontal, MM.Layout.spacing).padding(.bottom, MM.Layout.spacing)
                }
            }
        }
    }

    private func dayTitle(_ date: Date) -> String {
        let day = Calendar.current.isDateInToday(date) ? "Today" : Calendar.current.isDateInTomorrow(date) ? "Tomorrow" : date.formatted(.dateTime.weekday(.wide))
        return day + ", " + date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Shared previewable empty surface; permission behavior stays in CalendarPanelView.
struct CalendarEmptyState: View {
    let needsAccessRequest: Bool
    let accessDenied: Bool
    var compact = false
    var action: () -> Void = {}
    private var needsConnection: Bool { needsAccessRequest || accessDenied }
    var body: some View {
        UtilityEmptyState(icon: .calendar,
                          title: needsConnection ? "Your day, at a glance" : "A little breathing room",
                          message: needsConnection ? "Bring your calendar along." : "No events coming up.",
                          actionTitle: needsAccessRequest ? "Connect calendar" : accessDenied ? "Allow calendar access" : "Add a calendar",
                          compact: compact, action: action)
    }
}
