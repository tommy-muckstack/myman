import AVFoundation
import XCTest
@testable import MyMan

final class AudioEngineObservationTests: XCTestCase {
    func testRetiredObservationStopsReceivingHardwareChanges() {
        let center = NotificationCenter()
        let engine = AVAudioEngine()
        let received = expectation(description: "current graph notified once")
        received.assertForOverFulfill = true
        var observation: AudioEngineConfigurationObservation? = AudioEngineConfigurationObservation(
            engine: engine, center: center) { received.fulfill() }
        XCTAssertNotNil(observation)
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        observation = nil
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        wait(for: [received], timeout: 1)
    }

    func testObservationDoesNotKeepRetiredEngineAlive() {
        let center = NotificationCenter()
        var observation: AudioEngineConfigurationObservation?
        weak var retiredEngine: AVAudioEngine?
        autoreleasepool {
            let engine = AVAudioEngine()
            retiredEngine = engine
            observation = AudioEngineConfigurationObservation(engine: engine, center: center) {}
        }
        XCTAssertNil(retiredEngine)
        withExtendedLifetime(observation) {}
    }

    func testRepeatedRebuildsReleaseObserverClosures() {
        final class Lifetime {}
        let center = NotificationCenter()
        let engine = AVAudioEngine()
        for _ in 0..<100 {
            weak var retiredCapture: Lifetime?
            autoreleasepool {
                let capture = Lifetime()
                retiredCapture = capture
                let observation = AudioEngineConfigurationObservation(engine: engine, center: center) {
                    withExtendedLifetime(capture) {}
                }
                withExtendedLifetime(observation) {}
            }
            XCTAssertNil(retiredCapture)
        }
    }
}
