import Foundation
import CoreMedia
import AVFoundation

/// Creates CMSampleBuffers from H264 NALU data.
final class SampleBufferFactory {
    private let spsPPSStore: SPSPPSStore
    private var formatDescription: CMVideoFormatDescription?
    private var lastSPS: Data?
    private var lastPPS: Data?

    init(spsPPSStore: SPSPPSStore) {
        self.spsPPSStore = spsPPSStore
    }

    func reset() {
        formatDescription = nil
        lastSPS = nil
        lastPPS = nil
    }

    /// Build a CMSampleBuffer from raw NALU payloads (AVCC format, no length prefix).
    func makeSampleBuffer(nalus: [Data], isKeyframe: Bool, timestamp: UInt32) -> CMSampleBuffer? {
        guard let sps = spsPPSStore.sps, let pps = spsPPSStore.pps else { return nil }

        // Recreate format description if SPS/PPS changed
        if sps != lastSPS || pps != lastPPS {
            formatDescription = makeFormatDescription(sps: sps, pps: pps)
            lastSPS = sps
            lastPPS = pps
        }
        guard let formatDesc = formatDescription else { return nil }

        // Build block buffer with AVCC length-prefixed NALUs
        var totalLength = 0
        for nalu in nalus { totalLength += 4 + nalu.count }
        guard totalLength > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let bb = blockBuffer else { return nil }

        status = CMBlockBufferAssureBlockMemory(bb)
        guard status == noErr else { return nil }

        var writeOffset = 0
        for nalu in nalus {
            let naluLength = nalu.count
            // Write 4-byte big-endian length prefix
            var lengthBE = UInt32(naluLength).bigEndian
            status = CMBlockBufferReplaceDataBytes(
                with: &lengthBE,
                blockBuffer: bb,
                offsetIntoDestination: writeOffset,
                dataLength: 4
            )
            guard status == noErr else { return nil }
            writeOffset += 4

            // Write NALU data
            status = nalu.withUnsafeBytes { ptr -> OSStatus in
                guard let base = ptr.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferReplaceDataBytes(
                    with: base,
                    blockBuffer: bb,
                    offsetIntoDestination: writeOffset,
                    dataLength: naluLength
                )
            }
            guard status == noErr else { return nil }
            writeOffset += naluLength
        }

        // Create sample timing
        let timestampSeconds = Double(timestamp) / 1000.0
        let pts = CMTimeMakeWithSeconds(timestampSeconds, preferredTimescale: 90000)
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: CMTime.invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = totalLength
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sb = sampleBuffer else { return nil }

        if isKeyframe {
            markAsSync(sampleBuffer: sb)
        }
        markDisplayImmediately(sampleBuffer: sb)

        return sb
    }

    private func markAsSync(sampleBuffer: CMSampleBuffer) {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ) else { return }
        let count = CFArrayGetCount(attachmentsArray)
        guard count > 0,
              let rawDict = CFArrayGetValueAtIndex(attachmentsArray, 0) else { return }
        // The array contains CFMutableDictionary items created by CoreMedia
        let dict = Unmanaged<CFMutableDictionary>
            .fromOpaque(rawDict)
            .takeUnretainedValue()
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanFalse).toOpaque()
        )
    }

    private func markDisplayImmediately(sampleBuffer: CMSampleBuffer) {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ) else { return }
        let count = CFArrayGetCount(attachmentsArray)
        guard count > 0,
              let rawDict = CFArrayGetValueAtIndex(attachmentsArray, 0) else { return }
        let dict = Unmanaged<CFMutableDictionary>
            .fromOpaque(rawDict)
            .takeUnretainedValue()
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    // MARK: - Private

    private func makeFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var formatDescription: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                guard let spsBase = spsPtr.baseAddress,
                      let ppsBase = ppsPtr.baseAddress else {
                    return Int32(-1)
                }
                var parameterSetPointers: [UnsafePointer<UInt8>] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self)
                ]
                var parameterSetSizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
        guard status == noErr else { return nil }
        return formatDescription
    }
}
