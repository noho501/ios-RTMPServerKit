import Foundation
import CoreMedia
import CoreVideo

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
//   server.onFrame = { pixelBuffer, pts in /* render or process */ }
//   try server.start(port: 1935)
//
// The `onFrame` callback delivers stable, clock-paced frames via `FrameScheduler`.
// All buffering, B-frame reordering, and timing happen before `onFrame` is called.
// The callback is always invoked on the **main thread**.
