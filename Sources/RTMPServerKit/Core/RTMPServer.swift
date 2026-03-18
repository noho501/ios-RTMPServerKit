import Foundation
import Network
import CoreMedia

/// The main RTMP server that listens on a TCP port.
public final class RTMPServer {
    // MARK: - Public callbacks

    /// Called on the main thread when a new video frame is ready.
    public var onFrame: ((CMSampleBuffer) -> Void)?

    /// Called when a client starts publishing, with the stream key.
    public var onPublish: ((String) -> Void)?

    /// Called when a client disconnects.
    public var onDisconnect: (() -> Void)?

    // MARK: - Private

    private var listener: NWListener?
    private var connections: [UUID: RTMPConnection] = [:]
    private let serverQueue = DispatchQueue(label: "rtmp.server.queue", qos: .userInteractive)
    private let connectionsLock = NSLock()

    public init() {}

    // MARK: - Public API

    public func start(port: UInt16) throws {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] newConnection in
            self?.accept(newConnection)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                RTMPLogger.info("Server listening on port \(port)")
            case .failed(let error):
                RTMPLogger.error("Listener failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: serverQueue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil

        connectionsLock.lock()
        let all = connections
        connections.removeAll()
        connectionsLock.unlock()

        for conn in all.values {
            conn.stop()
        }
    }

    // MARK: - Private

    private func accept(_ nwConnection: NWConnection) {
        let id = UUID()
        let conn = RTMPConnection(connection: nwConnection, id: id)

        conn.onFrame = { [weak self] sampleBuffer in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onFrame?(sampleBuffer)
            }
        }

        conn.onPublish = { [weak self] key in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onPublish?(key)
            }
        }

        conn.onDisconnect = { [weak self] in
            guard let self else { return }
            self.connectionsLock.lock()
            self.connections.removeValue(forKey: id)
            self.connectionsLock.unlock()
            DispatchQueue.main.async {
                self.onDisconnect?()
            }
        }

        connectionsLock.lock()
        connections[id] = conn
        connectionsLock.unlock()

        conn.start()
    }
}
