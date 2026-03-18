import Foundation

/// An RTMP message assembled from one or more chunks.
struct RTMPMessage {
    var typeID: UInt8
    var streamID: UInt32
    var timestamp: UInt32
    var payload: Data

    // RTMP message type IDs
    static let typeSetChunkSize: UInt8       = 1
    static let typeAbortMessage: UInt8       = 2
    static let typeAcknowledgement: UInt8    = 3
    static let typeWindowAckSize: UInt8      = 5
    static let typeSetPeerBandwidth: UInt8   = 6
    static let typeUserControl: UInt8        = 4
    static let typeAudio: UInt8              = 8
    static let typeVideo: UInt8              = 9
    static let typeDataAMF0: UInt8           = 18
    static let typeCommandAMF0: UInt8        = 20
}
