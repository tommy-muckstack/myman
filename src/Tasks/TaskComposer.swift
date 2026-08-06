import AppKit
import SwiftUI

// Task creation and editing. This is a real key window (unlike the pinned
// tasks panel, which deliberately never takes keyboard focus). It survives
// focus loss — people leave to copy links mid-thought.

@MainActor
final class TaskComposerController {
    static let shared = TaskComposerController()
    private var panel: FloatingPanel?

    func show(editing task: TaskItem? = nil) {
        panel?.orderOut(nil)
        let view = TaskComposerView(task: task, onDone: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
        })
        let composer = FloatingPanel(content: view, becomesKey: true)
        // Half-typed tasks survive trips to other windows for links etc. —
        // only Cancel/Esc/Save closes this.
        composer.dismissesOnResign = false
        composer.onDismiss = { [weak self] in self?.panel = nil }
        panel = composer
        composer.layoutIfNeeded()
        guard let screen = NSScreen.main else { return }
        let size = composer.contentIdeal
        let visible = screen.visibleFrame
        composer.setFrame(
            NSRect(x: visible.midX - size.width / 2,
                   y: visible.midY - size.height / 2 + 60,
                   width: size.width, height: size.height),
            display: true
        )
        composer.orderFrontRegardless()
        composer.makeKey()
    }
}

private struct TaskComposerView: View {
    let task: TaskItem?
    var onDone: () -> Void

    @State private var title: String
    @State private var notes: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @FocusState private var titleFocused: Bool

    init(task: TaskItem?, onDone: @escaping () -> Void) {
        self.task = task
        self.onDone = onDone
        _title = State(initialValue: task?.title ?? "")
        _notes = State(initialValue: task?.notes ?? "")
        _hasDueDate = State(initialValue: task?.dueDate != nil)
        _dueDate = State(initialValue: task?.dueDate
            ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("", text: $title, prompt: Text("What needs doing?")
                .foregroundStyle(MM.Colors.textTertiary))
                .textFieldStyle(.plain)
                .font(MM.Fonts.outfit(19, .medium))
                .foregroundStyle(MM.Colors.textPrimary)
                .focused($titleFocused)
                .onSubmit(save)

            TextField("", text: $notes, prompt: Text("Details (optional)")
                .foregroundStyle(MM.Colors.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...8)
                .font(MM.Fonts.body)
                .foregroundStyle(MM.Colors.textPrimary)

            dueDateRow

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onDone)
                    .buttonStyle(.plain)
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textSecondary)
                    .clickable(minSize: 26)
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    Text(task == nil ? "Add Task" : "Save")
                        .font(MM.Fonts.secondary)
                        .foregroundStyle(MM.Colors.background)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(Capsule().fill(
                            title.trimmingCharacters(in: .whitespaces).isEmpty
                                ? MM.Colors.textTertiary : MM.Colors.textPrimary))
                        .fixedSize()
                        .clickable(minSize: 26)
                }
                .buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MM.Colors.background)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MM.Colors.border, lineWidth: 1))
        )
        .onAppear { titleFocused = true }
    }

    /// Due dates the way people actually pick them: two chips for the 90%
    /// case, a native field for everything else.
    private var dueDateRow: some View {
        HStack(spacing: 6) {
            if hasDueDate {
                DatePicker("", selection: $dueDate, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .fixedSize()
                Text("✕")
                    .font(MM.Fonts.secondary)
                    .foregroundStyle(MM.Colors.textTertiary)
                    .clickable(minSize: 22)
                    .onTapGesture { hasDueDate = false }
                    .help("Remove due date")
            } else {
                Button {
                    hasDueDate = true
                } label: {
                    HStack(spacing: 5) {
                        IconView(icon: .calendar, size: 13, color: MM.Colors.textSecondary)
                        Text("Due date")
                            .font(MM.Fonts.secondary)
                            .foregroundStyle(MM.Colors.textSecondary)
                    }
                    .clickable(minSize: 24)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let task {
            TasksStore.shared.update(task, title: trimmed, notes: notes,
                                     dueDate: hasDueDate ? dueDate : nil)
        } else {
            TasksStore.shared.add(title: trimmed, notes: notes,
                                  dueDate: hasDueDate ? dueDate : nil)
        }
        onDone()
    }
}
