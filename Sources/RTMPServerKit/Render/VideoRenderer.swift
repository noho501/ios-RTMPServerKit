import Foundation
import AVFoundation
import CoreMedia

/// Renders H264 video frames using AVSampleBufferDisplayLayer.
/// Must be used only from the main thread.
final class VideoRenderer {
    let displayLayer: AVSampleBufferDisplayLayer

    init() {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.controlTimebase = makeControlTimebase()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
            displayLayer.controlTimebase = makeControlTimebase()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    func flush() {
        displayLayer.flush()
        displayLayer.controlTimebase = makeControlTimebase()
    }

    // MARK: - Private

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
