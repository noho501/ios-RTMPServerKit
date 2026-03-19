import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

/// Renders H264 video frames using AVSampleBufferDisplayLayer.
/// Must be used only from the main thread.
final class VideoRenderer {
    let displayLayer: AVSampleBufferDisplayLayer
    var onStats: ((RTMPRenderStats) -> Void)?

    private let playoutDelay: TimeInterval
    private let maxPendingCount: Int
    private var baseSourcePTS: CMTime?
    private var baseHostTime: CFTimeInterval?
    private var requiresSyncFrame: Bool = true
    private var renderEpoch: UInt64 = 0
    private var pendingCount: Int = 0
    private var incomingCount: Int = 0
    private var renderedCount: Int = 0
    private var droppedCount: Int = 0
    private var incomingBytes: Int = 0
    private var statsWindowStart: CFTimeInterval = CACurrentMediaTime()
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0

    init(playoutDelay: TimeInterval = 0.6, maxPendingCount: Int = 40) {
        self.playoutDelay = max(0, playoutDelay)
        self.maxPendingCount = max(1, maxPendingCount)
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.controlTimebase = makeControlTimebase()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        trackIncoming(sampleBuffer)

        let syncFrame = isSyncFrame(sampleBuffer)
        if requiresSyncFrame {
            guard syncFrame else {
                droppedCount += 1
                emitStatsIfNeeded()
                return
            }
            requiresSyncFrame = false
            resetPlayoutClock()
        }

        if displayLayer.status == .failed {
            startNewStream()
        }

        if pendingCount >= maxPendingCount {
            droppedCount += 1
            emitStatsIfNeeded()
            return
        }

        let delay = max(0, targetHostTime(for: sampleBuffer) - CACurrentMediaTime())
        let epoch = renderEpoch
        pendingCount += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.render(sampleBuffer, epoch: epoch)
        }
    }

    func flush() {
        startNewStream()
    }

    func startNewStream() {
        renderEpoch &+= 1
        displayLayer.flush()
        displayLayer.controlTimebase = makeControlTimebase()
        pendingCount = 0
        requiresSyncFrame = true
        resetPlayoutClock()
    }

    // MARK: - Private

    private func render(_ sampleBuffer: CMSampleBuffer, epoch: UInt64) {
        guard epoch == renderEpoch else { return }
        pendingCount = max(0, pendingCount - 1)

        if displayLayer.status == .failed {
            startNewStream()
            droppedCount += 1
            emitStatsIfNeeded()
            return
        }

        if !displayLayer.isReadyForMoreMediaData {
            droppedCount += 1
            emitStatsIfNeeded()
            return
        }

        displayLayer.enqueue(sampleBuffer)
        renderedCount += 1
        emitStatsIfNeeded()
    }

    private func isSyncFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) else {
            return true
        }
        guard CFArrayGetCount(attachmentsArray) > 0,
              let rawDict = CFArrayGetValueAtIndex(attachmentsArray, 0) else {
            return true
        }
        let dict = unsafeBitCast(rawDict, to: CFDictionary.self)
        let notSync = CFDictionaryGetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        )
        guard let notSync else { return true }
        return CFBooleanGetValue(unsafeBitCast(notSync, to: CFBoolean.self)) == false
    }

    private func trackIncoming(_ sampleBuffer: CMSampleBuffer) {
        incomingCount += 1
        incomingBytes += CMSampleBufferGetTotalSampleSize(sampleBuffer)
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            currentWidth = dims.width
            currentHeight = dims.height
        }
        emitStatsIfNeeded()
    }

    private func targetHostTime(for sampleBuffer: CMSampleBuffer) -> CFTimeInterval {
        let now = CACurrentMediaTime()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if baseHostTime == nil {
            baseHostTime = now + playoutDelay
            baseSourcePTS = pts.isValid ? pts : nil
        }

        guard let hostBase = baseHostTime else {
            return now + playoutDelay
        }

        guard pts.isValid, let sourceBase = baseSourcePTS else {
            return now + playoutDelay
        }

        let delta = CMTimeGetSeconds(pts - sourceBase)
        if !delta.isFinite {
            return now + playoutDelay
        }
        return max(now, hostBase + delta)
    }

    private func resetPlayoutClock() {
        baseHostTime = nil
        baseSourcePTS = nil
    }

    private func emitStatsIfNeeded() {
        let now = CACurrentMediaTime()
        let elapsed = now - statsWindowStart
        guard elapsed >= 1 else { return }

        let stats = RTMPRenderStats(
            incomingFPS: Double(incomingCount) / elapsed,
            renderedFPS: Double(renderedCount) / elapsed,
            droppedFPS: Double(droppedCount) / elapsed,
            bitrateKbps: (Double(incomingBytes) * 8 / elapsed) / 1000.0,
            queueDepth: pendingCount,
            width: currentWidth,
            height: currentHeight,
            playoutDelayMs: Int((playoutDelay * 1000).rounded())
        )
        onStats?(stats)

        statsWindowStart = now
        incomingCount = 0
        renderedCount = 0
        droppedCount = 0
        incomingBytes = 0
    }

    private func makeControlTimebase() -> CMTimebase? {
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if let tb = timebase {
            CMTimebaseSetTime(tb, time: CMTime.zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }
        return timebase
    }
}
