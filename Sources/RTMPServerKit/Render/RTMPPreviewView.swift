import UIKit
import CoreImage
import CoreMedia

/// A UIView that renders RTMP video frames using Metal + CoreImage.
///
/// Frames are buffered and released in presentation-time order using a clock-paced
/// playback buffer, eliminating stutter caused by B-frame reordering and network jitter.
/// By default the renderer accumulates 1 second of frames before starting playback,
/// trading a small amount of latency for perfectly smooth motion.
///
/// Usage:
/// ```swift
/// let preview = RTMPPreviewView()
/// preview.attach(server: myServer)
/// ```
public final class RTMPPreviewView: UIView {
    private var renderer: VideoRenderer?

    /// Callback delivering rendering statistics approximately once per second (main thread).
    public var onStats: ((RTMPRenderStats) -> Void)?

    /// Minimum seconds of frames to buffer before playback begins (and after an underrun).
    /// Increase for smoother playback on lossy networks; decrease to reduce initial latency.
    /// Default: **1.0 s**.
    public var minBufferDuration: Double = 1.0

    /// Kept for API compatibility.  The renderer always uses PTS-sorted buffering.
    public var useReordering: Bool = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }

    /// Attach to an RTMPServer and start rendering frames it produces.
    public func attach(server: RTMPServer) {
        let r = VideoRenderer()
        r.minBufferDuration = minBufferDuration
        r.useReordering = useReordering
        r.onStats = { [weak self] stats in
            self?.onStats?(stats)
        }
        self.renderer = r

        // MTKView fills the preview container.
        r.metalView.frame = bounds
        r.metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(r.metalView)

        // onCIImage is already delivered on the main thread by FrameScheduler.
        server.onCIImage = { [weak r] ciImage, pts in
            r?.enqueue(ciImage: ciImage, pts: pts)
        }
    }

    /// Reset renderer state — call when a new publish session begins.
    public func resetStreamState() {
        renderer?.startNewStream()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        renderer?.metalView.frame = bounds
    }
}
