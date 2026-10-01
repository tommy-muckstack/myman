import AVFoundation
import Foundation

/// Own the block registration without owning the hardware graph. Both the
/// registration and its captures must go away when AudioCapture retires it.
final class AudioEngineConfigurationObservation {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(engine: AVAudioEngine, center: NotificationCenter = .default,
         onChange: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                   object: engine, queue: nil) { _ in onChange() }
    }

    deinit { center.removeObserver(token) }
}
