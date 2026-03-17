import Foundation

/// Incrementally parses the RTMP chunk stream from a byte stream.
///
/// RTMP Chunk format:
///   Basic Header (1-3 bytes)
///   Message Header (0, 3, 7, or 11 bytes depending on fmt)
///   Extended Timestamp (0 or 4 bytes)
///   Chunk Data (up to chunkSize bytes)
final class RTMPChunkParser {
    // Default RTMP chunk size
    private(set) var chunkSize: Int = 128
    private let ringBuffer = RingBuffer(capacity: 1 << 20) // 1 MB
    private var streams: [UInt32: RTMPChunkStream] = [:]
    var onMessage: ((RTMPMessage) -> Void)?

    func setChunkSize(_ size: Int) {
        chunkSize = max(1, size)
    }

    func append(_ data: Data) {
        ringBuffer.write(data)
        parseChunks()
    }

    // MARK: - Parsing

    private func parseChunks() {
        while parseNextChunk() {}
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func parseNextChunk() -> Bool {
        // We need at least 1 byte for basic header
        guard ringBuffer.count >= 1 else { return false }

        // Peek at the basic header without consuming
        var scratch = [UInt8](repeating: 0, count: 3)
        let peeked = ringBuffer.peek(into: &scratch, length: 3)
        guard peeked >= 1 else { return false }

        let firstByte = scratch[0]
        let fmt = (firstByte >> 6) & 0x03
        var csidRaw = Int(firstByte & 0x3F)
        var basicHeaderSize = 1

        if csidRaw == 0 {
            // 2-byte form: csid = second_byte + 64
            guard peeked >= 2 else { return false }
            csidRaw = Int(scratch[1]) + 64
            basicHeaderSize = 2
        } else if csidRaw == 1 {
            // 3-byte form: csid = third_byte * 256 + second_byte + 64
            guard peeked >= 3 else { return false }
            csidRaw = Int(scratch[2]) * 256 + Int(scratch[1]) + 64
            basicHeaderSize = 3
        }

        let csid = UInt32(csidRaw)

        // Determine message header size based on fmt
        let messageHeaderSize: Int
        switch fmt {
        case 0: messageHeaderSize = 11
        case 1: messageHeaderSize = 7
        case 2: messageHeaderSize = 3
        default: messageHeaderSize = 0
        }

        let minimumNeeded = basicHeaderSize + messageHeaderSize
        guard ringBuffer.count >= minimumNeeded else { return false }

        // Peek enough bytes to read message header
        var headerBuf = [UInt8](repeating: 0, count: minimumNeeded + 4) // +4 for extended TS
        let peekLen = ringBuffer.peek(into: &headerBuf, length: min(minimumNeeded + 4, ringBuffer.count))
        guard peekLen >= minimumNeeded else { return false }

        var offset = basicHeaderSize
        let cs = stream(for: csid)

        var rawTimestamp: UInt32 = 0
        var extendedTimestamp = false

        switch fmt {
        case 0:
            // Full header
            rawTimestamp = readUInt24BE(from: headerBuf, at: offset)
            offset += 3
            cs.messageLength = readUInt24BE(from: headerBuf, at: offset)
            offset += 3
            cs.messageTypeID = headerBuf[offset]
            offset += 1
            cs.messageStreamID = readUInt32LE(from: headerBuf, at: offset)
            offset += 4
            extendedTimestamp = (rawTimestamp == 0xFFFFFF)
            cs.timestampDelta = 0

        case 1:
            rawTimestamp = readUInt24BE(from: headerBuf, at: offset)
            offset += 3
            cs.messageLength = readUInt24BE(from: headerBuf, at: offset)
            offset += 3
            cs.messageTypeID = headerBuf[offset]
            offset += 1
            extendedTimestamp = (rawTimestamp == 0xFFFFFF)

        case 2:
            rawTimestamp = readUInt24BE(from: headerBuf, at: offset)
            offset += 3
            extendedTimestamp = (rawTimestamp == 0xFFFFFF)

        default:
            break // fmt 3: no message header
        }

        // Check for extended timestamp
        var extTSSize = 0
        if extendedTimestamp {
            guard peekLen >= offset + 4 else { return false }
            extTSSize = 4
        }

        let totalHeaderSize = minimumNeeded + extTSSize
        guard ringBuffer.count >= totalHeaderSize else { return false }

        // Now compute how many payload bytes are in this chunk
        let payloadRemaining = Int(cs.messageLength) - cs.payload.count
        let chunkPayloadSize = min(chunkSize, payloadRemaining)
        let totalChunkSize = totalHeaderSize + chunkPayloadSize

        guard ringBuffer.count >= totalChunkSize else { return false }

        // Consume the header
        ringBuffer.discard(totalHeaderSize)

        // Apply extended timestamp
        if extendedTimestamp {
            let extTS = readUInt32BE(from: headerBuf, at: offset)
            rawTimestamp = extTS
        }

        // Update timestamps
        switch fmt {
        case 0:
            cs.timestamp = rawTimestamp
            cs.timestampDelta = 0
        case 1, 2:
            cs.timestampDelta = rawTimestamp
            if cs.payload.isEmpty {
                // Only advance timestamp at the start of a new message
                cs.timestamp = cs.timestamp &+ cs.timestampDelta
            }
        default: // fmt=3: reuse stored delta, only advance at new message start
            if cs.payload.isEmpty {
                cs.timestamp = cs.timestamp &+ cs.timestampDelta
            }
        }

        // Read chunk payload
        if chunkPayloadSize > 0, let payloadData = ringBuffer.readData(chunkPayloadSize) {
            cs.payload.append(payloadData)
        }

        // Check if message is complete
        if cs.payload.count >= Int(cs.messageLength) {
            let msg = RTMPMessage(
                typeID: cs.messageTypeID,
                streamID: cs.messageStreamID,
                timestamp: cs.timestamp,
                payload: cs.payload
            )
            cs.reset()
            onMessage?(msg)
        }

        return true
    }

    // MARK: - Helpers

    private func stream(for csid: UInt32) -> RTMPChunkStream {
        if let existing = streams[csid] { return existing }
        let s = RTMPChunkStream()
        s.chunkStreamID = csid
        streams[csid] = s
        return s
    }

    private func readUInt24BE(from buf: [UInt8], at offset: Int) -> UInt32 {
        UInt32(buf[offset]) << 16 | UInt32(buf[offset + 1]) << 8 | UInt32(buf[offset + 2])
    }

    private func readUInt32BE(from buf: [UInt8], at offset: Int) -> UInt32 {
        UInt32(buf[offset]) << 24 | UInt32(buf[offset + 1]) << 16 |
        UInt32(buf[offset + 2]) << 8 | UInt32(buf[offset + 3])
    }

    private func readUInt32LE(from buf: [UInt8], at offset: Int) -> UInt32 {
        UInt32(buf[offset]) | UInt32(buf[offset + 1]) << 8 |
        UInt32(buf[offset + 2]) << 16 | UInt32(buf[offset + 3]) << 24
    }
}
