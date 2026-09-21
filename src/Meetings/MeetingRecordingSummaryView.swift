import AppKit
import SwiftUI

struct MeetingRecordingSummaryView: View {
    let meetingID: String?
    var savedSummary = ""
    @ObservedObject var service: MeetingNotesService = .shared

    private var summary: String {
        meetingID.flatMap { service.drafts[$0] } ?? savedSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MM.Layout.spacing / 2) {
            Text("Live summary")
                .font(MM.Fonts.metadata)
                .foregroundStyle(MM.Colors.textSecondary)
            if summary.isEmpty {
                UtilityEmptyState(icon: .calendar, title: "Summary takes shape here",
                                  message: "A summary will appear as the conversation is transcribed.", compact: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RecordingSummaryText(markdown: summary)
                    .accessibilityLabel("Meeting summary")
            }
            Text("Updates as more conversation is transcribed.")
                .font(MM.Fonts.metadata)
                .foregroundStyle(MM.Colors.textTertiary)
        }
    }
}

/// Read-only generated notes. Updates must not overwrite the user's Notes
/// editor or discard a text selection while they copy from the summary.
private struct RecordingSummaryText: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var markdown: String? }

    func makeNSView(context: Context) -> NSScrollView {
        let text = NSTextView()
        text.textContainer?.replaceLayoutManager(ChecklistLayoutManager())
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.markdown != markdown,
              let text = scroll.documentView as? NSTextView else { return }
        let selection = text.selectedRange()
        text.textStorage?.setAttributedString(MarkdownRich.attributed(from: markdown, firstLineIsTitle: false))
        let length = text.string.utf16.count
        let location = min(selection.location, length)
        text.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        context.coordinator.markdown = markdown
    }
}
