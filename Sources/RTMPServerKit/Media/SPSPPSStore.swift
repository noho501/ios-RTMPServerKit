import Foundation

/// Stores the most recent SPS and PPS NAL units for H264 decoding.
final class SPSPPSStore {
    private let lock = NSLock()
    private var _sps: Data?
    private var _pps: Data?

    var sps: Data? {
        lock.lock(); defer { lock.unlock() }
        return _sps
    }

    var pps: Data? {
        lock.lock(); defer { lock.unlock() }
        return _pps
    }

    func update(sps: Data, pps: Data) {
        lock.lock(); defer { lock.unlock() }
        _sps = sps
        _pps = pps
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _sps = nil
        _pps = nil
    }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return _sps != nil && _pps != nil
    }
}
