//
//  VouchForMeApp.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//

import SwiftUI
import AppKit

@main
struct VouchForMeApp: App {
    // We use an NSApplication delegate so we can set up an NSStatusItem cleanly.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window; LSUIElement hides Dock. Keep Settings empty.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()
    }
}
