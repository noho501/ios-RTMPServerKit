import Foundation

public struct RTMPRenderStats {
    public let incomingFPS: Double
    public let renderedFPS: Double
    public let droppedFPS: Double
    public let bitrateKbps: Double
    public let queueDepth: Int
    public let width: Int32
    public let height: Int32
    public let playoutDelayMs: Int

    public init(
        incomingFPS: Double,
        renderedFPS: Double,
        droppedFPS: Double,
        bitrateKbps: Double,
        queueDepth: Int,
        width: Int32,
        height: Int32,
        playoutDelayMs: Int
    ) {
        self.incomingFPS = incomingFPS
        self.renderedFPS = renderedFPS
        self.droppedFPS = droppedFPS
        self.bitrateKbps = bitrateKbps
        self.queueDepth = queueDepth
        self.width = width
        self.height = height
        self.playoutDelayMs = playoutDelayMs
    }
}
