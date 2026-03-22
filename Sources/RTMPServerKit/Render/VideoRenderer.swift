import Foundation
import Metal
import MetalKit
import CoreImage
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit

/// Renders decoded video frames using Metal + CoreImage.
///
/// This renderer replaces `AVSampleBufferDisplayLayer` with a transparent, frame-by-frame
/// pipeline that exposes all timing, ordering and pacing problems rather than hiding them.
///
/// **Threading model**
/// - `enqueue(_:)` must be called on the **main thread** (as delivered by `RTMPServer`).
/// - Frame ordering, logging and out-of-order detection run on a dedicated serial
///   `renderQueue`.
/// - Metal draw calls are triggered synchronously on the **main thread**.
///
/// **Debug features**
/// - Every rendered frame is logged to the console:
///   `[Frame] pts=1.033, delta=0.033, system=12345.67`
/// - Out-of-order frames produce a warning:
///   `[WARNING] Frame out of order! currentPTS=…, lastPTS=…`
/// - An on-screen `debugOverlayLabel` shows the same info visually.
final class VideoRenderer: NSObject, MTKViewDelegate {

    // MARK: - Public interface

    /// Metal-backed view that displays the video.  Add this as a subview of your container.
    let metalView: MTKView

    /// Stats callback, delivered on the main thread approximately once per second.
    var onStats: ((RTMPRenderStats) -> Void)?

    /// When `true`, incoming frames are held in a small buffer and sorted by PTS before
    /// rendering.  This can hide out-of-order artifacts but is useful for comparison.
    /// When `false` (default), every frame is rendered immediately in arrival order,
    /// exposing any ordering or pacing problems.
    var useReordering: Bool = false

    /// Number of frames held in the PTS-sort buffer when `useReordering` is `true`.
    var reorderBufferSize: Int = 4

    /// Overlay label placed in the top-left corner of `metalView`.
    /// Displays per-frame debug info: frame index, PTS, delta and out-of-order count.
    let debugOverlayLabel: UILabel = {
        let l = UILabel()
        l.textColor = .yellow
        l.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        l.numberOfLines = 3
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

    private var requiresSyncFrame = true
    private var incomingCount = 0
    private var renderedCount = 0
    private var droppedCount = 0
    private var incomingBytes = 0
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    private var statsWindowStart: CFTimeInterval = CACurrentMediaTime()
    private var pendingCountForStats = 0

    // MARK: - Private state — renderQueue only

    private let renderQueue = DispatchQueue(label: "rtmp.renderer.serial", qos: .userInteractive)
    private var pendingFrames: [PendingFrame] = []
    private var lastRenderedPTS: CMTime = .invalid
    private var frameIndex = 0
    private var outOfOrderCount = 0

    // MARK: - Private state — protected by frameLock

    private let frameLock = NSLock()
    /// Epoch incremented on `startNewStream()` so stale renderQueue dispatches are ignored.
    private var renderEpoch: UInt64 = 0
    private var latestFrame: PendingFrame?
    private var latestOverlayText = ""

    // MARK: - Private Metal state — main thread only

    private let device: MTLDevice
    private let ciContext: CIContext
    private var commandQueue: MTLCommandQueue?

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
    }

    // MARK: - Public API

    /// Enqueue a decoded sample buffer for rendering.  Must be called on the **main thread**.
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

        // Track incoming metrics (main thread).
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
        let frame = PendingFrame(pixelBuffer: pixelBuffer, pts: pts)

        // Hand off to the serial render queue for ordering / logging.
        renderQueue.async { [weak self] in
            self?.processFrame(frame)
        }
        emitStatsIfNeeded()
    }

    /// Reset renderer state — call when a new publish session begins.
    /// Must be called on the **main thread**.
    func startNewStream() {
        // Bump epoch under lock so any in-flight renderQueue dispatches are silently dropped.
        frameLock.lock()
        renderEpoch &+= 1
        latestFrame = nil
        latestOverlayText = ""
        frameLock.unlock()

        // Clear renderQueue-only state asynchronously.
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.pendingFrames.removeAll()
            self.lastRenderedPTS = .invalid
            self.frameIndex = 0
            self.outOfOrderCount = 0
        }

        // Reset main-thread state.
        requiresSyncFrame = true
        pendingCountForStats = 0
        debugOverlayLabel.text = nil
    }

    // MARK: - Private — frame pipeline (renderQueue)

    private func processFrame(_ frame: PendingFrame) {
        if useReordering {
            // Insert in PTS order; emit the earliest once the buffer is full enough.
            let insertIdx = pendingFrames.firstIndex(where: {
                CMTimeCompare($0.pts, frame.pts) > 0
            }) ?? pendingFrames.endIndex
            pendingFrames.insert(frame, at: insertIdx)
            while pendingFrames.count > reorderBufferSize {
                scheduleRender(pendingFrames.removeFirst(), queueDepth: pendingFrames.count)
            }
        } else {
            scheduleRender(frame, queueDepth: 0)
        }
    }

    private func scheduleRender(_ frame: PendingFrame, queueDepth: Int) {
        let pts = frame.pts
        let systemNow = CACurrentMediaTime()
        frameIndex += 1
        let idx = frameIndex

        let ptsSec = pts.isValid ? CMTimeGetSeconds(pts) : -1.0
        var deltaSec: Double = 0
        if lastRenderedPTS.isValid && pts.isValid {
            deltaSec = CMTimeGetSeconds(pts - lastRenderedPTS)
        }

        // Frame timing log (requirement 3) — debug builds only.
        RTMPLogger.debug(String(format: "[Frame] pts=%.3f, delta=%.3f, system=%.2f", ptsSec, deltaSec, systemNow))

        // Out-of-order detection (requirement 4).
        if lastRenderedPTS.isValid && pts.isValid && CMTimeCompare(pts, lastRenderedPTS) < 0 {
            outOfOrderCount += 1
            RTMPLogger.error(String(
                format: "[WARNING] Frame out of order! currentPTS=%.3f, lastPTS=%.3f",
                ptsSec,
                CMTimeGetSeconds(lastRenderedPTS)
            ))
        }

        lastRenderedPTS = pts

        let overlayText = String(
            format: " #%d  PTS: %.3f\n Δ: %.3f s\n OOO: %d ",
            idx, ptsSec, deltaSec, outOfOrderCount
        )

        // Publish frame and epoch atomically so the main-thread draw call is consistent.
        frameLock.lock()
        let epoch = renderEpoch
        latestFrame = frame
        latestOverlayText = overlayText
        frameLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.commitDraw(queueDepth: queueDepth, epoch: epoch)
        }
    }

    // MARK: - Private — rendering (main thread)

    private func commitDraw(queueDepth: Int, epoch: UInt64) {
        // Discard frames that belong to a previous stream session.
        frameLock.lock()
        let currentEpoch = renderEpoch
        frameLock.unlock()
        guard epoch == currentEpoch else { return }

        pendingCountForStats = queueDepth

        // Trigger a synchronous Metal draw call.
        metalView.draw()

        // Update the debug overlay label after the draw.
        frameLock.lock()
        let text = latestOverlayText
        frameLock.unlock()
        debugOverlayLabel.text = text

        renderedCount += 1
        emitStatsIfNeeded()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        frameLock.lock()
        let frame = latestFrame
        frameLock.unlock()

        guard let frame,
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
        ) { _ in drawable.texture }

        do {
            try ciContext.startTask(toRender: ciImage, to: dest)
        } catch {
            RTMPLogger.error("CIContext render failed: \(error)")
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Private — helpers

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
            playoutDelayMs: 0
        )
        onStats?(stats)

        statsWindowStart = now
        incomingCount = 0
        renderedCount = 0
        droppedCount = 0
        incomingBytes = 0
    }
}
