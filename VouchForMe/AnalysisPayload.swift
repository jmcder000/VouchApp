//
//  AnalysisPayload.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


//
//  AnalysisPayload.swift
//  VouchForMe
//
//  Phase 4: Payload model + image encoding helpers
//

import Foundation
import AppKit

/// Wire format we’ll send to the analyzer (Phase 5).
struct AnalysisPayload: Codable {
    struct AppInfo: Codable {
        let bundleId: String?
        let name: String
    }

    struct Rect: Codable {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
    }

    struct WindowInfo: Codable {
        let title: String
        let id: UInt32
        let bounds: Rect
    }

    struct Screenshot: Codable {
        let mime: String            // "image/jpeg" or "image/png"
        let dataBase64: String
    }

    let timestamp: String          // ISO8601 with fractional seconds
    let app: AppInfo
    let window: WindowInfo?        // optional if no window metadata available
    let typedTextChunk: String
    let screenshot: Screenshot?    // optional if permission not granted or capture failed
}

extension AnalysisPayload {
    static func make(
        typedText: String,
        frontAppName: String,
        frontBundleId: String?,
        snapshot: WindowSnapshot?
    ) -> AnalysisPayload {

        let ts = ISO8601DateFormatter.iso8601Fractional.string(from: Date())

        var windowInfo: WindowInfo? = nil
        var shot: Screenshot? = nil

        if let snap = snapshot {
            windowInfo = WindowInfo(
                title: snap.windowTitle,
                id: UInt32(snap.windowID),
                bounds: .init(
                    x: Int(snap.frame.origin.x),
                    y: Int(snap.frame.origin.y),
                    w: Int(snap.frame.size.width),
                    h: Int(snap.frame.size.height)
                )
            )

            // Prefer JPEG for smaller payloads; fall back to PNG if JPEG fails.
            if let data = snap.image.jpegData(compression: 0.7) {
                shot = Screenshot(mime: "image/jpeg", dataBase64: data.base64EncodedString())
            } else if let data = snap.image.pngData() {
                shot = Screenshot(mime: "image/png", dataBase64: data.base64EncodedString())
            }
        }

        return AnalysisPayload(
            timestamp: ts,
            app: .init(bundleId: frontBundleId, name: frontAppName),
            window: windowInfo,
            typedTextChunk: typedText,
            screenshot: shot
        )
    }
}

// MARK: - Helpers

extension ISO8601DateFormatter {
    static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func jpegData(compression: CGFloat) -> Data? {
        guard let tiffData = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }
}
