//
//  ScreenCaptureService.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics

// Represents a captured snapshot of the frontmost window
struct WindowSnapshot {
    let image: NSImage
    let appName: String
    let bundleID: String?
    let windowTitle: String
    let windowID: CGWindowID
    let frame: CGRect
    let processID: pid_t
}



enum ScreenCaptureError: Error, LocalizedError {
    case permissionDenied
    case noFrontApp
    case noEligibleWindow
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen & System Audio Recording permission not granted."
        case .noFrontApp:       return "Couldn’t resolve frontmost application."
        case .noEligibleWindow: return "No on‑screen window found for the frontmost application."
        case .captureFailed:    return "Screenshot capture failed."
        }
    }
}

/// Modern, one‑shot window screenshot service using ScreenCaptureKit's Screenshot API.
/// Requires the user to have granted Screen & System Audio Recording.
final class ScreenCaptureService {
    /// Captures a single still image of the frontmost application's topmost on‑screen window.
    /// Returns nil only if there is simply no eligible window at this instant.
    @MainActor
    func captureFrontmostWindow() async throws -> WindowSnapshot? {
        // Ensure permission was granted (don’t trigger the prompt here; UI should do that).
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        guard let front = NSWorkspace.shared.frontmostApplication else {
            throw ScreenCaptureError.noFrontApp
        }
        let pid = front.processIdentifier

        // Fetch shareable content (windows/apps/displays).
        let content = try await SCShareableContent.current

        // Pick the frontmost app's largest on‑screen window as a heuristic for the "active" window.
        let candidates = content.windows.filter { win in
            guard let app = win.owningApplication else { return false }
            return app.processID == pid && win.isOnScreen
        }
        guard let window = candidates.max(by: { $0.frame.area < $1.frame.area }) else {
            return nil
        }

        // Create a content filter that isolates only this one window (desktop‑independent).
        let filter = SCContentFilter(desktopIndependentWindow: window)

        // Use SCStreamConfiguration for broad SDK compatibility (Sonoma+).
        // Set output size to the window’s pixel dimensions to avoid downscaling/blur.
        let config = SCStreamConfiguration()
        let scale = Self.estimateScale(for: window.frame)
        config.captureResolution = .best
        config.width  = Int(window.frame.width  * scale)
        config.height = Int(window.frame.height * scale)

        // Perform the capture (CGImage path avoids CMSampleBuffer plumbing).
        let cgImage: CGImage = try await withCheckedThrowingContinuation { cont in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let image = image {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: ScreenCaptureError.captureFailed)
                }
            }
        }

        let size   = NSSize(width: cgImage.width, height: cgImage.height)
        let nsImage = NSImage(cgImage: cgImage, size: size)
        
        // Prefer metadata from the actual owning application of this window.
        let owner = window.owningApplication
        let appName  = owner?.applicationName ?? front.localizedName ?? (front.bundleIdentifier ?? "App")
        let bundleID = owner?.bundleIdentifier ?? front.bundleIdentifier
        let finalPid: pid_t = owner?.processID ?? front.processIdentifier

        return WindowSnapshot(
            image: nsImage,
            appName: appName,
            bundleID: bundleID,
            windowTitle: window.title ?? "",
            windowID: CGWindowID(window.windowID),
            frame: window.frame,
            processID: finalPid
        )
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

private extension ScreenCaptureService {
    /// Heuristic: find the screen that overlaps the window the most and use its backing scale.
    static func estimateScale(for windowRect: CGRect) -> CGFloat {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main?.backingScaleFactor ?? 2.0 }
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in screens {
            let inter = s.frame.intersection(windowRect)
            let area = inter.width * inter.height
            if area > bestArea { best = s; bestArea = area }
        }
        return best?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }
}
