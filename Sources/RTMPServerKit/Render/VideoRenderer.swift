import Foundation
import Metal
import MetalKit
import CoreImage
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit

/// Weak-target proxy that breaks the CADisplayLink → VideoRenderer retain cycle.
///
/// `CADisplayLink` retains its target strongly.  By using a proxy that holds only a
/// `weak` reference to the renderer, the renderer can be deallocated normally and
/// `VideoRenderer.deinit` will invalidate the display link via `stopDisplayLink()`.
private final class DisplayLinkProxy: NSObject {
    weak var renderer: VideoRenderer?
    init(_ renderer: VideoRenderer) { self.renderer = renderer }
    @objc func tick() { renderer?.displayLinkTick() }
}

/// Renders decoded video frames using Metal + CoreImage with a stable, clock-paced playback
/// buffer that eliminates stutter caused by B-frame reordering, network jitter, and
/// irregular decode timing.
///
/// **Architecture overview**
/// All incoming frames are inserted into a PTS-sorted buffer (`frameBuffer`).  A
/// `CADisplayLink` ticks on every display refresh and releases frames whose scheduled
/// presentation time has arrived, achieving frame-accurate pacing without busy-waiting.
///
/// **Playback clock**
/// When the buffer accumulates `minBufferDuration` seconds of frames the clock is
/// anchored:
/// ```
///   basePTS  = PTS of the first frame in the buffer
///   baseTime = current wall-clock time  (CACurrentMediaTime)
/// ```
/// Every subsequent frame is released at:
/// ```
///   targetTime = baseTime + (frame.pts − basePTS)
/// ```
/// This maps PTS deltas directly onto real wall-clock time while remaining immune to
/// absolute PTS values (which can be arbitrary large integers from an RTMP stream).
///
/// **Jitter / underrun handling**
/// If the renderable buffer falls below `refillThreshold` seconds the clock is paused
/// and re-anchored once `minBufferDuration` is reached again, avoiding temporal
/// distortion from attempting to "catch up".
///
/// **Threading model**
/// - `enqueue(_:)` and `startNewStream()` must be called on the **main thread**.
/// - All buffer mutation, pacing logic and Metal draw calls run on the **main thread**
///   (driven by CADisplayLink), so no additional locking is required.
///
/// **Debug logging**
/// ```
/// [Render]  pts=1.033, delay=0.0012, bufferSize=28
/// [WARNING] Out-of-order input pts=1.000, lastReceivedPTS=1.033
/// [DROP]    Late frame pts=0.967 (lastRendered=1.033)
/// [Pacing]  Playback started. basePTS=1.000s, buffer=1.23s (37 frames)
/// [Pacing]  Buffer underrun (0.12s / 4 frames). Pausing for refill.
/// ```
final class VideoRenderer: NSObject, MTKViewDelegate {

    // MARK: - Public interface

    /// Metal-backed view that displays the video.  Add this as a subview of your container.
    let metalView: MTKView

    /// Stats callback, delivered on the main thread approximately once per second.
    var onStats: ((RTMPRenderStats) -> Void)?

    /// Minimum seconds of frames to buffer before playback begins (and after an underrun).
    /// Larger values reduce stutter at the cost of added latency.  Default: **1.0 s**.
    var minBufferDuration: Double = 1.0

    /// If the renderable buffer drops below this threshold the clock is paused until
    /// `minBufferDuration` is reached again.  Default: **0.5 s**.
    var refillThreshold: Double = 0.5

    /// Hard cap on buffered frames to bound memory usage.
    /// At 30 fps this is ~3 seconds; at 60 fps ~1.5 seconds.  Default: **90**.
    var maxBufferFrames: Int = 90

    /// Kept for API compatibility.  The renderer always uses PTS-sorted buffering.
    var useReordering: Bool = true

    /// Kept for API compatibility.  Minimum reorder depth is governed by
    /// `minBufferDuration` instead.
    var reorderBufferSize: Int = 4

    /// Overlay label placed in the top-left corner of `metalView`.
    /// Displays per-frame debug info: index, PTS, render delay, buffer depth and OOO count.
    let debugOverlayLabel: UILabel = {
        let l = UILabel()
        l.textColor = .yellow
        l.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        l.numberOfLines = 4
        l.textAlignment = .left
        l.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        l.layer.cornerRadius = 4
        l.clipsToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // MARK: - Private types

    private struct PendingFrame {
        let pixelBuffer: CVPixelBuffer
        let pts: CMTime
    }

    // MARK: - Private state — main thread only

    /// PTS-sorted buffer of decoded frames waiting for their scheduled presentation time.
    private var frameBuffer: [PendingFrame] = []

    // Playback clock
    private var basePTS: CMTime = .invalid
    private var baseTime: CFTimeInterval = 0
    private var isPlaying = false

    /// PTS of the most recently rendered frame (used to detect / drop late frames).
    private var lastRenderedPTS: CMTime = .invalid
    /// PTS of the most recently received input frame (used to detect out-of-order input).
    private var lastReceivedPTS: CMTime = .invalid

    private var requiresSyncFrame = true
    private var frameIndex = 0
    private var outOfOrderInputCount = 0

    // Stats — main thread only
    private var incomingCount = 0
    private var renderedCount = 0
    private var droppedCount = 0
    private var incomingBytes = 0
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    private var statsWindowStart: CFTimeInterval = CACurrentMediaTime()
    private var pendingCountForStats = 0

    // MARK: - CADisplayLink — main thread only

    private var displayLink: CADisplayLink?

    // MARK: - Private Metal state — main thread only

    private let device: MTLDevice
    private let ciContext: CIContext
    private var commandQueue: MTLCommandQueue?
    /// Frame staged for the next `draw(in:)` call.
    private var frameForDraw: PendingFrame?

    // MARK: - Init

    override init() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal rendering is required but not supported on this device. Please run on a device with Metal support (all iOS devices since A7).")
        }
        device = dev
        let mtkView = MTKView(frame: .zero, device: dev)
        // framebufferOnly must be false so that CIContext can render into the drawable
        // texture via CIRenderDestination (which writes to an arbitrary MTLTexture).
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.backgroundColor = .black
        metalView = mtkView
        ciContext = CIContext(mtlDevice: dev)
        commandQueue = dev.makeCommandQueue()
        super.init()
        mtkView.delegate = self

        // Overlay label anchored to the top-left corner of the Metal view.
        mtkView.addSubview(debugOverlayLabel)
        NSLayoutConstraint.activate([
            debugOverlayLabel.leadingAnchor.constraint(equalTo: mtkView.leadingAnchor, constant: 8),
            debugOverlayLabel.topAnchor.constraint(equalTo: mtkView.topAnchor, constant: 8)
        ])

        startDisplayLink()
    }

    deinit {
        stopDisplayLink()
    }

    // MARK: - Public API

    /// Enqueue a decoded sample buffer into the playback buffer.
    /// Must be called on the **main thread** (as guaranteed by `RTMPServer`).
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // Wait for the first sync (key) frame so rendering starts cleanly.
        let syncFrame = isSyncFrame(sampleBuffer)
        if requiresSyncFrame {
            guard syncFrame else {
                droppedCount += 1
                emitStatsIfNeeded()
                return
            }
            requiresSyncFrame = false
        }

        // Track incoming metrics.
        incomingCount += 1
        incomingBytes += CMSampleBufferGetTotalSampleSize(sampleBuffer)
        if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let d = CMVideoFormatDescriptionGetDimensions(fmt)
            currentWidth = d.width
            currentHeight = d.height
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            droppedCount += 1
            emitStatsIfNeeded()
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Detect out-of-order input (frames arriving at the renderer in the wrong order).
        if lastReceivedPTS.isValid && pts.isValid && CMTimeCompare(pts, lastReceivedPTS) < 0 {
            outOfOrderInputCount += 1
            RTMPLogger.error(String(
                format: "[WARNING] Out-of-order input pts=%.3f, lastReceivedPTS=%.3f",
                CMTimeGetSeconds(pts), CMTimeGetSeconds(lastReceivedPTS)
            ))
        }
        if pts.isValid { lastReceivedPTS = pts }

        // Hard cap: drop the oldest buffered frame when the buffer is full.
        if frameBuffer.count >= maxBufferFrames {
            let dropped = frameBuffer.removeFirst()
            droppedCount += 1
            RTMPLogger.error(String(
                format: "[DROP] Buffer full (%d frames), dropping oldest frame pts=%.3f",
                maxBufferFrames, CMTimeGetSeconds(dropped.pts)
            ))
        }

        // Insert the frame at the correct PTS-sorted position (insertion sort).
        // The buffer is bounded by maxBufferFrames so this is O(n) with small n.
        let frame = PendingFrame(pixelBuffer: pixelBuffer, pts: pts)
        let insertIdx = frameBuffer.firstIndex(where: { CMTimeCompare($0.pts, pts) > 0 }) ?? frameBuffer.endIndex
        frameBuffer.insert(frame, at: insertIdx)

        emitStatsIfNeeded()
    }

    /// Reset renderer state — call when a new publish session begins.
    /// Must be called on the **main thread**.
    func startNewStream() {
        frameBuffer.removeAll()
        basePTS = .invalid
        baseTime = 0
        isPlaying = false
        lastRenderedPTS = .invalid
        lastReceivedPTS = .invalid
        requiresSyncFrame = true
        frameIndex = 0
        outOfOrderInputCount = 0
        pendingCountForStats = 0
        frameForDraw = nil
        debugOverlayLabel.text = nil
    }

    // MARK: - Private — CADisplayLink

    private func startDisplayLink() {
        let proxy = DisplayLinkProxy(self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Called on every display refresh (main thread).  Checks which buffered frames are
    /// due for presentation and renders them in PTS order.
    fileprivate func displayLinkTick() {
        let now = CACurrentMediaTime()
        let bufferDuration = computeBufferDuration()

        if !isPlaying {
            // Wait until the buffer holds at least `minBufferDuration` of content.
            guard bufferDuration >= minBufferDuration, let firstFrame = frameBuffer.first else { return }

            // Anchor the playback clock to the first frame in the buffer.
            basePTS = firstFrame.pts
            baseTime = now
            isPlaying = true
            RTMPLogger.info(String(
                format: "[Pacing] Playback started. basePTS=%.3fs, buffer=%.2fs (%d frames)",
                CMTimeGetSeconds(basePTS), bufferDuration, frameBuffer.count
            ))
        } else if bufferDuration < refillThreshold {
            // Buffer underrun — pause and re-anchor when refilled.
            isPlaying = false
            RTMPLogger.error(String(
                format: "[Pacing] Buffer underrun (%.2fs / %d frames). Pausing for refill.",
                bufferDuration, frameBuffer.count
            ))
            return
        }

        // Release all frames whose scheduled presentation time has arrived.
        while let next = frameBuffer.first {
            let targetTime = baseTime + CMTimeGetSeconds(next.pts - basePTS)
            guard now >= targetTime else { break }
            frameBuffer.removeFirst()

            // Drop frames that are strictly late relative to what has already been rendered.
            if lastRenderedPTS.isValid && next.pts.isValid
                && CMTimeCompare(next.pts, lastRenderedPTS) <= 0 {
                droppedCount += 1
                RTMPLogger.error(String(
                    format: "[DROP] Late frame pts=%.3fs (lastRendered=%.3fs)",
                    CMTimeGetSeconds(next.pts), CMTimeGetSeconds(lastRenderedPTS)
                ))
                continue
            }

            // Commit this frame for rendering.
            lastRenderedPTS = next.pts
            frameIndex += 1
            let idx = frameIndex
            let delay = now - targetTime
            let bufSize = frameBuffer.count
            let ptsSec = CMTimeGetSeconds(next.pts)
            let currentBufDuration = computeBufferDuration()

            RTMPLogger.debug(String(
                format: "[Render] pts=%.3f, delay=%.4f, bufferSize=%d",
                ptsSec, delay, bufSize
            ))

            let overlayText = String(
                format: " #%d  PTS: %.3f\n delay: %.1f ms\n buf: %d fr / %.2f s\n OOO: %d ",
                idx, ptsSec, delay * 1000, bufSize, currentBufDuration, outOfOrderInputCount
            )
            frameForDraw = next
            metalView.draw()
            debugOverlayLabel.text = overlayText
            renderedCount += 1
        }

        pendingCountForStats = frameBuffer.count
        emitStatsIfNeeded()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let frame = frameForDraw,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

        var ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)

        // Scale the image to aspect-fit in the drawable, composited over a black background.
        let drawSize = view.drawableSize
        let imgExtent = ciImage.extent
        guard imgExtent.width > 0, imgExtent.height > 0,
              drawSize.width > 0, drawSize.height > 0 else { return }

        let scale = min(drawSize.width / imgExtent.width, drawSize.height / imgExtent.height)
        let tx = (drawSize.width  - imgExtent.width  * scale) / 2.0
        let ty = (drawSize.height - imgExtent.height * scale) / 2.0

        ciImage = ciImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))

        // Black letterbox background.
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(origin: .zero, size: drawSize))
        ciImage = ciImage.composited(over: background)

        let dest = CIRenderDestination(
            width: Int(drawSize.width),
            height: Int(drawSize.height),
            pixelFormat: view.colorPixelFormat,
            commandBuffer: commandBuffer
        ) { drawable.texture }

        do {
            try ciContext.startTask(toRender: ciImage, to: dest)
        } catch {
            RTMPLogger.error("CIContext render failed: \(error)")
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Private — helpers

    /// Returns the PTS span (in seconds) of the frames currently in the buffer.
    private func computeBufferDuration() -> Double {
        guard frameBuffer.count >= 2,
              let first = frameBuffer.first, first.pts.isValid,
              let last  = frameBuffer.last,  last.pts.isValid else { return 0 }
        return max(0, CMTimeGetSeconds(last.pts - first.pts))
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

    private func emitStatsIfNeeded() {
        let now = CACurrentMediaTime()
        let elapsed = now - statsWindowStart
        guard elapsed >= 1 else { return }

        let stats = RTMPRenderStats(
            incomingFPS: Double(incomingCount) / elapsed,
            renderedFPS: Double(renderedCount) / elapsed,
            droppedFPS: Double(droppedCount) / elapsed,
            bitrateKbps: Double(incomingBytes) * 8.0 / elapsed / 1000.0,
            queueDepth: pendingCountForStats,
            width: currentWidth,
            height: currentHeight,
            playoutDelayMs: Int(minBufferDuration * 1000)
        )
        onStats?(stats)

        statsWindowStart = now
        incomingCount = 0
        renderedCount = 0
        droppedCount = 0
        incomingBytes = 0
    }
}
