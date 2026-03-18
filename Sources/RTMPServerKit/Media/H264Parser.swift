import Foundation

/// Parses AVC (H264) video data from RTMP video messages.
///
/// RTMP video message format:
///  Byte 0: frame type (upper nibble) + codec id (lower nibble)
///    - Frame type: 1=keyframe, 2=inter frame
///    - Codec id: 7 = AVC (H264)
///  Byte 1: AVCPacketType
///    - 0 = AVCDecoderConfigurationRecord (SPS/PPS)
///    - 1 = AVC NALU
///    - 2 = AVC End of sequence
///  Bytes 2-4: Composition time offset (signed 24-bit, in ms)
///  Remaining bytes: payload
final class H264Parser {
    let spsPPSStore: SPSPPSStore
    var onSPSPPSUpdated: (() -> Void)?
    var onNALUnits: (([Data], Bool, UInt32) -> Void)? // nalus, isKeyframe, timestamp

    init(spsPPSStore: SPSPPSStore) {
        self.spsPPSStore = spsPPSStore
    }

    func parse(message: RTMPMessage) {
        let payload = message.payload
        guard payload.count >= 5 else { return }

        let firstByte = payload[0]
        let codecID = firstByte & 0x0F
        guard codecID == 7 else { return } // Only AVC

        let frameType = (firstByte >> 4) & 0x0F
        let isKeyframe = (frameType == 1)
        let avcPacketType = payload[1]

        switch avcPacketType {
        case 0:
            // AVCDecoderConfigurationRecord
            parseDecoderConfig(payload: payload, offset: 5)
        case 1:
            // AVC NAL units
            let naluPayload = payload.dropFirst(5)
            let nalus = parseNALUs(Data(naluPayload))
            if !nalus.isEmpty {
                onNALUnits?(nalus, isKeyframe, message.timestamp)
            }
        default:
            break
        }
    }

    // MARK: - Private

    private func parseDecoderConfig(payload: Data, offset: Int) {
        // AVCDecoderConfigurationRecord layout (ISO 14496-15):
        // 1 byte  configurationVersion
        // 1 byte  AVCProfileIndication
        // 1 byte  profile_compatibility
        // 1 byte  AVCLevelIndication
        // 1 byte  lengthSizeMinusOne (lower 2 bits) — always 3 (4-byte length)
        // 1 byte  numSequenceParameterSets (lower 5 bits)
        // N bytes SPS sets (each: 2 byte length + SPS data)
        // 1 byte  numPictureParameterSets
        // N bytes PPS sets (each: 2 byte length + PPS data)

        guard payload.count > offset + 5 else { return }
        var pos = offset
        pos += 5 // skip configurationVersion, profile, etc., and lengthSizeMinusOne

        guard pos < payload.count else { return }
        let numSPS = Int(payload[pos] & 0x1F)
        pos += 1

        var spsData: Data?
        for _ in 0 ..< numSPS {
            guard pos + 2 <= payload.count else { return }
            let spsLength = Int(payload[pos]) << 8 | Int(payload[pos + 1])
            pos += 2
            guard pos + spsLength <= payload.count else { return }
            if spsData == nil {
                spsData = Data(payload[pos ..< pos + spsLength])
            }
            pos += spsLength
        }

        guard pos < payload.count else { return }
        let numPPS = Int(payload[pos])
        pos += 1

        var ppsData: Data?
        for _ in 0 ..< numPPS {
            guard pos + 2 <= payload.count else { return }
            let ppsLength = Int(payload[pos]) << 8 | Int(payload[pos + 1])
            pos += 2
            guard pos + ppsLength <= payload.count else { return }
            if ppsData == nil {
                ppsData = Data(payload[pos ..< pos + ppsLength])
            }
            pos += ppsLength
        }

        if let sps = spsData, let pps = ppsData {
            spsPPSStore.update(sps: sps, pps: pps)
            onSPSPPSUpdated?()
        }
    }

    /// Parse length-prefixed NALU list (AVCC format, 4-byte lengths).
    private func parseNALUs(_ data: Data) -> [Data] {
        var nalus: [Data] = []
        var pos = 0
        while pos + 4 <= data.count {
            let length = Int(data[pos]) << 24 | Int(data[pos + 1]) << 16
                       | Int(data[pos + 2]) << 8 | Int(data[pos + 3])
            pos += 4
            guard length > 0, pos + length <= data.count else { break }
            nalus.append(Data(data[pos ..< pos + length]))
            pos += length
        }
        return nalus
    }
}
