import Foundation

/// RTMP handshake implementation (simple handshake).
///
/// RTMP handshake sequence:
///  Client sends: C0 (1 byte) + C1 (1536 bytes) = 1537 bytes
///  Server sends: S0 (1 byte) + S1 (1536 bytes) + S2 (1536 bytes)
///  Client sends: C2 (1536 bytes)
final class RTMPHandshake {
    enum State {
        case waitingForC0C1
        case waitingForC2
        case complete
    }

    private(set) var state: State = .waitingForC0C1
    private let ringBuffer = RingBuffer(capacity: 4096)

    /// Feed incoming bytes into the handshake processor.
    /// - Returns: Data to send back to the client, or nil if more data is needed.
    func consume(_ data: Data) -> Data? {
        ringBuffer.write(data)
        return processBuffer()
    }

    /// Any bytes remaining in the buffer after handshake is complete.
    func drainRemaining() -> Data {
        ringBuffer.readAll()
    }

    // MARK: - Private

    private func processBuffer() -> Data? {
        switch state {
        case .waitingForC0C1:
            guard let response = handleC0C1() else { return nil }
            // Immediately try C2 in case it arrived in the same packet
            _ = handleC2()
            return response
        case .waitingForC2:
            _ = handleC2()
            return nil
        case .complete:
            return nil
        }
    }

    private func handleC0C1() -> Data? {
        let needed = 1 + 1536 // C0 + C1
        guard ringBuffer.count >= needed else { return nil }

        // Read C0 (RTMP version byte) — we accept any version
        var c0: UInt8 = 0
        ringBuffer.read(into: &c0, length: 1)

        // Read C1 (1536 bytes)
        var c1 = [UInt8](repeating: 0, count: 1536)
        ringBuffer.read(into: &c1, length: 1536)

        // Build S0 + S1 + S2
        var response = Data()

        // S0: version 3
        response.append(0x03)

        // S1: 1536 bytes (timestamp = 0, zeros for the rest)
        var s1 = [UInt8](repeating: 0, count: 1536)
        // First 4 bytes: server timestamp (0)
        // Next 4 bytes: zeros
        response.append(contentsOf: s1)

        // S2: echo of C1
        response.append(contentsOf: c1)

        state = .waitingForC2
        return response
    }

    private func handleC2() -> Data? {
        guard ringBuffer.count >= 1536 else { return nil }
        // Discard C2
        ringBuffer.discard(1536)
        state = .complete
        return nil
    }
}
