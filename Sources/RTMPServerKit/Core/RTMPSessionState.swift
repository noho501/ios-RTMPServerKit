import Foundation

/// RTMP session state machine.
enum RTMPSessionState {
    case uninitialized
    case handshakeC0C1Received
    case handshakeC2Received
    case connected
    case streamCreated
    case publishing
    case disconnected
}
