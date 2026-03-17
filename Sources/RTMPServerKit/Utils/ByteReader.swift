import Foundation

/// Lightweight byte reader over a Data slice.
struct ByteReader {
    private let data: Data
    private(set) var position: Int

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.position = offset
    }

    var remaining: Int { data.count - position }
    var isAtEnd: Bool { position >= data.count }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw ByteReaderError.outOfBounds }
        defer { position += 1 }
        return data[data.startIndex + position]
    }

    mutating func readUInt16BE() throws -> UInt16 {
        guard remaining >= 2 else { throw ByteReaderError.outOfBounds }
        let b0 = UInt16(data[data.startIndex + position])
        let b1 = UInt16(data[data.startIndex + position + 1])
        position += 2
        return (b0 << 8) | b1
    }

    mutating func readUInt24BE() throws -> UInt32 {
        guard remaining >= 3 else { throw ByteReaderError.outOfBounds }
        let b0 = UInt32(data[data.startIndex + position])
        let b1 = UInt32(data[data.startIndex + position + 1])
        let b2 = UInt32(data[data.startIndex + position + 2])
        position += 3
        return (b0 << 16) | (b1 << 8) | b2
    }

    mutating func readUInt32BE() throws -> UInt32 {
        guard remaining >= 4 else { throw ByteReaderError.outOfBounds }
        let b0 = UInt32(data[data.startIndex + position])
        let b1 = UInt32(data[data.startIndex + position + 1])
        let b2 = UInt32(data[data.startIndex + position + 2])
        let b3 = UInt32(data[data.startIndex + position + 3])
        position += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    mutating func readUInt32LE() throws -> UInt32 {
        guard remaining >= 4 else { throw ByteReaderError.outOfBounds }
        let b0 = UInt32(data[data.startIndex + position])
        let b1 = UInt32(data[data.startIndex + position + 1])
        let b2 = UInt32(data[data.startIndex + position + 2])
        let b3 = UInt32(data[data.startIndex + position + 3])
        position += 4
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard remaining >= count else { throw ByteReaderError.outOfBounds }
        let start = data.startIndex + position
        let slice = data[start ..< start + count]
        position += count
        return Data(slice)
    }

    mutating func skip(_ count: Int) throws {
        guard remaining >= count else { throw ByteReaderError.outOfBounds }
        position += count
    }
}

enum ByteReaderError: Error {
    case outOfBounds
}
