import Foundation
import CoreMedia
import CoreVideo
import QuartzCore

/// Central frame scheduling component that sits between the video decoder and all consumers.
///
/// All timing and ordering logic lives here — no consumer needs to implement its own
/// buffering, sorting, or clock-pacing.
///
/// **Input:** Raw decoded frames (`CVPixelBuffer` + `CMTime` PTS) from `VideoDecoder`
///
/// **Output:** Stable, PTS-ordered frames via `onFrame(pixelBuffer, pts)` on the **main thread**
///
/// **Responsibilities:**
/// - Buffer frames in a PTS-sorted queue (default 3 frames)
/// - Anchor a wall-clock playback clock to the first buffered frame
/// - Emit each frame only when `CACurrentMediaTime() >= targetTime` for that frame
/// - Drop late or out-of-order frames
///
/// **Playback clock:**
/// ```
/// basePTS  = PTS of the first frame in the buffer
/// baseTime = CACurrentMediaTime() at clock anchor
///
/// targetTime = baseTime + (frame.pts − basePTS)
/// ```
///
/// **Threading model:**
/// - `enqueue` may be called from any thread (dispatches internally to `schedulerQueue`)
/// - `onFrame` is always delivered on the **main thread**
///
/// **Debug logging:**
/// ```
/// [IN]   pts=1.033, buffer=3
/// [OUT]  pts=1.000, delay=0.0012, buffer=2
/// [DROP] late frame pts=0.967, lastPTS=1.000
/// ```
final class FrameScheduler {

    // MARK: - Types

    private struct Frame {
        let pts: CMTime
        let pixelBuffer: CVPixelBuffer
    }

    // MARK: - Configuration

    /// Minimum number of frames buffered before playback begins (absorbs B-frame reordering).
    /// Increase for streams with more consecutive B-frames. Default: **3**.
    var bufferCapacity: Int = 3

    /// Hard cap on buffered frames to bound memory usage. Default: **30**.
    var maxBufferFrames: Int = 30

    // MARK: - Output

    /// Called on the **main thread** with stable, PTS-ordered frames.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    // MARK: - Private state (protected by schedulerQueue)

    private let schedulerQueue = DispatchQueue(label: "rtmp.scheduler", qos: .userInteractive)
    /// PTS-sorted buffer of decoded frames awaiting scheduled emission.
    private var buffer: [Frame] = []
    /// PTS of the anchor frame (lowest PTS in the buffer at clock-start time).
    private var basePTS: CMTime = .invalid
    /// Wall-clock time when the playback clock was anchored.
    private var baseTime: CFTimeInterval = 0
    private var isAnchored = false
    /// PTS of the most recently emitted frame; used to drop retrograde frames.
    private var lastOutputPTS: CMTime = .invalid

    // MARK: - Private state (main thread only)

    private var displayLink: CADisplayLink?

    // MARK: - Init / Deinit

    init() {
        DispatchQueue.main.async { [weak self] in
            self?.startDisplayLink()
        }
    }

    deinit {
        stopDisplayLink()
    }

    // MARK: - Public API

    /// Enqueue a decoded frame. Thread-safe; may be called from any queue.
    func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        schedulerQueue.async { [weak self] in
            self?.insertFrame(Frame(pts: pts, pixelBuffer: pixelBuffer))
        }
    }

    /// Reset all scheduler state. Call when a new stream begins or on disconnect.
    func reset() {
        schedulerQueue.sync {
            buffer.removeAll()
            basePTS = .invalid
            baseTime = 0
            isAnchored = false
            lastOutputPTS = .invalid
        }
    }

    // MARK: - Private — buffer management (schedulerQueue)

    private func insertFrame(_ frame: Frame) {
        // Drop input that is already behind the last emitted PTS
        if lastOutputPTS.isValid && frame.pts.isValid && CMTimeCompare(frame.pts, lastOutputPTS) <= 0 {
            RTMPLogger.error(String(
                format: "[DROP] late frame pts=%.3f, lastPTS=%.3f",
                CMTimeGetSeconds(frame.pts), CMTimeGetSeconds(lastOutputPTS)
            ))
            return
        }

        // Insertion-sort by PTS (buffer stays sorted; O(n) with small bounded n)
        let idx = buffer.firstIndex(where: { CMTimeCompare($0.pts, frame.pts) > 0 }) ?? buffer.endIndex
        buffer.insert(frame, at: idx)

        // Hard cap: drop the oldest frame if the buffer overflows
        if buffer.count > maxBufferFrames {
            let dropped = buffer.removeFirst()
            RTMPLogger.error(String(
                format: "[DROP] buffer cap exceeded, dropping pts=%.3f",
                CMTimeGetSeconds(dropped.pts)
            ))
        }

        RTMPLogger.debug(String(
            format: "[IN] pts=%.3f, buffer=%d",
            CMTimeGetSeconds(frame.pts), buffer.count
        ))
    }

    private func processBuffer(now: CFTimeInterval) {
        // Wait until we have enough frames to absorb any B-frame reordering
        guard buffer.count >= bufferCapacity else { return }

        // Anchor the playback clock to the earliest (lowest PTS) buffered frame
        if !isAnchored, let first = buffer.first {
            basePTS = first.pts
            baseTime = now
            isAnchored = true
            RTMPLogger.info(String(
                format: "[Scheduler] Clock anchored. basePTS=%.3fs, buffer=%d frames",
                CMTimeGetSeconds(basePTS), buffer.count
            ))
        }

        // Emit frames whose scheduled wall-clock time has arrived
        while let next = buffer.first {
            let targetTime = baseTime + CMTimeGetSeconds(next.pts - basePTS)
            guard now >= targetTime else { break }
            buffer.removeFirst()

            // Drop strictly-equal or retrograde frames relative to last emission
            if lastOutputPTS.isValid && CMTimeCompare(next.pts, lastOutputPTS) <= 0 {
                RTMPLogger.error(String(
                    format: "[DROP] pts=%.3f <= lastPTS=%.3f",
                    CMTimeGetSeconds(next.pts), CMTimeGetSeconds(lastOutputPTS)
                ))
                continue
            }

            lastOutputPTS = next.pts
            let delay = now - targetTime
            RTMPLogger.debug(String(
                format: "[OUT] pts=%.3f, delay=%.4f, buffer=%d",
                CMTimeGetSeconds(next.pts), delay, buffer.count
            ))

            let pixelBuffer = next.pixelBuffer
            let pts = next.pts
            DispatchQueue.main.async { [weak self] in
                self?.onFrame?(pixelBuffer, pts)
            }
        }

        // Re-anchor when the buffer drains completely (handles stream gaps and reconnects)
        if buffer.isEmpty {
            isAnchored = false
        }
    }

    // MARK: - Private — CADisplayLink (main thread)

    private func startDisplayLink() {
        let proxy = SchedulerProxy(self)
        let link = CADisplayLink(target: proxy, selector: #selector(SchedulerProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Invoked on the main thread by `CADisplayLink`; dispatches timing check to `schedulerQueue`.
    fileprivate func displayLinkFired() {
        let now = CACurrentMediaTime()
        schedulerQueue.async { [weak self] in
            self?.processBuffer(now: now)
        }
    }
}

// MARK: - Weak proxy to break CADisplayLink → FrameScheduler retain cycle

private final class SchedulerProxy: NSObject {
    weak var scheduler: FrameScheduler?
    init(_ scheduler: FrameScheduler) { self.scheduler = scheduler }
    @objc func tick() { scheduler?.displayLinkFired() }
}
