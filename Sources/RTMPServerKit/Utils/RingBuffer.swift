import Foundation

/// A simple FIFO ring buffer backed by a byte array.
final class RingBuffer {
    private var buffer: [UInt8]
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private(set) var count: Int = 0

    var capacity: Int { buffer.count }
    var isEmpty: Bool { count == 0 }

    init(capacity: Int = 65536) {
        buffer = [UInt8](repeating: 0, count: capacity)
    }

    /// Append bytes to the ring buffer, growing the backing store if needed.
    func write(_ data: Data) {
        data.withUnsafeBytes { ptr in
            write(ptr.bindMemory(to: UInt8.self).baseAddress!, length: data.count)
        }
    }

    func write(_ bytes: UnsafePointer<UInt8>, length: Int) {
        ensureCapacity(count + length)
        let cap = buffer.count
        let spaceToEnd = cap - writeIndex
        if length <= spaceToEnd {
            buffer.withUnsafeMutableBufferPointer {
                $0.baseAddress!.advanced(by: writeIndex)
                    .initialize(from: bytes, count: length)
            }
            writeIndex = (writeIndex + length) % cap
        } else {
            // Wrap around
            buffer.withUnsafeMutableBufferPointer {
                $0.baseAddress!.advanced(by: writeIndex)
                    .initialize(from: bytes, count: spaceToEnd)
                $0.baseAddress!
                    .initialize(from: bytes.advanced(by: spaceToEnd), count: length - spaceToEnd)
            }
            writeIndex = length - spaceToEnd
        }
        count += length
    }

    /// Read and consume up to `length` bytes.
    @discardableResult
    func read(into dest: UnsafeMutablePointer<UInt8>, length: Int) -> Int {
        let toRead = min(length, count)
        let cap = buffer.count
        let contiguousToEnd = cap - readIndex
        if toRead <= contiguousToEnd {
            buffer.withUnsafeBufferPointer {
                dest.initialize(from: $0.baseAddress!.advanced(by: readIndex), count: toRead)
            }
            readIndex = (readIndex + toRead) % cap
        } else {
            // Wrap around
            let firstPart = contiguousToEnd
            let secondPart = toRead - firstPart
            buffer.withUnsafeBufferPointer {
                dest.initialize(from: $0.baseAddress!.advanced(by: readIndex), count: firstPart)
                dest.advanced(by: firstPart).initialize(from: $0.baseAddress!, count: secondPart)
            }
            readIndex = secondPart
        }
        count -= toRead
        return toRead
    }

    /// Peek without consuming.
    func peek(into dest: UnsafeMutablePointer<UInt8>, length: Int) -> Int {
        let toPeek = min(length, count)
        let cap = buffer.count
        let contiguousToEnd = cap - readIndex
        if toPeek <= contiguousToEnd {
            buffer.withUnsafeBufferPointer {
                dest.initialize(from: $0.baseAddress!.advanced(by: readIndex), count: toPeek)
            }
        } else {
            let firstPart = contiguousToEnd
            let secondPart = toPeek - firstPart
            buffer.withUnsafeBufferPointer {
                dest.initialize(from: $0.baseAddress!.advanced(by: readIndex), count: firstPart)
                dest.advanced(by: firstPart).initialize(from: $0.baseAddress!, count: secondPart)
            }
        }
        return toPeek
    }

    /// Read all available bytes as Data and consume them.
    func readAll() -> Data {
        var out = [UInt8](repeating: 0, count: count)
        read(into: &out, length: count)
        return Data(out)
    }

    /// Read exactly `length` bytes into a Data value.
    func readData(_ length: Int) -> Data? {
        guard count >= length else { return nil }
        var out = [UInt8](repeating: 0, count: length)
        read(into: &out, length: length)
        return Data(out)
    }

    /// Discard bytes.
    func discard(_ length: Int) {
        let toDiscard = min(length, count)
        readIndex = (readIndex + toDiscard) % buffer.count
        count -= toDiscard
    }

    func reset() {
        readIndex = 0
        writeIndex = 0
        count = 0
    }

    // MARK: - Private

    private func ensureCapacity(_ needed: Int) {
        guard needed > buffer.count else { return }
        var newCap = buffer.count * 2
        while newCap < needed { newCap *= 2 }
        var newBuf = [UInt8](repeating: 0, count: newCap)
        _ = peek(into: &newBuf, length: count)
        // Re-layout
        let oldCount = count
        writeIndex = oldCount
        readIndex = 0
        buffer = newBuf
    }
}
