//
//  InputPermissionManager.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


import Foundation
import AppKit
import IOKit.hid

/// Manages Input Monitoring permissions required for global keystroke capture
final class InputPermissionManager {

    enum Status {
        case granted
        case denied
        case unknown
    }

    // MARK: - Permission Status

    /// Returns the tri-state Input Monitoring status.
    func inputMonitoringStatus() -> Status {
        if #available(macOS 10.15, *) {
            let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            switch access {
            case kIOHIDAccessTypeGranted:
                return .granted
            case kIOHIDAccessTypeDenied:
                return .denied
            case kIOHIDAccessTypeUnknown:
                fallthrough
            default:
                return .unknown
            }
        } else {
            // Pre-Catalina had no TCC gate for input monitoring.
            return .granted
        }
    }

    /// Convenience Bool if you only need a quick check.
    func isInputMonitoringGranted() -> Bool {
        return inputMonitoringStatus() == .granted
    }

    // MARK: - Permission Request

    /// Request Input Monitoring permission.
    ///
    /// NOTE: The return value indicates whether the *request was posted*,
    /// not whether the user has already granted permission.
    /// After calling this, guide the user to System Settings and then re-check status.
    @discardableResult
    func requestInputMonitoring() -> Bool {
        if #available(macOS 10.15, *) {
            return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        } else {
            return true
        }
    }

    // MARK: - User Guidance

    /// Opens System Settings to the Input Monitoring pane so the user can enable the toggle.
    func openSystemPreferences() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Messaging Helpers

    var permissionExplanation: String {
        """
        This app needs Input Monitoring permission to capture your typing across applications.

        This allows the app to:
        • Detect when you type text in any application
        • Analyze your text for factual accuracy
        • Provide real-time feedback

        Your privacy:
        • Capture only works when you explicitly enable it
        • Password fields and other secure inputs are protected by macOS
        • You can pause or disable capture at any time
        """
    }

    var statusMessage: String {
        switch inputMonitoringStatus() {
        case .granted: return "✓ Input Monitoring: Granted"
        case .denied:  return "✗ Input Monitoring: Not Granted"
        case .unknown: return "◔ Input Monitoring: Not Determined"
        }
    }
}
