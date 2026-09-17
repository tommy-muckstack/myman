import Foundation
import Combine

/// Which meetings are still being transcribed after Stop. Documents read
/// this so an empty transcript says "still working", never "nothing said".
@MainActor
final class MeetingTranscriptionStatus: ObservableObject {
    static let shared = MeetingTranscriptionStatus()
    @Published private(set) var pending: [String: String] = [:]
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var stages: [String: String] = [:]
    @Published var recordingIDs: Set<String> = []
    var retryHandler: ((String, Bool) -> Void)?

    func begin(meetingID: String, title: String) {
        pending[meetingID] = title
        failures.removeValue(forKey: meetingID)
        stages[meetingID] = "Finishing transcript…"
    }
    func stage(_ text: String, meetingID: String) { stages[meetingID] = text }
    func fail(meetingID: String, message: String) { failures[meetingID] = message }
    func finish(meetingID: String) {
        pending.removeValue(forKey: meetingID)
        stages.removeValue(forKey: meetingID)
    }
    func isPending(_ meetingID: String) -> Bool { pending[meetingID] != nil }
}
