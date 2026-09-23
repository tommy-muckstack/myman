import SwiftUI

struct ReminderSchedulePicker: View {
    @Binding var date: Date
    @State private var calendarOpen = false
    @State private var timeOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            HStack(spacing: MM.Layout.spacing / 2) {
                preset("In 15 minutes") { date = Date().addingTimeInterval(15 * 60) }
                preset("In 1 hour") { date = Date().addingTimeInterval(60 * 60) }
                preset("Tomorrow morning") {
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                    date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
                }
            }
            HStack(spacing: MM.Layout.spacing) {
                Button { calendarOpen.toggle() } label: {
                    scheduleLabel(dayLabel, icon: .calendar)
                }.buttonStyle(.plain).accessibilityLabel("Choose reminder date")
                    .popover(isPresented: $calendarOpen, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
                            Text("Choose a day").font(MM.Fonts.secondary)
                            ReminderCalendarPicker(date: $date) { calendarOpen = false }
                            HStack {
                                preset("Today") { setDay(Date()); calendarOpen = false }
                                preset("Tomorrow") { setDay(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()); calendarOpen = false }
                                Spacer()
                                Button("Done") { calendarOpen = false }.buttonStyle(.plain).clickable()
                            }.font(MM.Fonts.secondary)
                        }.padding(MM.Layout.padding).frame(width: 300)
                            .background(MM.Colors.background)
                    }
                Button { timeOpen.toggle() } label: {
                    scheduleLabel(date.formatted(date: .omitted, time: .shortened), icon: .timer)
                }.buttonStyle(.plain).accessibilityLabel("Choose reminder time")
                    .popover(isPresented: $timeOpen, arrowEdge: .bottom) {
                        ReminderTimePicker(date: $date, onDone: { timeOpen = false })
                    }
            }
        }
    }

    private var dayLabel: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func setDay(_ day: Date) {
        date = Calendar.current.date(bySettingHour: Calendar.current.component(.hour, from: date),
                                     minute: Calendar.current.component(.minute, from: date), second: 0, of: day) ?? day
    }

    private func preset(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textSecondary)
                .padding(.horizontal, MM.Layout.spacing).padding(.vertical, MM.Layout.spacing / 2)
                .background(MM.Colors.surface, in: Capsule()).clickable(minSize: 28)
        }.buttonStyle(.plain)
    }

    private func scheduleLabel(_ label: String, icon: MMIcon) -> some View {
        HStack(spacing: MM.Layout.spacing) {
            IconView(icon: icon)
            Text(label).font(MM.Fonts.secondary)
            Spacer(minLength: MM.Layout.spacing)
        }.padding(.horizontal, MM.Layout.padding).frame(minHeight: 44)
            .foregroundStyle(MM.Colors.textPrimary)
            .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: MM.Layout.radiusSmall).strokeBorder(MM.Colors.border, lineWidth: 1))
            .clickable()
    }
}

struct ReminderTimePicker: View {
    @Binding var date: Date
    var onDone: () -> Void
    private var calendar: Calendar { .current }
    private var hour: Int { calendar.component(.hour, from: date) }
    private var minute: Int { calendar.component(.minute, from: date) }

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing) {
            Text("Choose a time").font(MM.Fonts.secondary)
            HStack(spacing: MM.Layout.padding) {
                numberColumn("Hour", value: Binding(get: { hour % 12 == 0 ? 12 : hour % 12 }, set: {
                    guard (1...12).contains($0) else { return }
                    setTime(hour: $0 % 12 + (hour >= 12 ? 12 : 0), minute: minute)
                }), range: 1...12)
                Text(":").font(MM.Fonts.title)
                numberColumn("Minute", value: Binding(get: { minute }, set: {
                    guard (0...59).contains($0) else { return }
                    setTime(hour: hour, minute: $0)
                }), range: 0...59)
                VStack(spacing: MM.Layout.spacing / 2) {
                    period("AM", isPM: false)
                    period("PM", isPM: true)
                }
            }
            HStack {
                Button { date = date.addingTimeInterval(-300) } label: { Text("−5 min").padding(MM.Layout.spacing / 2).clickable() }
                Button { date = date.addingTimeInterval(300) } label: { Text("+5 min").padding(MM.Layout.spacing / 2).clickable() }
                Spacer()
                Button(action: onDone) { Text("Done").padding(MM.Layout.spacing / 2).clickable() }.keyboardShortcut(.defaultAction)
            }.buttonStyle(.plain).font(MM.Fonts.secondary)
        }.padding(MM.Layout.padding).background(MM.Colors.background)
    }

    private func numberColumn(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(spacing: MM.Layout.spacing / 2) {
            Button {
                value.wrappedValue = value.wrappedValue == range.upperBound ? range.lowerBound : value.wrappedValue + 1
            } label: { Text("+").font(MM.Fonts.secondary).frame(width: 52, height: 28).clickable() }
                .accessibilityLabel("Increase \(label.lowercased())")
            TextField(label, value: value, format: .number.grouping(.never))
                .textFieldStyle(.plain).multilineTextAlignment(.center)
                .font(MM.Fonts.title).monospacedDigit().frame(width: 52, height: 40)
                .background(MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                .accessibilityLabel(label)
            Button {
                value.wrappedValue = value.wrappedValue == range.lowerBound ? range.upperBound : value.wrappedValue - 1
            } label: { Text("−").font(MM.Fonts.secondary).frame(width: 52, height: 28).clickable() }
                .accessibilityLabel("Decrease \(label.lowercased())")
            Text(label).font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary)
        }.buttonStyle(.plain)
    }

    private func period(_ label: String, isPM: Bool) -> some View {
        Button { setTime(hour: hour % 12 + (isPM ? 12 : 0), minute: minute) } label: {
            Text(label).font(MM.Fonts.secondary)
                .foregroundStyle((hour >= 12) == isPM ? MM.Colors.onAccent : MM.Colors.textSecondary)
                .frame(width: 48, height: 36)
                .background((hour >= 12) == isPM ? MM.Colors.accent : MM.Colors.surface,
                            in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                .clickable()
        }.buttonStyle(.plain)
    }

    private func setTime(hour: Int, minute: Int) {
        date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }
}

/// Full-width day targets, with the selected time preserved when choosing a day.
struct ReminderCalendarPicker: View {
    @Binding var date: Date
    var onSelect: () -> Void
    @State private var month = Date()
    private var calendar: Calendar { .current }
    private var monthStart: Date { calendar.dateInterval(of: .month, for: month)?.start ?? month }
    private var leadingDays: Int { (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7 }
    private var dayCount: Int { calendar.range(of: .day, in: .month, for: month)?.count ?? 31 }

    var body: some View {
        VStack(spacing: MM.Layout.spacing) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(MM.Fonts.secondary)
                Spacer()
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28).clickable() }
                    .accessibilityLabel("Previous month")
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28).clickable() }
                    .accessibilityLabel("Next month")
            }.buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MM.Layout.spacing / 2), count: 7), spacing: MM.Layout.spacing / 2) {
                ForEach(0..<7, id: \.self) { index in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                        .font(MM.Fonts.metadata).foregroundStyle(MM.Colors.textTertiary).frame(maxWidth: .infinity)
                }
                ForEach(0..<(leadingDays + dayCount), id: \.self) { index in
                    if index < leadingDays { Color.clear.frame(height: 36) }
                    else if let day = calendar.date(byAdding: .day, value: index - leadingDays, to: monthStart) {
                        dayButton(day, number: index - leadingDays + 1)
                    }
                }
            }
        }.foregroundStyle(MM.Colors.textPrimary)
            .onAppear { month = date }
    }

    private func dayButton(_ day: Date, number: Int) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: date)
        let past = day < calendar.startOfDay(for: Date())
        return Button {
            date = calendar.date(bySettingHour: calendar.component(.hour, from: date),
                                 minute: calendar.component(.minute, from: date), second: 0, of: day) ?? day
            onSelect()
        } label: {
            Text(String(number)).font(MM.Fonts.secondary).monospacedDigit()
                .foregroundStyle(selected ? MM.Colors.onAccent : past ? MM.Colors.textTertiary : MM.Colors.textPrimary)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(selected ? MM.Colors.accent : MM.Colors.surface, in: RoundedRectangle(cornerRadius: MM.Layout.radiusSmall))
                .clickable()
        }.buttonStyle(.plain).disabled(past)
            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func changeMonth(_ amount: Int) {
        month = calendar.date(byAdding: .month, value: amount, to: monthStart) ?? month
    }
}
