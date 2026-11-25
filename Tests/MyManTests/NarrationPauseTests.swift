import AVFoundation
import CoreMedia
import XCTest
@testable import MyMan

final class NarrationPauseTests: XCTestCase {
    private func sample(at seconds: Double) throws -> CMSampleBuffer {
        var format: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 480, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: 480, flags: 0, blockBufferOut: &block)
        var out: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &out)
        return try XCTUnwrap(out)
    }

    /// A buffer moved back by the paused time keeps its length and lands on the shortened timeline.
    func testShiftRemovesPausedTime() throws {
        let original = try sample(at: 2.0)
        let shifted = try XCTUnwrap(NarrationSink.shifted(original, by: CMTime(seconds: 0.5, preferredTimescale: 600)))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(shifted).seconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(CMSampleBufferGetDuration(shifted).seconds, CMSampleBufferGetDuration(original).seconds, accuracy: 0.000_01)
    }

    /// With no paused time the buffer is returned as it was.
    func testNoOffsetLeavesTheBufferAlone() throws {
        let original = try sample(at: 3.0)
        let same = try XCTUnwrap(NarrationSink.shifted(original, by: .zero))
        XCTAssertTrue(same === original)
    }
}
