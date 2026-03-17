import Foundation
import Network
import CoreMedia

/// Manages a single RTMP client connection.
final class RTMPConnection {
    private let connection: NWConnection
    private let id: UUID
    private let networkQueue: DispatchQueue
    private let parseQueue: DispatchQueue

    private let handshake = RTMPHandshake()
    private let chunkParser = RTMPChunkParser()
    private let commandHandler: RTMPCommandHandler
    private let h264Parser: H264Parser
    private let sampleBufferFactory: SampleBufferFactory
    private let spsPPSStore: SPSPPSStore

    private(set) var state: RTMPSessionState = .uninitialized

    var onFrame: ((CMSampleBuffer) -> Void)?
    var onPublish: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var outgoingChunkSize: Int = 128

    init(connection: NWConnection, id: UUID = UUID()) {
        self.connection = connection
        self.id = id
        self.networkQueue = DispatchQueue(label: "rtmp.connection.\(id).network", qos: .userInteractive)
        self.parseQueue = DispatchQueue(label: "rtmp.connection.\(id).parse", qos: .userInteractive)

        let store = SPSPPSStore()
        self.spsPPSStore = store
        self.h264Parser = H264Parser(spsPPSStore: store)
        self.sampleBufferFactory = SampleBufferFactory(spsPPSStore: store)
        self.commandHandler = RTMPCommandHandler()

        commandHandler.connection = self

        commandHandler.onPublish = { [weak self] key in
            self?.state = .publishing
            self?.onPublish?(key)
        }

        chunkParser.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }

        h264Parser.onNALUnits = { [weak self] nalus, isKeyframe, timestamp in
            guard let self else { return }
            if let sb = self.sampleBufferFactory.makeSampleBuffer(
                nalus: nalus, isKeyframe: isKeyframe, timestamp: timestamp
            ) {
                self.onFrame?(sb)
            }
        }

        h264Parser.onSPSPPSUpdated = { [weak self] in
            self?.sampleBufferFactory.reset()
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] newState in
            self?.handleConnectionState(newState)
        }
        connection.start(queue: networkQueue)
        scheduleReceive()
    }

    func stop() {
        connection.cancel()
        state = .disconnected
    }

    func send(_ data: Data) {
        guard state != .disconnected else { return }
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    RTMPLogger.error("Send error: \(error)")
                    self?.disconnect()
                }
            }
        )
    }

    func setChunkSize(_ size: Int) {
        chunkParser.setChunkSize(size)
    }

    func updateOutgoingChunkSize(_ size: Int) {
        outgoingChunkSize = max(128, size)
    }

    // MARK: - Private

    private func scheduleReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                RTMPLogger.error("Receive error: \(error)")
                self.disconnect()
                return
            }
            if let data, !data.isEmpty {
                self.parseQueue.async {
                    self.processIncoming(data)
                }
            }
            if isComplete {
                self.disconnect()
                return
            }
            self.scheduleReceive()
        }
    }

    private func processIncoming(_ data: Data) {
        guard state != .disconnected else { return }

        if handshake.state != .complete {
            // Feed to handshake; it buffers internally
            if let response = handshake.consume(data) {
                send(response)
            }

            // Check if handshake is now complete
            if handshake.state == .complete {
                state = .connected
                let remaining = handshake.drainRemaining()
                if !remaining.isEmpty {
                    chunkParser.append(remaining)
                }
            }
        } else {
            chunkParser.append(data)
        }
    }

    private func handleMessage(_ message: RTMPMessage) {
        switch message.typeID {
        case RTMPMessage.typeVideo:
            if state == .publishing {
                h264Parser.parse(message: message)
            }
        case RTMPMessage.typeAudio:
            break // Audio not implemented
        default:
            commandHandler.handle(message: message)
        }
    }

    private func handleConnectionState(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            RTMPLogger.info("Connection ready: \(id)")
        case .failed(let error):
            RTMPLogger.error("Connection failed: \(error)")
            disconnect()
        case .cancelled:
            disconnect()
        default:
            break
        }
    }

    private func disconnect() {
        guard state != .disconnected else { return }
        state = .disconnected
        connection.cancel()
        spsPPSStore.reset()
        sampleBufferFactory.reset()
        onDisconnect?()
    }
}

// Simple logger
enum RTMPLogger {
    static func info(_ msg: String) {
        #if DEBUG
        print("[RTMPServerKit] INFO: \(msg)")
        #endif
    }

    static func error(_ msg: String) {
        #if DEBUG
        print("[RTMPServerKit] ERROR: \(msg)")
        #endif
    }
}
