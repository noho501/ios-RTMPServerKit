import Foundation
import Metal
import MetalKit
import CoreImage
import CoreMedia
import QuartzCore
import UIKit

/// Weak-target proxy that breaks the CADisplayLink → VideoRenderer retain cycle.
private final class DisplayLinkProxy: NSObject {
    weak var renderer: VideoRenderer?
    init(_ renderer: VideoRenderer) { self.renderer = renderer }
    @objc func tick() { renderer?.displayLinkTick() }
}

/// CIImage-based video renderer backed by Metal.
///
/// Receives `CIImage` frames from `FrameScheduler` (which handles all buffering, sorting,
/// and clock-pacing), stores the latest frame, and renders it on every `CADisplayLink` tick.
///
/// **Architecture**
/// - All timing/ordering and CVPixelBuffer → CIImage conversion happens upstream in `FrameScheduler`.
/// - This renderer only needs to: store the latest `CIImage` and blit it into the Metal
///   drawable via a shared `CIContext`.
///
/// **Threading model**
/// - `enqueue(ciImage:pts:)` and `startNewStream()` must be called on the **main thread**
///   (guaranteed by `FrameScheduler`).
/// - All Metal / CIImage draw calls run on the **main thread** (driven by `CADisplayLink`).
///
/// **Debug logging**
/// ```
/// [Render] pts=1.033, #42, 1920x1080
/// ```
final class VideoRenderer: NSObject, MTKViewDelegate {

    // MARK: - Public interface

    /// Metal-backed view that displays the video.  Add this as a subview of your container.
    let metalView: MTKView

    /// Stats callback, delivered on the main thread approximately once per second.
    var onStats: ((RTMPRenderStats) -> Void)?

    /// Kept for API compatibility; has no effect in the new pipeline
    /// (buffering is controlled by `FrameScheduler.bufferCapacity`).
    var minBufferDuration: Double = 1.0

    /// Kept for API compatibility.
    var useReordering: Bool = true

    /// Kept for API compatibility.
    var reorderBufferSize: Int = 4

    /// Overlay label placed in the top-left corner of `metalView`.
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

    // MARK: - Private state — main thread only

    /// Incoming frame not yet rendered; replaced on each new enqueue.
    private var pendingFrame: (ciImage: CIImage, pts: CMTime)?
    /// PTS of the most recently rendered frame (prevents re-rendering the same frame).
    private var lastRenderedPTS: CMTime = .invalid
    private var frameIndex = 0

    // Stats — main thread only
    private var incomingCount = 0
    private var renderedCount = 0
    private var droppedCount = 0
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    private var statsWindowStart: CFTimeInterval = CACurrentMediaTime()

    // MARK: - CADisplayLink — main thread only

    private var displayLink: CADisplayLink?

    // MARK: - Metal state — main thread only

    private let device: MTLDevice
    /// Shared CIContext backed by the Metal device.  Created once; never recreated per-frame.
    private let ciContext: CIContext
    private var commandQueue: MTLCommandQueue?
    /// CIImage staged for the current `draw(in:)` call.
    private var frameForDraw: CIImage?

    // MARK: - Init

    override init() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal rendering is required but not supported on this device. Please run on a device with Metal support (all iOS devices since A7).")
        }
        device = dev
        let mtkView = MTKView(frame: .zero, device: dev)
        // framebufferOnly must be false so CIContext can render into the drawable texture.
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.backgroundColor = .black
        metalView = mtkView
        // Single shared CIContext with Metal backing — never recreated per frame.
        ciContext = CIContext(mtlDevice: dev)
        commandQueue = dev.makeCommandQueue()
        super.init()
        mtkView.delegate = self

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

    /// Store an incoming frame for rendering on the next CADisplayLink tick.
    /// Must be called on the **main thread** (guaranteed by `FrameScheduler`).
    func enqueue(ciImage: CIImage, pts: CMTime) {
        incomingCount += 1
        currentWidth  = Int32(ciImage.extent.width)
        currentHeight = Int32(ciImage.extent.height)

        // Guard against out-of-order delivery (FrameScheduler should prevent this;
        // log a warning if it ever occurs to help diagnose scheduler bugs).
        if lastRenderedPTS.isValid && pts.isValid && CMTimeCompare(pts, lastRenderedPTS) <= 0 {
            RTMPLogger.error(String(
                format: "[Render][WARNING] Out-of-order frame suppressed: pts=%.3f <= lastRendered=%.3f",
                CMTimeGetSeconds(pts), CMTimeGetSeconds(lastRenderedPTS)
            ))
            droppedCount += 1
            emitStatsIfNeeded()
            return
        }

        // If a not-yet-rendered frame is being superseded, count it as dropped.
        if pendingFrame != nil {
            droppedCount += 1
        }

        pendingFrame = (ciImage, pts)

        emitStatsIfNeeded()
    }

    /// Reset renderer state — call when a new publish session begins.
    /// Must be called on the **main thread**.
    func startNewStream() {
        pendingFrame = nil
        lastRenderedPTS = .invalid
        frameIndex = 0
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

    /// Called on every display refresh (main thread).
    /// Renders the latest available frame if it differs from the last rendered frame.
    fileprivate func displayLinkTick() {
        guard let frame = pendingFrame else { return }

        // Skip if the pending frame has the same PTS as what we already rendered.
        if lastRenderedPTS.isValid && frame.pts.isValid
            && CMTimeCompare(frame.pts, lastRenderedPTS) == 0 { return }

        lastRenderedPTS = frame.pts
        pendingFrame = nil  // Consume; last-rendered state is held in lastRenderedPTS / frameForDraw
        frameIndex += 1

        let ptsSec = CMTimeGetSeconds(frame.pts)
        RTMPLogger.debug(String(
            format: "[Render] pts=%.3f, #%d, %dx%d",
            ptsSec, frameIndex, Int(currentWidth), Int(currentHeight)
        ))

        frameForDraw = frame.ciImage
        metalView.draw()
        renderedCount += 1

        debugOverlayLabel.text = String(
            format: " #%d  PTS: %.3f\n %dx%d ",
            frameIndex, ptsSec, Int(currentWidth), Int(currentHeight)
        )
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let ciImage = frameForDraw,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

        var scaledImage = ciImage

        // Scale to aspect-fit, centred over a black background.
        let drawSize = view.drawableSize
        let imgExtent = ciImage.extent
        guard imgExtent.width > 0, imgExtent.height > 0,
              drawSize.width > 0, drawSize.height > 0 else { return }

        let scale = min(drawSize.width / imgExtent.width, drawSize.height / imgExtent.height)
        let tx = (drawSize.width  - imgExtent.width  * scale) / 2.0
        let ty = (drawSize.height - imgExtent.height * scale) / 2.0

        scaledImage = scaledImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))

        // Black letterbox background
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(origin: .zero, size: drawSize))
        scaledImage = scaledImage.composited(over: background)

        let dest = CIRenderDestination(
            width: Int(drawSize.width),
            height: Int(drawSize.height),
            pixelFormat: view.colorPixelFormat,
            commandBuffer: commandBuffer
        ) { drawable.texture }

        do {
            try ciContext.startTask(toRender: scaledImage, to: dest)
        } catch {
            RTMPLogger.error("CIContext render failed: \(error)")
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Private — stats

    private func emitStatsIfNeeded() {
        let now = CACurrentMediaTime()
        let elapsed = now - statsWindowStart
        guard elapsed >= 1 else { return }

        let stats = RTMPRenderStats(
            incomingFPS: Double(incomingCount) / elapsed,
            renderedFPS: Double(renderedCount) / elapsed,
            droppedFPS: Double(droppedCount) / elapsed,
            bitrateKbps: 0,
            queueDepth: pendingFrame != nil ? 1 : 0,
            width: currentWidth,
            height: currentHeight,
            playoutDelayMs: 0
        )
        onStats?(stats)

        statsWindowStart = now
        incomingCount = 0
        renderedCount = 0
        droppedCount = 0
    }
}
