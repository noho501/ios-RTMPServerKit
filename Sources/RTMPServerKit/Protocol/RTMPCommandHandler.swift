import Foundation

/// Builds RTMP responses (AMF0 encoded).
struct AMF0Encoder {
    static func encodeString(_ s: String) -> Data {
        var d = Data()
        d.append(0x02) // string marker
        let utf8 = s.utf8
        let len = UInt16(utf8.count)
        d.append(UInt8(len >> 8))
        d.append(UInt8(len & 0xFF))
        d.append(contentsOf: utf8)
        return d
    }

    static func encodeNumber(_ n: Double) -> Data {
        var d = Data()
        d.append(0x00) // number marker
        var raw = n.bitPattern.byteSwapped
        withUnsafeBytes(of: &raw) { d.append(contentsOf: $0) }
        return d
    }

    static func encodeNull() -> Data {
        Data([0x05])
    }

    static func encodeObjectStart() -> Data {
        Data([0x03])
    }

    static func encodeObjectEnd() -> Data {
        Data([0x00, 0x00, 0x09])
    }

    static func encodeKey(_ key: String) -> Data {
        var d = Data()
        let utf8 = key.utf8
        let len = UInt16(utf8.count)
        d.append(UInt8(len >> 8))
        d.append(UInt8(len & 0xFF))
        d.append(contentsOf: utf8)
        return d
    }

    static func encodeBool(_ b: Bool) -> Data {
        Data([0x01, b ? 0x01 : 0x00])
    }
}

/// Handles RTMP commands and generates responses.
final class RTMPCommandHandler {
    weak var connection: RTMPConnection?

    var onPublish: ((String) -> Void)?

    func handle(message: RTMPMessage) {
        guard message.typeID == RTMPMessage.typeCommandAMF0
                || message.typeID == RTMPMessage.typeDataAMF0
                || message.typeID == RTMPMessage.typeSetChunkSize
                || message.typeID == RTMPMessage.typeWindowAckSize
                || message.typeID == RTMPMessage.typeSetPeerBandwidth else {
            return
        }

        switch message.typeID {
        case RTMPMessage.typeSetChunkSize:
            handleSetChunkSize(message)
        case RTMPMessage.typeWindowAckSize:
            break // ignore
        case RTMPMessage.typeSetPeerBandwidth:
            break // ignore
        case RTMPMessage.typeCommandAMF0:
            handleCommand(message)
        default:
            break
        }
    }

    // MARK: - Private

    private func handleSetChunkSize(_ msg: RTMPMessage) {
        guard msg.payload.count >= 4 else { return }
        let size = Int(msg.payload[0]) << 24 | Int(msg.payload[1]) << 16
                 | Int(msg.payload[2]) << 8  | Int(msg.payload[3])
        connection?.setChunkSize(size & 0x7FFFFFFF)
    }

    private func handleCommand(_ msg: RTMPMessage) {
        let values = AMF0Decoder.decode(msg.payload)
        guard case let .string(commandName) = values.first else { return }
        let transactionID: Double
        if values.count > 1, case let .number(n) = values[1] {
            transactionID = n
        } else {
            transactionID = 0
        }

        switch commandName {
        case "connect":
            handleConnect(transactionID: transactionID)
        case "createStream":
            handleCreateStream(transactionID: transactionID)
        case "publish":
            handlePublish(values: values)
        case "releaseStream", "FCPublish", "FCUnpublish", "deleteStream":
            break // ignore
        default:
            break
        }
    }

    private func handleConnect(transactionID: Double) {
        // Send Window Acknowledgement Size
        sendWindowAckSize(2_500_000)
        // Send Set Peer Bandwidth
        sendSetPeerBandwidth(2_500_000)
        // Send Set Chunk Size
        sendSetChunkSize(4096)
        // Send _result for connect
        var payload = Data()
        payload.append(contentsOf: AMF0Encoder.encodeString("_result"))
        payload.append(contentsOf: AMF0Encoder.encodeNumber(transactionID))
        // properties object
        payload.append(contentsOf: AMF0Encoder.encodeObjectStart())
        payload.append(contentsOf: AMF0Encoder.encodeKey("fmsVer"))
        payload.append(contentsOf: AMF0Encoder.encodeString("FMS/3,0,1,123"))
        payload.append(contentsOf: AMF0Encoder.encodeKey("capabilities"))
        payload.append(contentsOf: AMF0Encoder.encodeNumber(31))
        payload.append(contentsOf: AMF0Encoder.encodeObjectEnd())
        // information object
        payload.append(contentsOf: AMF0Encoder.encodeObjectStart())
        payload.append(contentsOf: AMF0Encoder.encodeKey("level"))
        payload.append(contentsOf: AMF0Encoder.encodeString("status"))
        payload.append(contentsOf: AMF0Encoder.encodeKey("code"))
        payload.append(contentsOf: AMF0Encoder.encodeString("NetConnection.Connect.Success"))
        payload.append(contentsOf: AMF0Encoder.encodeKey("description"))
        payload.append(contentsOf: AMF0Encoder.encodeString("Connection succeeded."))
        payload.append(contentsOf: AMF0Encoder.encodeObjectEnd())
        sendChunk(chunkStreamID: 3, typeID: RTMPMessage.typeCommandAMF0, streamID: 0, payload: payload)
    }

    private func handleCreateStream(transactionID: Double) {
        var payload = Data()
        payload.append(contentsOf: AMF0Encoder.encodeString("_result"))
        payload.append(contentsOf: AMF0Encoder.encodeNumber(transactionID))
        payload.append(contentsOf: AMF0Encoder.encodeNull())
        payload.append(contentsOf: AMF0Encoder.encodeNumber(1)) // stream id = 1
        sendChunk(chunkStreamID: 3, typeID: RTMPMessage.typeCommandAMF0, streamID: 0, payload: payload)
    }

    private func handlePublish(values: [AMF0Decoder.Value]) {
        // values: ["publish", transactionID, null, streamName, publishType]
        let streamKey: String
        if values.count > 3, case let .string(key) = values[3] {
            streamKey = key
        } else {
            streamKey = "unknown"
        }

        // Send onStatus
        var payload = Data()
        payload.append(contentsOf: AMF0Encoder.encodeString("onStatus"))
        payload.append(contentsOf: AMF0Encoder.encodeNumber(0))
        payload.append(contentsOf: AMF0Encoder.encodeNull())
        payload.append(contentsOf: AMF0Encoder.encodeObjectStart())
        payload.append(contentsOf: AMF0Encoder.encodeKey("level"))
        payload.append(contentsOf: AMF0Encoder.encodeString("status"))
        payload.append(contentsOf: AMF0Encoder.encodeKey("code"))
        payload.append(contentsOf: AMF0Encoder.encodeString("NetStream.Publish.Start"))
        payload.append(contentsOf: AMF0Encoder.encodeKey("description"))
        payload.append(contentsOf: AMF0Encoder.encodeString("Started publishing stream."))
        payload.append(contentsOf: AMF0Encoder.encodeObjectEnd())
        sendChunk(chunkStreamID: 5, typeID: RTMPMessage.typeCommandAMF0, streamID: 1, payload: payload)

        onPublish?(streamKey)
    }

    // MARK: - Low-level sends

    private func sendWindowAckSize(_ size: UInt32) {
        var payload = Data(count: 4)
        payload[0] = UInt8((size >> 24) & 0xFF)
        payload[1] = UInt8((size >> 16) & 0xFF)
        payload[2] = UInt8((size >> 8)  & 0xFF)
        payload[3] = UInt8(size & 0xFF)
        sendChunk(chunkStreamID: 2, typeID: RTMPMessage.typeWindowAckSize, streamID: 0, payload: payload)
    }

    private func sendSetPeerBandwidth(_ size: UInt32) {
        var payload = Data(count: 5)
        payload[0] = UInt8((size >> 24) & 0xFF)
        payload[1] = UInt8((size >> 16) & 0xFF)
        payload[2] = UInt8((size >> 8)  & 0xFF)
        payload[3] = UInt8(size & 0xFF)
        payload[4] = 2 // dynamic
        sendChunk(chunkStreamID: 2, typeID: RTMPMessage.typeSetPeerBandwidth, streamID: 0, payload: payload)
    }

    private func sendSetChunkSize(_ size: Int) {
        connection?.updateOutgoingChunkSize(size)
        var payload = Data(count: 4)
        payload[0] = UInt8((size >> 24) & 0xFF)
        payload[1] = UInt8((size >> 16) & 0xFF)
        payload[2] = UInt8((size >> 8)  & 0xFF)
        payload[3] = UInt8(size & 0xFF)
        sendChunk(chunkStreamID: 2, typeID: RTMPMessage.typeSetChunkSize, streamID: 0, payload: payload)
    }

    private func sendChunk(chunkStreamID: UInt32, typeID: UInt8, streamID: UInt32, payload: Data) {
        connection?.send(buildChunk(
            chunkStreamID: chunkStreamID,
            typeID: typeID,
            streamID: streamID,
            payload: payload
        ))
    }

    private func buildChunk(chunkStreamID: UInt32, typeID: UInt8, streamID: UInt32, payload: Data) -> Data {
        var chunk = Data()
        // Basic header: fmt=0, csid
        chunk.append(UInt8(chunkStreamID & 0x3F)) // fmt=0 means top 2 bits are 0
        // Message header (11 bytes, fmt=0)
        chunk.append(0x00) // timestamp[0]
        chunk.append(0x00) // timestamp[1]
        chunk.append(0x00) // timestamp[2]
        let len = payload.count
        chunk.append(UInt8((len >> 16) & 0xFF))
        chunk.append(UInt8((len >> 8)  & 0xFF))
        chunk.append(UInt8(len & 0xFF))
        chunk.append(typeID)
        // Stream ID (little-endian)
        chunk.append(UInt8(streamID & 0xFF))
        chunk.append(UInt8((streamID >> 8) & 0xFF))
        chunk.append(UInt8((streamID >> 16) & 0xFF))
        chunk.append(UInt8((streamID >> 24) & 0xFF))
        // Payload (chunked)
        let outChunkSize = connection?.outgoingChunkSize ?? 128
        var offset = 0
        while offset < payload.count {
            let chunkEnd = min(offset + outChunkSize, payload.count)
            if offset > 0 {
                // fmt=3 continuation header
                chunk.append(UInt8(0xC0 | (chunkStreamID & 0x3F)))
            }
            chunk.append(contentsOf: payload[offset ..< chunkEnd])
            offset = chunkEnd
        }
        return chunk
    }
}
