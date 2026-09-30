import SwiftUI

struct SchedulerView: View {
    let input: String
    var onExample: (String) -> Void = { _ in }
    @StateObject var model = SchedulerModel()
    @State private var refreshID = UUID()
    @State private var personIndex: Int?
    @State private var choosingDay = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private var empty: Bool { ["schedule", "schedule meeting", "schedule a meeting"].contains(input.lowercased()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                heading
                if empty { examples }
                if !model.people.isEmpty { chips }
                controls
                if let clarification = model.clarification { Text(clarification).font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary) }
                timeline
                suggestions
                preview
                if let message = model.message {
                    VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                        Text(message).font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
                        HStack {
                            if model.needsGrants { Button("Scheduling permissions…") { SettingsController.shared.show() }.clickable() }
                            if model.needsOSPermission { Button("Allow Calendar access…") { Permission.calendar.request() }.clickable() }
                            Button("Check again") { refreshID = UUID() }.clickable()
                        }.font(MM.Fonts.secondary).buttonStyle(.plain)
                    }.padding(MM.Layout.padding).frame(maxWidth: .infinity, alignment: .leading)
                        .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                }
            }.padding(MM.Layout.paddingLarge)
        }
        .frame(height: min(MM.Layout.schedulerHeight, (NSScreen.main?.visibleFrame.height ?? 800) - 180))
        .background(MM.Colors.background)
        .task(id: input) {
            model.invalidate()
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await model.load(input)
        }
        .task(id: refreshID) { if model.hasAvailability || model.message != nil { await model.load(input) } }
        .onDisappear { model.invalidate() }
        .animation(reducedMotion ? nil : MM.Motion.gentle, value: model.loading)
    }
    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                Text("Make time.").font(MM.Fonts.result)
                Text("A little space for a good conversation.").font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
            }
            Spacer()
            Label("Only your calendar", systemImage: "lock").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                .padding(MM.Layout.spacing / 2).background(MM.Colors.surface, in: Capsule())
        }
    }
    private var examples: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
            ForEach(["Coffee with Developer Friday at 10am for 30 min", "Meeting with Jilles and Harshil tomorrow"], id: \.self) { prompt in
                Button { onExample(prompt) } label: {
                    HStack { Text(prompt); Spacer(); Image(systemName: "arrow.up.left") }.font(MM.Fonts.secondary).clickable()
                }.buttonStyle(.plain).foregroundStyle(MM.Colors.textSecondary)
            }
        }
    }
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MM.Layout.spacing / 2) {
                ForEach(Array(model.people.enumerated()), id: \.offset) { index, name in
                    Button { personIndex = index } label: {
                        HStack(spacing: MM.Layout.spacing / 2) {
                            Text(String(name.prefix(1)).uppercased()).font(MM.Fonts.metadata)
                                .frame(width: MM.Layout.spacing * 2, height: MM.Layout.spacing * 2)
                                .background(MM.Colors.border, in: Circle())
                            Text(name).font(MM.Fonts.secondary)
                            Image(systemName: "chevron.down").font(MM.Fonts.hint)
                        }.padding(.trailing, MM.Layout.spacing).padding(.vertical, MM.Layout.spacing / 3)
                            .background(MM.Colors.surface, in: Capsule()).clickable()
                    }.buttonStyle(.plain).fixedSize()
                        .popover(isPresented: Binding(get: { personIndex == index }, set: { if !$0 { personIndex = nil } })) {
                            VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                                Text(name).font(MM.Fonts.title)
                                Text("Availability not shared").font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
                                if let match = model.matches.first(where: { $0.input == name || $0.candidates.contains(where: { $0.name == name }) }) {
                                    ForEach(Array(match.candidates.enumerated()), id: \.offset) { _, candidate in
                                        Button(candidate.name + (candidate.email.map { " · " + $0 } ?? "")) { model.choose(candidate, for: index); personIndex = nil }.clickable()
                                    }
                                }
                                Button("Remove from preview") { model.people.remove(at: index); personIndex = nil }.clickable()
                            }.font(MM.Fonts.secondary).padding(MM.Layout.padding)
                        }
                        .accessibilityLabel("\(name), guest label. Availability unknown. Choose a saved person or remove.")
                }
            }
        }
    }
    private var controls: some View {
        HStack(spacing: MM.Layout.spacing) {
            Button { choosingDay = true } label: {
                HStack(spacing: MM.Layout.spacing / 2) {
                    Image(systemName: "calendar")
                    Text(model.format(model.day, "EEE, MMM d"))
                    Image(systemName: "chevron.down").font(MM.Fonts.hint)
                }.font(MM.Fonts.secondary).clickable()
            }.buttonStyle(.plain).accessibilityLabel("Meeting date, " + model.format(model.day, "EEEE, MMMM d"))
                .popover(isPresented: $choosingDay) {
                    DatePicker("Meeting date", selection: Binding(get: { model.day }, set: { model.day = $0; refresh() }), displayedComponents: .date)
                        .datePickerStyle(.graphical).padding(MM.Layout.padding).clickable()
                }
            Spacer()
            Text(model.zone.identifier.replacingOccurrences(of: "_", with: " ")).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            HStack(spacing: MM.Layout.spacing / 2) {
                Button { model.duration = max(15, model.duration - 15); refresh() } label: { Image(systemName: "minus").clickable() }
                    .disabled(model.duration <= 15).accessibilityLabel("Shorten meeting by 15 minutes")
                Text("\(model.duration) min").font(MM.Fonts.secondary).monospacedDigit().frame(minWidth: MM.Layout.spacing * 4)
                Button { model.duration = min(480, model.duration + 15); refresh() } label: { Image(systemName: "plus").clickable() }
                    .disabled(model.duration >= 480).accessibilityLabel("Lengthen meeting by 15 minutes")
            }.buttonStyle(.plain).padding(MM.Layout.spacing / 2)
                .background(MM.Colors.surface, in: Capsule())
        }
    }
    private var timeline: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            HStack {
                Text("THE DAY AT A GLANCE").font(MM.Fonts.metadata).tracking(1)
                Spacer()
                Label("Busy", systemImage: "rectangle.fill").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: MM.Layout.schedulerLabelWidth)
                ForEach(["9 AM", "12 PM", "3 PM", "6 PM"], id: \.self) { label in
                    Text(label).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                    if label != "6 PM" { Spacer(minLength: 0) }
                }
            }
            timelineRow("You", known: model.hasAvailability)
            ForEach(Array(model.people.prefix(4).enumerated()), id: \.offset) { _, name in timelineRow(name, known: false) }
            if model.people.count > 4 { Text("+\(model.people.count - 4) more guests · availability not shared").font(MM.Fonts.metadata) }
            Text("Your free time is shown below. Guests’ availability isn’t shared.")
                .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
        }
    }
    private func timelineRow(_ name: String, known: Bool) -> some View {
        HStack(spacing: 0) {
            Text(name).font(MM.Fonts.secondary).lineLimit(1).frame(width: MM.Layout.schedulerLabelWidth, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).fill(MM.Colors.surface)
                    HStack { ForEach(0..<10) { _ in Rectangle().fill(MM.Colors.border).frame(width: 1); Spacer(minLength: 0) } }
                    if known {
                        ForEach(Array(model.busy.enumerated()), id: \.offset) { _, block in interval(block.start, block.end, width: geometry.size.width, selected: false) }
                        if let start = model.selected, let end = model.end { interval(start, end, width: geometry.size.width, selected: true) }
                    } else {
                        Text(name == "You" ? "Availability not loaded" : "Not shared").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        guard known else { return }
                        let minutes = 540 + Int((min(1, max(0, value.location.x / geometry.size.width)) * 540 / 15).rounded()) * 15
                        model.select(model.date(at: min(1080 - model.duration, minutes)))
                    })
            }.frame(height: MM.Layout.spacing * 3)
                .focusable(known).accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name) availability timeline")
                .accessibilityValue(known ? model.selected.map { "Selected " + model.time($0) } ?? "Choose a time" : "Unknown")
                .accessibilityHint(known ? "Use left and right arrows to move the selection by 15 minutes. Or use the time picker below." : "")
                .onKeyPress(.leftArrow) { move(-15, known: known) }
                .onKeyPress(.rightArrow) { move(15, known: known) }
        }
    }
    private func interval(_ start: Date, _ end: Date, width: CGFloat, selected: Bool) -> some View {
        let origin = model.date(at: 540), total = model.date(at: 1080).timeIntervalSince(origin)
        let a = min(1, max(0, start.timeIntervalSince(origin) / total)), b = min(1, max(0, end.timeIntervalSince(origin) / total))
        return RoundedRectangle(cornerRadius: MM.Layout.radiusSmall / 2)
            .fill(selected ? MM.Colors.accent : MM.Colors.textSecondary.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall / 2).strokeBorder(selected ? MM.Colors.onAccent : MM.Colors.textSecondary, lineWidth: 1))
            .frame(width: max(0, (b - a) * width), height: MM.Layout.spacing * 2)
            .offset(x: a * width).accessibilityHidden(true)
    }
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            HStack {
                Text(model.loading ? "Finding a little space…" : "You’re free at").font(MM.Fonts.body)
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MM.Layout.spacing / 2) {
                    ForEach(model.slots, id: \.self) { slot in
                        Button { model.select(slot) } label: {
                            Text(model.time(slot)).font(MM.Fonts.secondary)
                                .foregroundStyle(model.selected == slot ? MM.Colors.onAccent : MM.Colors.textPrimary)
                                .padding(.horizontal, MM.Layout.spacing).padding(.vertical, MM.Layout.spacing * 0.75)
                                .background(model.selected == slot ? MM.Colors.accent : MM.Colors.surface, in: Capsule()).clickable()
                        }.buttonStyle(.plain).accessibilityLabel("Choose \(model.time(slot))")
                            .accessibilityAddTraits(model.selected == slot ? .isSelected : [])
                    }
                }
            }
        }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            HStack {
                Image(systemName: "calendar").font(MM.Fonts.title).foregroundStyle(MM.Colors.textSecondary)
                TextField("Meeting title", text: $model.title).textFieldStyle(.plain).font(MM.Fonts.title).accessibilityLabel("Meeting title")
                Text("PREVIEW").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            }
            HStack {
                VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
                    Text(model.format(model.day, "EEEE, MMM d")).font(MM.Fonts.body)
                    Text(model.selected.map { model.time($0) + " – " + model.time(model.end!) } ?? "Choose a free time")
                        .font(MM.Fonts.secondary).foregroundStyle(MM.Colors.textSecondary)
                }
                Spacer()
                DatePicker("Time", selection: Binding(get: { model.selected ?? model.date(at: 540) }, set: { model.select($0) }), displayedComponents: .hourAndMinute)
                    .labelsHidden().disabled(!model.hasAvailability).accessibilityLabel("Choose meeting start time").clickable()
            }
            Divider().overlay(MM.Colors.border)
            HStack {
                Label("\(model.people.count) guest\(model.people.count == 1 ? "" : "s") · no invitations", systemImage: "person.2")
                    .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                Spacer()
                Text("Nothing booked yet").font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
            }
        }.padding(MM.Layout.padding).background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radius))
            .overlay(RoundedRectangle(cornerRadius: MM.Layout.radius).strokeBorder(MM.Colors.border))
    }
    private func refresh() { model.invalidate(); Task { await model.refresh() } }
    private func move(_ minutes: Int, known: Bool) -> KeyPress.Result {
        guard known else { return .ignored }
        model.select((model.selected ?? model.date(at: 540)).addingTimeInterval(Double(minutes * 60))); return .handled
    }
}
