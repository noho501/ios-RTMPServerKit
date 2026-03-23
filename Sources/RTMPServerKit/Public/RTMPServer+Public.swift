import Foundation
import CoreImage
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
//   server.onCIImage = { ciImage, pts in /* render or process */ }
//   try server.start(port: 1935)
//
// The `onCIImage` callback delivers stable, clock-paced `CIImage` frames via `FrameScheduler`.
// All buffering, B-frame reordering, timing, and CVPixelBuffer → CIImage conversion happen
// before `onCIImage` is called. The callback is always invoked on the **main thread**.
