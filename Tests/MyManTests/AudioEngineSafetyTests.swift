import AVFoundation
import AudioEngineSafety
import XCTest

private final class FailingAudioEngine: AVAudioEngine {
    var exceptionOnStart = false

    override func prepare() {
        NSException(name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                    reason: "Failed to initialize active nodes in input chain! err = -10868",
                    userInfo: nil).raise()
    }

    override func start() throws {
        if exceptionOnStart {
            NSException(name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                        reason: "Input format changed", userInfo: nil).raise()
        } else {
            throw NSError(domain: "AudioTest", code: -10868)
        }
    }
}

final class AudioEngineSafetyTests: XCTestCase {
    func testPreparationExceptionBecomesRecoverableError() throws {
        let error = try XCTUnwrap(MMPrepareAudioEngine(FailingAudioEngine())) as NSError
        XCTAssertEqual(error.domain, "com.muckstack.myman.audio-engine")
        XCTAssertTrue(error.localizedDescription.contains("-10868"))
    }

    func testStartupExceptionBecomesRecoverableError() throws {
        let engine = FailingAudioEngine()
        engine.exceptionOnStart = true
        let error = try XCTUnwrap(MMStartAudioEngine(engine)) as NSError
        XCTAssertEqual(error.domain, "com.muckstack.myman.audio-engine")
        XCTAssertEqual(error.localizedDescription, "Input format changed")
    }

    func testStartupPreservesOrdinaryHardwareError() throws {
        let error = try XCTUnwrap(MMStartAudioEngine(FailingAudioEngine())) as NSError
        XCTAssertEqual(error.domain, "AudioTest")
        XCTAssertEqual(error.code, -10868)
    }
}
