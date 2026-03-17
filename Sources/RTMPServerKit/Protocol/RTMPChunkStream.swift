import Foundation

/// Tracks per-chunk-stream state for assembling RTMP messages.
final class RTMPChunkStream {
    var chunkStreamID: UInt32 = 0
    var timestamp: UInt32 = 0
    var timestampDelta: UInt32 = 0
    var messageLength: UInt32 = 0
    var messageTypeID: UInt8 = 0
    var messageStreamID: UInt32 = 0
    var bytesRead: Int = 0
    var payload: Data = Data()

    var isComplete: Bool { payload.count >= Int(messageLength) }

    func reset() {
        bytesRead = 0
        payload = Data()
    }
}
