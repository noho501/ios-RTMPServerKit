import VideoToolbox
import CoreMedia
import CoreVideo

/// Decodes H264 video frames using `VTDecompressionSession`.
///
/// Input:  AVCC-format NAL unit arrays from `H264Parser`
/// Output: Decoded `CMSampleBuffer` containing a `CVPixelBuffer` via `onFrame`,
///         delivered in presentation order (PTS-sorted reorder buffer).
final class VideoDecoder {
    private let spsPPSStore: SPSPPSStore
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var lastSPS: Data?
    private var lastPPS: Data?
    private let lock = NSLock()

    // MARK: - Reorder buffer
    // Frames are decoded asynchronously and may arrive in decode order (DTS order).
    // We collect them in a small buffer, sort by PTS, and emit the earliest frame
    // once the buffer reaches `reorderBufferCapacity`.  All access is serialised on
    // `reorderQueue` to avoid races with the VTDecompressionSession callback thread.
    private let reorderQueue = DispatchQueue(label: "rtmp.decoder.reorder", qos: .userInteractive)
    private struct DecodedFrame {
        let pts: CMTime
        let buffer: CMSampleBuffer
    }
    private var reorderBuffer: [DecodedFrame] = []
    /// Number of decoded frames held back before the earliest is emitted.
    /// Increase for streams with more consecutive B-frames (default: 4).
    var reorderBufferCapacity: Int = 4
    private var lastRenderedPTS: CMTime = .invalid
    /// Monotonically increasing counter for frames arriving in the reorder buffer,
    /// used only for debug logging.  Accessed exclusively on `reorderQueue`.
    private var decodeOrderIndex: Int = 0

    /// Called on `reorderQueue` with decoded frames in presentation order.
    var onFrame: ((CMSampleBuffer) -> Void)?

    init(spsPPSStore: SPSPPSStore) {
        self.spsPPSStore = spsPPSStore
    }

    deinit {
        tearDownSession()
    }

    // MARK: - Public

    /// Feed NAL units (AVCC format, no length prefix) into the decoder.
    /// - Parameters:
    ///   - dts: Decode timestamp from the RTMP message (milliseconds).
    ///   - pts: Presentation timestamp = DTS + composition-time-offset (milliseconds).
    func decode(nalus: [Data], isKeyframe: Bool, dts: UInt32, pts: UInt32) {
        guard let sps = spsPPSStore.sps, let pps = spsPPSStore.pps else { return }

        lock.lock()
        if sps != lastSPS || pps != lastPPS {
            tearDownSessionLocked()
            guard setUpSessionLocked(sps: sps, pps: pps) else {
                lock.unlock()
                return
            }
        }
        let activeSession = session
        let activeFormatDesc = formatDescription
        lock.unlock()

        guard let activeSession, let activeFormatDesc else { return }
        guard let blockBuffer = makeBlockBuffer(nalus: nalus) else { return }

        let ptsCM  = CMTimeMake(value: Int64(pts), timescale: 1000)
        let dtsCM  = CMTimeMake(value: Int64(dts), timescale: 1000)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: ptsCM,
            decodeTimeStamp: dtsCM
        )
        let totalSize = nalus.reduce(0) { $0 + 4 + $1.count }
        var sampleSize = totalSize

        var compressedBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: activeFormatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &compressedBuffer
        ) == noErr, let sb = compressedBuffer else { return }

        RTMPLogger.debug("Submitting decode DTS=\(dts)ms PTS=\(pts)ms keyframe=\(isKeyframe)")

        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            activeSession,
            sampleBuffer: sb,
            flags: ._EnableAsynchronousDecompression,
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if decodeStatus != noErr {
            RTMPLogger.error("VTDecompressionSessionDecodeFrame failed: \(decodeStatus)")
        }
    }

    /// Invalidate and clear the current decompression session.
    /// Call when SPS/PPS parameters are reset or the stream ends.
    func reset() {
        lock.lock()
        tearDownSessionLocked()
        lock.unlock()
    }

    // MARK: - Private – session lifecycle

    private func tearDownSession() {
        lock.lock()
        tearDownSessionLocked()
        lock.unlock()
    }

    private func tearDownSessionLocked() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        formatDescription = nil
        lastSPS = nil
        lastPPS = nil
        // Drain any frames that were decoded but not yet emitted.
        // VTDecompressionSessionWaitForAsynchronousFrames guarantees all callbacks
        // have fired (and thus all reorderQueue.async blocks have been enqueued)
        // before we reach this sync block, so the flush sees the complete buffer.
        reorderQueue.sync {
            flushReorderBufferLocked()
        }
    }

    private func setUpSessionLocked(sps: Data, pps: Data) -> Bool {
        guard let formatDesc = makeFormatDescription(sps: sps, pps: pps) else { return false }
        formatDescription = formatDesc
        lastSPS = sps
        lastPPS = pps

        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]

        // The callback is a non-capturing closure: `self` is recovered from refCon.
        var outputCallbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, pts, _ in
                guard let refCon else { return }
                let decoder = Unmanaged<VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
                decoder.didDecodeFrame(status: status, imageBuffer: imageBuffer, pts: pts)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: &outputCallbackRecord,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let s = newSession else { return false }
        session = s
        return true
    }

    // MARK: - Private – buffer helpers

    private func makeFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return kCMFormatDescriptionError_InvalidParameter
                }
                var ptrs: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &ptrs,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }
        return status == noErr ? desc : nil
    }

    private func makeBlockBuffer(nalus: [Data]) -> CMBlockBuffer? {
        let totalSize = nalus.reduce(0) { $0 + 4 + $1.count }
        guard totalSize > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let bb = blockBuffer else { return nil }

        status = CMBlockBufferAssureBlockMemory(bb)
        guard status == noErr else { return nil }

        var writeOffset = 0
        for nalu in nalus {
            var lengthBE = UInt32(nalu.count).bigEndian
            status = CMBlockBufferReplaceDataBytes(
                with: &lengthBE,
                blockBuffer: bb,
                offsetIntoDestination: writeOffset,
                dataLength: 4
            )
            guard status == noErr else { return nil }
            writeOffset += 4

            status = nalu.withUnsafeBytes { ptr -> OSStatus in
                guard let base = ptr.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferReplaceDataBytes(
                    with: base,
                    blockBuffer: bb,
                    offsetIntoDestination: writeOffset,
                    dataLength: nalu.count
                )
            }
            guard status == noErr else { return nil }
            writeOffset += nalu.count
        }
        return bb
    }

    // MARK: - Private – decode callback

    /// Called on a VideoToolbox internal thread; must not block or render directly.
    fileprivate func didDecodeFrame(status: OSStatus, imageBuffer: CVImageBuffer?, pts: CMTime) {
        guard status == noErr, let pixelBuffer = imageBuffer else { return }

        var formatDesc: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard formatStatus == noErr, let desc = formatDesc else {
            if formatStatus != noErr {
                RTMPLogger.error("CMVideoFormatDescriptionCreateForImageBuffer failed: \(formatStatus)")
            }
            return
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var decodedBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &decodedBuffer
        ) == noErr, let sb = decodedBuffer else { return }

        // Enqueue on the serial reorder queue — do NOT call onFrame directly here.
        reorderQueue.async { [weak self] in
            guard let self else { return }
            self.decodeOrderIndex += 1
            let idx = self.decodeOrderIndex
            // Insert the frame at the correct sorted position by PTS (insertion sort).
            // The buffer is tiny (≤ reorderBufferCapacity + 1 elements) so this is O(n).
            let insertIndex = self.reorderBuffer.firstIndex(where: { CMTimeCompare($0.pts, pts) > 0 })
                ?? self.reorderBuffer.endIndex
            self.reorderBuffer.insert(DecodedFrame(pts: pts, buffer: sb), at: insertIndex)
            RTMPLogger.debug("Reorder buffer size: \(self.reorderBuffer.count), arrival order=\(idx) PTS=\(pts.value)ms")
            // Emit the earliest frame once the buffer is deep enough to absorb
            // any reordering introduced by B-frames.
            while self.reorderBuffer.count > self.reorderBufferCapacity {
                self.emitEarliestFrameLocked()
            }
        }
    }

    // MARK: - Private – reorder helpers (must be called from reorderQueue)

    /// Emit the frame with the lowest PTS from the reorder buffer.
    private func emitEarliestFrameLocked() {
        guard !reorderBuffer.isEmpty else { return }
        let frame = reorderBuffer.removeFirst()
        if lastRenderedPTS.isValid && CMTimeCompare(frame.pts, lastRenderedPTS) < 0 {
            RTMPLogger.error(
                "Out-of-order frame detected: PTS=\(frame.pts.value)ms < last rendered=\(lastRenderedPTS.value)ms"
            )
        }
        RTMPLogger.debug("Emitting PTS=\(frame.pts.value)ms, buffer remaining=\(reorderBuffer.count)")
        lastRenderedPTS = frame.pts
        onFrame?(frame.buffer)
    }

    /// Emit all buffered frames in PTS order (used on teardown / reset).
    private func flushReorderBufferLocked() {
        // The buffer is maintained in sorted order by the insertion logic in didDecodeFrame,
        // so no additional sort is needed here.
        while !reorderBuffer.isEmpty {
            emitEarliestFrameLocked()
        }
        lastRenderedPTS = .invalid
        decodeOrderIndex = 0
    }
}
