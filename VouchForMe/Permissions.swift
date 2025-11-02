//
//  Permissions.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//

import SwiftUI
import AppKit
import CoreGraphics
import IOKit.hid // If this fails on your setup, try: import IOKit

// MARK: - Permission model

enum PermissionStatus: String {
    case granted, denied, unknown
}

struct PermissionRow: View {
    let title: String
    let status: PermissionStatus
    let description: String
    let onRequest: (() -> Void)?
    let onOpenSettings: (() -> Void)?
    let onRecheck: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusDot
                Text(title).font(.headline)
                Spacer()
                Button("Re‑check") { onRecheck?() }.keyboardShortcut("r")
            }
            Text(description).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if let onRequest {
                    Button("Request Now") { onRequest() }
                }
                if let onOpenSettings {
                    Button("Open Settings…") { onOpenSettings() }
                }
                Spacer()
                Text("Status: \(status.rawValue.capitalized)")
                    .font(.subheadline)
                    .foregroundColor(color(for: status))
            }
            Divider()
        }
        .padding(.vertical, 6)
    }

    private var statusDot: some View {
        Circle()
            .frame(width: 10, height: 10)
            .foregroundColor(color(for: status))
    }

    private func color(for status: PermissionStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied:  return .red
        case .unknown: return .orange
        }
    }
}

// MARK: - Permission helpers

final class PermissionManager: ObservableObject {
    @Published var inputMonitoring: PermissionStatus = .unknown
    @Published var screenRecording: PermissionStatus = .unknown
    @Published var accessibility: PermissionStatus = .unknown
    
    init() {
        refreshAll()
    }

    func refreshAll() {
        inputMonitoring = checkInputMonitoring()
        screenRecording = checkScreenRecording()
        accessibility    = checkAccessibility()
    }

    // === Input Monitoring ===
    func checkInputMonitoring() -> PermissionStatus {
        if #available(macOS 10.15, *) {
            let result = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            switch result.rawValue {
            case kIOHIDAccessTypeGranted.rawValue:
                return .granted
            case kIOHIDAccessTypeDenied.rawValue:
                return .denied
            default:
                return .unknown
            }
        } else {
            return .granted // pre‑Catalina: no TCC gate
        }
    }

    func requestInputMonitoring() {
        if #available(macOS 10.15, *) {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            // This adds your app to the list and surfaces the system prompt.
            // The user must then enable it in System Settings.
        }
    }

    func openInputMonitoringPane() {
        openPrivacyPane(anchor: "Privacy_ListenEvent")
    }

    // === Screen & System Audio Recording ===
    func checkScreenRecording() -> PermissionStatus {
        // `CGPreflightScreenCaptureAccess` returns true when permitted.
        let granted = CGPreflightScreenCaptureAccess()
        return granted ? .granted : .denied
    }

    @discardableResult
    func requestScreenRecording() -> Bool {
        // This displays the system prompt if applicable.
        return CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingPane() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }
    
    // === Accessibility (NEW) ===
    func checkAccessibility() -> PermissionStatus {
        return AXIsProcessTrusted() ? .granted : .denied
    }
    
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options: CFDictionary = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    
    func openAccessibilityPane() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    // === Utilities ===
    private func openPrivacyPane(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - SwiftUI view

struct PermissionsView: View {
    @StateObject private var pm = PermissionManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Permissions").font(.title2).padding(.bottom, 4)
            Text("To function, the app needs access to:\n• Input Monitoring (to observe your keystrokes across apps when you turn capture ON)\n• Screen & System Audio Recording (to snapshot the active window for context)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            PermissionRow(
                title: "Input Monitoring",
                status: pm.inputMonitoring,
                description: "Allows this app to monitor your keyboard input even while using other apps. macOS shows an explicit consent prompt and you can revoke this in System Settings.",
                onRequest: { pm.requestInputMonitoring() },
                onOpenSettings: { pm.openInputMonitoringPane() },
                onRecheck: { pm.refreshAll() }
            )

            PermissionRow(
                title: "Screen & System Audio Recording",
                status: pm.screenRecording,
                description: "Allows this app to capture the contents of your screen (we’ll only snapshot the frontmost window). You can enable/disable this in System Settings.",
                onRequest: { _ = pm.requestScreenRecording() },
                onOpenSettings: { pm.openScreenRecordingPane() },
                onRecheck: { pm.refreshAll() }
            )
            
            PermissionRow(  // NEW
                title: "Accessibility",
                status: pm.accessibility,
                description: "Allows this app to read text positions in other apps’ text fields to draw guidance overlays (no injection/modification).",
                onRequest: { pm.requestAccessibility() },
                onOpenSettings: { pm.openAccessibilityPane() },
                onRecheck: { pm.refreshAll() }
            )


            Spacer()

            HStack {
                Image(systemName: "lock.shield")
                Text("You’re always in control. Permissions can be changed any time in System Settings → Privacy & Security.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
    }
}
