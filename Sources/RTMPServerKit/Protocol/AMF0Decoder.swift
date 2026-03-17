import Foundation

/// Decodes AMF0 encoded values.
struct AMF0Decoder {
    enum Value {
        case number(Double)
        case bool(Bool)
        case string(String)
        case object([String: Value])
        case null
        case undefined
        case ecmaArray([String: Value])
    }

    // AMF0 type markers
    private enum Marker: UInt8 {
        case number    = 0x00
        case bool      = 0x01
        case string    = 0x02
        case object    = 0x03
        case null      = 0x05
        case undefined = 0x06
        case ecmaArray = 0x08
        case objectEnd = 0x09
    }

    static func decode(_ data: Data) -> [Value] {
        var reader = ByteReader(data: data)
        var results: [Value] = []
        while !reader.isAtEnd {
            if let val = readValue(from: &reader) {
                results.append(val)
            } else {
                break
            }
        }
        return results
    }

    // MARK: - Private

    private static func readValue(from reader: inout ByteReader) -> Value? {
        guard let typeByte = try? reader.readUInt8() else { return nil }
        switch Marker(rawValue: typeByte) {
        case .number:
            return readNumber(from: &reader)
        case .bool:
            return readBool(from: &reader)
        case .string:
            return readString(from: &reader)
        case .object:
            return readObject(from: &reader)
        case .null:
            return .null
        case .undefined:
            return .undefined
        case .ecmaArray:
            return readEcmaArray(from: &reader)
        default:
            return .null
        }
    }

    private static func readNumber(from reader: inout ByteReader) -> Value? {
        guard let bytes = try? reader.readBytes(8) else { return nil }
        // AMF0 numbers are big-endian IEEE 754 doubles
        var raw: UInt64 = 0
        bytes.withUnsafeBytes { ptr in
            raw = ptr.load(as: UInt64.self)
        }
        raw = raw.byteSwapped
        let value = reinterpretBits(raw, as: Double.self)
        return .number(value)
    }

    private static func readBool(from reader: inout ByteReader) -> Value? {
        guard let byte = try? reader.readUInt8() else { return nil }
        return .bool(byte != 0)
    }

    private static func readString(from reader: inout ByteReader) -> Value? {
        guard let length = try? reader.readUInt16BE() else { return nil }
        guard let bytes = try? reader.readBytes(Int(length)) else { return nil }
        return .string(String(bytes: bytes, encoding: .utf8) ?? "")
    }

    private static func readObject(from reader: inout ByteReader) -> Value? {
        var pairs: [String: Value] = [:]
        while true {
            // Read key (U16 string)
            guard let keyLength = try? reader.readUInt16BE() else { break }
            if keyLength == 0 {
                // End of object marker (0x00 0x00 0x09)
                _ = try? reader.readUInt8()
                break
            }
            guard let keyBytes = try? reader.readBytes(Int(keyLength)) else { break }
            let key = String(bytes: keyBytes, encoding: .utf8) ?? ""
            guard let value = readValue(from: &reader) else { break }
            pairs[key] = value
        }
        return .object(pairs)
    }

    private static func readEcmaArray(from reader: inout ByteReader) -> Value? {
        _ = try? reader.readUInt32BE() // count hint, not reliable
        return readObject(from: &reader)
    }
}

private func reinterpretBits<T, U>(_ value: T, as type: U.Type) -> U {
    var v = value
    return withUnsafeBytes(of: &v) { $0.load(as: U.self) }
}
