import UIKit
import AVFoundation
import CoreMedia

/// A UIView that renders RTMP video using AVSampleBufferDisplayLayer.
public final class RTMPPreviewView: UIView {
    private var renderer: VideoRenderer?
    public var preferredPlayoutDelay: TimeInterval = 0.8
    public var preferredMaxQueueDepth: Int = 40
    public var onStats: ((RTMPRenderStats) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
    }

    /// Attach to an RTMPServer and start rendering frames it produces.
    public func attach(server: RTMPServer) {
        let r = VideoRenderer(
            playoutDelay: preferredPlayoutDelay,
            maxPendingCount: preferredMaxQueueDepth
        )
        self.renderer = r
        r.displayLayer.frame = bounds
        r.displayLayer.videoGravity = .resizeAspect
        r.onStats = { [weak self] stats in
            self?.onStats?(stats)
        }
        layer.addSublayer(r.displayLayer)

        // onFrame is already called on the main thread by RTMPServer
        server.onFrame = { [weak r] sampleBuffer in
            r?.enqueue(sampleBuffer)
        }
    }

    public func resetStreamState() {
        renderer?.startNewStream()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        renderer?.displayLayer.frame = bounds
    }
}
