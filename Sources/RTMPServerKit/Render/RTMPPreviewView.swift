import UIKit
import CoreMedia

/// A UIView that renders RTMP video frames using Metal + CoreImage.
///
/// Frames are rendered one-by-one without any hidden buffering, making all timing,
/// ordering and pacing issues directly observable in console logs and the on-screen
/// debug overlay in the top-left corner of the view.
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

    /// When `true`, an additional renderer-side PTS-sort buffer is used before rendering.
    /// Defaults to `false` — frames are rendered in arrival order for maximum observability.
    public var useReordering: Bool = false

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
        r.useReordering = useReordering
        r.onStats = { [weak self] stats in
            self?.onStats?(stats)
        }
        self.renderer = r

        // MTKView fills the preview container.
        r.metalView.frame = bounds
        r.metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(r.metalView)

        // onFrame is already delivered on the main thread by RTMPServer.
        server.onFrame = { [weak r] sampleBuffer in
            r?.enqueue(sampleBuffer)
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
