import Foundation

/// Converts AVCC-format NAL units to Annex-B format.
struct NALUAssembler {
    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    /// Convert an array of raw NALU payloads (without length prefix or start codes)
    /// to a single contiguous Annex-B buffer.
    static func annexB(from nalus: [Data]) -> Data {
        var result = Data()
        result.reserveCapacity(nalus.reduce(0) { $0 + 4 + $1.count })
        for nalu in nalus {
            result.append(contentsOf: startCode)
            result.append(nalu)
        }
        return result
    }

    /// Prepend SPS and PPS start-code-prefixed units before the NALU data.
    static func annexBWithParameterSets(sps: Data, pps: Data, nalus: [Data]) -> Data {
        var result = Data()
        result.append(contentsOf: startCode)
        result.append(sps)
        result.append(contentsOf: startCode)
        result.append(pps)
        for nalu in nalus {
            result.append(contentsOf: startCode)
            result.append(nalu)
        }
        return result
    }
}
