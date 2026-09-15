import Foundation
import Combine

/// Which meetings are still being transcribed after Stop. Documents read
/// this so an empty transcript says "still working", never "nothing said".
@MainActor
final class MeetingTranscriptionStatus: ObservableObject {
    static let shared = MeetingTranscriptionStatus()
    @Published private(set) var pending: [String: String] = [:]

    func begin(meetingID: String, title: String) { pending[meetingID] = title }
    func finish(meetingID: String) { pending.removeValue(forKey: meetingID) }
    func isPending(_ meetingID: String) -> Bool { pending[meetingID] != nil }
}
