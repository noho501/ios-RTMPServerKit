import Foundation
import CoreMedia

// RTMPServer+Public.swift
// Re-exports and documents the public surface of RTMPServerKit.
//
// Public types:
//   - RTMPServer: The main server class.
//   - RTMPPreviewView: A UIView subclass for live video preview.
//
// Usage:
//   let server = RTMPServer()
//   server.onPublish = { key in print("Publishing: \(key)") }
//   server.onFrame = { sampleBuffer in /* render */ }
//   try server.start(port: 1935)
