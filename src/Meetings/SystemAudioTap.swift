import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac is playing (other apps' audio) via a CoreAudio
/// process tap + private aggregate device. macOS 14.2+. Emits 16kHz mono
/// Float samples. Requires the NSAudioCaptureUsageDescription TCC grant
/// ("System Audio Recording Only" under Screen & System Audio Recording).
///
/// Hard-won rules baked in (see docs/meeting-port-notes.md):
/// - GLOBAL stereo tap, not a device-stream tap (those can be zero-filled).
/// - The aggregate's tap list takes UID-string dictionaries, never
///   CATapDescription objects (objects crash CoreAudio).
/// - Excluding ourselves needs the HAL process AudioObjectID, not the pid.
/// - Destroy order: stop → IOProc → aggregate → tap.
/// - Clean up stale aggregates at launch — crashes leave phantoms behind.
final class SystemAudioTap {
    var onSamples: (([Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sourceFormat = AudioStreamBasicDescription()
    private let ioQueue = DispatchQueue(label: "com.muckstack.myman.tap.io", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "com.muckstack.myman.tap.processing")
    private(set) var isRunning = false

    private static let aggregateName = "My Man System Audio"

    enum TapError: Error {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
    }

    // MARK: Lifecycle

    func start() throws {
        guard !isRunning else { return }

        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: Self.currentProcessAudioObjectID().map { [$0] } ?? [])
        description.name = "My Man System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw TapError.tapCreationFailed(status) }
        tapID = newTapID

        let aggregateUID = "com.muckstack.myman.tap-\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw TapError.aggregateCreationFailed(status)
        }
        aggregateID = newAggregateID

        sourceFormat = Self.tapStreamFormat(for: tapID) ?? {
            var fallback = AudioStreamBasicDescription()
            fallback.mSampleRate = 48000
            fallback.mChannelsPerFrame = 2
            fallback.mFormatID = kAudioFormatLinearPCM
            fallback.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            return fallback
        }()

        let format = sourceFormat
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            guard let self, self.isRunning else { return }
            // Copy out of the realtime callback, process off it.
            let copied = Self.copyBuffers(inputData)
            self.processingQueue.async {
                let mono = Self.mixToMono(copied, format: format)
                guard !mono.isEmpty else { return }
                let resampled = AudioCapture.resample(mono, from: format.mSampleRate, to: 16000)
                self.onSamples?(resampled)
            }
        }
        guard status == noErr else {
            teardown()
            throw TapError.ioProcFailed(status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            teardown()
            throw TapError.ioProcFailed(status)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        processingQueue.sync { [weak self] in self?.onSamples = nil }
        teardown()
    }

    private func teardown() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        if isRunning {
            isRunning = false
            teardown()
        }
    }

    // MARK: Stale-device cleanup (call at launch)

    /// Crashed sessions leave phantom "My Man System Audio" aggregate devices
    /// in the HAL. Destroy any we find.
    static func cleanupStaleDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else { return }

        for deviceID in deviceIDs {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &name) { ptr in
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, ptr)
            }
            if status == noErr, (name as String) == aggregateName {
                AudioHardwareDestroyAggregateDevice(deviceID)
            }
        }
    }

    /// TCC check: try to create (and immediately destroy) a throwaway tap.
    static func hasPermission() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        var probeTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &probeTapID)
        if status == noErr {
            AudioHardwareDestroyProcessTap(probeTapID)
            return true
        }
        return false
    }

    // MARK: Helpers

    /// The HAL process object ID for this process — CATapDescription wants
    /// these, not raw pids.
    private static func currentProcessAudioObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var objectIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs) == noErr else { return nil }

        let myPID = ProcessInfo.processInfo.processIdentifier
        for objectID in objectIDs {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
               pid == myPID {
                return objectID
            }
        }
        return nil
    }

    private static func tapStreamFormat(for tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }

    private static func copyBuffers(_ list: UnsafePointer<AudioBufferList>) -> [[Float]] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var result: [[Float]] = []
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = data.bindMemory(to: Float.self, capacity: count)
            result.append(Array(UnsafeBufferPointer(start: floats, count: count)))
        }
        return result
    }

    /// Average all channels of all buffers into one mono stream (float PCM).
    private static func mixToMono(_ buffers: [[Float]], format: AudioStreamBasicDescription) -> [Float] {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              !buffers.isEmpty else { return [] }
        let channels = max(1, Int(format.mChannelsPerFrame))

        if buffers.count == 1 {
            // Interleaved: de-interleave by averaging each frame's channels.
            let samples = buffers[0]
            guard channels > 1 else { return samples }
            let frames = samples.count / channels
            var mono = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[frame * channels + channel]
                }
                mono[frame] = sum / Float(channels)
            }
            return mono
        }
        // Non-interleaved: one buffer per channel.
        let frames = buffers.map(\.count).min() ?? 0
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for buffer in buffers {
                sum += buffer[frame]
            }
            mono[frame] = sum / Float(buffers.count)
        }
        return mono
    }
}
