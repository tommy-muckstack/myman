import AppKit
import SwiftUI

@MainActor final class CalendarBookingWindow: NSObject, NSWindowDelegate {
    static let shared = CalendarBookingWindow()
    private var window: NSWindow?
    private var session: CalendarBookingSession?
    func show(_ session: CalendarBookingSession) {
        window?.close()
        self.session = session
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:MM.Layout.bookingWidth,height:MM.Layout.bookingHeight),
                              styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Review your meeting"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView:CalendarBookingView(session:session,onClose:{ [weak self] in self?.window?.close() }))
        self.window = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { session?.state != .saving }
    func windowWillClose(_ notification: Notification) { session?.cancel() }
}

struct CalendarBookingView: View {
    @ObservedObject var session: CalendarBookingSession
    let onClose: () -> Void
    private func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter(); f.timeZone = session.draft.zone; f.dateFormat = pattern; return f.string(from:date)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:MM.Layout.paddingLarge) {
            HStack {
                Image(systemName:session.state == .booked ? "checkmark.circle.fill" : "calendar")
                    .font(MM.Fonts.result).foregroundStyle(MM.Colors.accent)
                Spacer()
                Text("YOUR CALENDAR ONLY").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            }
            VStack(alignment:.leading,spacing:MM.Layout.spacing / 2) {
                Text(session.state == .booked ? "You’re booked." : "One last look.").font(MM.Fonts.result)
                Text(session.state == .booked ? "Your event is saved. No invitations were sent." : "Review the details, then press Book to save your event.")
                    .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
                if let owner = session.owner {
                    Text("Requested by \(owner.name)").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                }
            }
            ScrollView {
                VStack(alignment:.leading,spacing:MM.Layout.padding) {
                    Text(session.draft.title).font(MM.Fonts.title).textSelection(.enabled)
                    Label(format(session.draft.start,"EEEE, MMMM d, yyyy"),systemImage:"calendar")
                    Label(format(session.draft.start,"h:mm a") + " – " + format(session.draft.end,"h:mm a") + " · \(session.draft.duration) min",systemImage:"clock")
                    Text(session.draft.zone.identifier.replacingOccurrences(of:"_",with:" ")).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                    if !session.draft.guests.isEmpty {
                        Label(session.draft.guests.joined(separator:", "),systemImage:"person.2")
                        Text("Guest names are saved in your notes. Their availability is unknown; no one receives an invitation.")
                            .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                    }
                    Divider().overlay(MM.Colors.border)
                    HStack {
                        Text("Calendar").foregroundStyle(MM.Colors.textSecondary)
                        Spacer(minLength: MM.Layout.spacing)
                        Picker("Calendar", selection: $session.calendarID) {
                            ForEach(session.calendars, id: \.id) { calendar in
                                Text(calendar.title).tag(calendar.id)
                            }
                        }.labelsHidden().pickerStyle(.menu).controlSize(.regular)
                            .font(MM.Fonts.systemControl).fixedSize()
                            .disabled(session.state != .pending).clickable()
                            .accessibilityLabel("Destination calendar")
                    }.font(MM.Fonts.systemControl)
                }.font(MM.Fonts.body).padding(MM.Layout.padding).frame(maxWidth:.infinity,alignment:.leading)
                    .background(MM.Colors.surface,in:RoundedRectangle(cornerRadius:MM.Layout.radius))
            }
            if let message = session.message { Text(message).font(MM.Fonts.secondary).foregroundStyle(MM.Colors.danger) }
            HStack {
                if session.state == .pending {
                    Button("Cancel") { session.cancel(); onClose() }.keyboardShortcut(.cancelAction).clickable()
                    Spacer()
                    Button { Task { await session.bookFromHuman() } } label: {
                        Text("Book").font(MM.Fonts.body).foregroundStyle(MM.Colors.onAccent)
                            .padding(.horizontal,MM.Layout.paddingLarge * 2).padding(.vertical,MM.Layout.spacing)
                            .background(MM.Colors.accent,in:Capsule()).clickable()
                    }.buttonStyle(.plain).accessibilityLabel("Book this event on my calendar")
                        .accessibilityHint("Creates one event with these details. No guest invitations are sent.")
                } else if session.state == .saving {
                    ProgressView().controlSize(.small)
                    Text("Checking availability and saving…").font(MM.Fonts.secondary)
                } else {
                    Spacer()
                    Button("Done") { onClose() }.keyboardShortcut(.cancelAction).clickable()
                }
            }.buttonStyle(.plain)
        }.padding(MM.Layout.paddingLarge).frame(width:MM.Layout.bookingWidth,height:MM.Layout.bookingHeight)
            .foregroundStyle(MM.Colors.textPrimary).background(MM.Colors.background)
            .onReceive(Timer.publish(every:1,on:.main,in:.common).autoconnect()) { _ in session.updateExpiry() }
    }
}
