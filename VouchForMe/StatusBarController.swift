//
//  StatusBarController.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


import AppKit
import SwiftUI
import CoreGraphics


@MainActor
final class StatusBarController: NSObject, KeyCaptureServiceDelegate {
    private let statusItem: NSStatusItem
    private var permissionsWindow: NSWindow?
    private var logWindow: NSWindow?

    private let captureService = KeyCaptureService()
    private let logModel = LogModel()
    private let screenCapture = ScreenCaptureService()   // NEW
    private let queue = LocalQueue()
    private let client = AnalysisClient()               // NEW: Phase 4.5 HTTP client
    private var sender: OutboxSender?
    private let overlayModel = OverlayModel()
    private var overlayController: OverlayController?
    private let swapper = TextSwapService()


    private var isCapturing = false {
        didSet {
            rebuildMenu();updateStatusIcon()
            overlayController?.toggle(isCapturing)   // <-- show when ON, hide when OFF
        }
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        overlayController = OverlayController(
            model: overlayModel,
            onReplace: { [weak self] item in
                guard let self else { return }
                guard let suggestion = item.replacement?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !suggestion.isEmpty else {
                    self.logModel.append(.queueInfo("No replacement available for this item."))
                    return
                }
                Task { @MainActor in
                    if !self.swapper.ensureAccessibility(prompt: true) {
                        self.logModel.append(.queueInfo("Accessibility permission required to replace text. Enable in System Settings → Privacy & Security → Accessibility."))
                        return
                    }
                    let ok = await self.swapper.replaceLastOccurrence(original: item.chunk, with: suggestion)
                    self.logModel.append(.queueInfo(ok ? "✓ Replaced text in the active field." :
                                                         "Replace failed (control may block selection; try selecting manually)."))
                }
            }
        )
        captureService.delegate = self
        updateStatusIcon()
        rebuildMenu()
        // Start background sender loop
        let s = OutboxSender(queue: queue, client: client, logModel: logModel, overlay: overlayModel)
        s.start()
        sender = s
    }

    private func updateStatusIcon() {
        // Simple visual: different glyph when capturing
        statusItem.button?.title = isCapturing ? "▶︎" : "⬣"
        statusItem.button?.toolTip = isCapturing ? "Capture ON" : "Capture OFF"
    }
    
    func keyCaptureServiceDidAutoStop(_ service: KeyCaptureService) {
        // Service already stopped itself; reflect in UI
        isCapturing = false
        // Optional: brief notification or badge could go here
    }


    private func rebuildMenu() {
        let menu = NSMenu()

        let startTitle = isCapturing ? "Stop Capture" : "Start Capture"
        let startItem = NSMenuItem(title: startTitle, action: #selector(toggleCapture), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)

        menu.addItem(NSMenuItem.separator())

        let permItem = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: ",")
        permItem.target = self
        menu.addItem(permItem)

        let logItem = NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)
        
        let sendNowItem = NSMenuItem(title: "Send Queue Now", action: #selector(sendQueueNow), keyEquivalent: "")
        sendNowItem.target = self
        menu.addItem(sendNowItem)
        
        let clearItem = NSMenuItem(title: "Clear Queue…", action: #selector(clearQueue), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }
    
    

    // MARK: - Actions

    @objc private func toggleCapture() {
        if isCapturing {
            captureService.stopCapture()
            isCapturing = false
        } else {
            let pm = InputPermissionManager()
            if !pm.isInputMonitoringGranted() {
                let alert = NSAlert()
                alert.messageText = "Input Monitoring Required"
                alert.informativeText = "Please grant Input Monitoring in System Settings → Privacy & Security → Input Monitoring."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    pm.requestInputMonitoring()
                    pm.openSystemPreferences()
                }
                return
            }

            // Optional: see logs quickly
            captureService.debugMinChunkLengthForTesting = 3

            captureService.startCapture { [weak self] success in
                guard let self else { return }
                self.isCapturing = success
                if !success {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t Start Capture"
                    alert.informativeText = "Check Input Monitoring permission and ensure App Sandbox is disabled."
                    alert.runModal()
                }
            }
        }
    }
    
    @objc private func clearQueue() {
        let alert = NSAlert()
        alert.messageText = "Clear All Queued Payloads?"
        alert.informativeText = "This will remove all pending payload files from disk. This cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
    
        // Pause sender to avoid races, clear, then resume.
        sender?.stop()
        queue.clearAll { [weak self] removed in
            guard let self else { return }
            self.logModel.append(.queueInfo("Cleared queue (\(removed) item(s))."))
            self.sender?.start()
        }
    }


    @objc private func openPermissions() {
        if permissionsWindow == nil {
            let view = PermissionsView()
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.setContentSize(NSSize(width: 520, height: 380))
            window.title = "Permissions"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            permissionsWindow = window
        }
        permissionsWindow?.center()
        permissionsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showLog() {
        if logWindow == nil {
            let hosting = NSHostingController(rootView: LogView(model: logModel))
            let window = NSWindow(contentViewController: hosting)
            window.setContentSize(NSSize(width: 600, height: 420))
            window.title = "Log"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            logWindow = window
        }
        logWindow?.center()
        logWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        captureService.shutdown()
        sender?.stop()
        NSApp.terminate(nil)
    }
    // MARK: - KeyCaptureServiceDelegate

    func keyCaptureService(_ service: KeyCaptureService, didCaptureChunk text: String) {
        // Log immediately
        logModel.append(.chunk(text))

        // Run the whole flow on the MainActor so UI + ScreenCaptureKit (@MainActor) are happy
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Active window/app (header for overlay)
            let front = NSWorkspace.shared.frontmostApplication
            let frontName = front?.localizedName ?? (front?.bundleIdentifier ?? "App")
            let frontBundle = front?.bundleIdentifier

            var snapshot: WindowSnapshot? = nil
            if CGPreflightScreenCaptureAccess() {
                do {
                    // ScreenCaptureService.captureFrontmostWindow() is @MainActor
                    snapshot = try await self.screenCapture.captureFrontmostWindow()
                } catch {
                    self.logModel.append(.queueInfo("Window capture error: \(error.localizedDescription)"))
                }
            }

            // Keep header up to date
            self.overlayModel.setActiveWindow(
                appName: frontName,
                windowTitle: snapshot?.windowTitle ?? ""
            )

            // Build payload
            let payload = AnalysisPayload.make(
                typedText: text,
                frontAppName: frontName,
                frontBundleId: frontBundle,
                snapshot: snapshot
            )

            // Enqueue and update overlay with a pending card (id = queued filename)
            self.queue.enqueue(payload) { [weak self] result in
                guard let self else { return }

                let preview = PayloadPreview(
                    appName: payload.app.name,
                    windowTitle: payload.window?.title ?? "",
                    text: payload.typedTextChunk,
                    image: snapshot?.image
                )
                self.logModel.append(.payload(preview))
                if result.droppedCount > 0 {
                    self.logModel.append(.queueInfo("Dropped \(result.droppedCount) oldest payload(s) (queue full)."))
                }

                // Show "Checking…" immediately for this chunk
                let id = result.url.lastPathComponent
                self.overlayModel.upsertPending(
                    id: id,
                    appName: payload.app.name,
                    windowTitle: payload.window?.title ?? "",
                    chunk: payload.typedTextChunk
                )

                self.overlayController?.reposition() // keep overlay tucked in TR corner

            }
        }
    }


    func keyCaptureService(_ service: KeyCaptureService, secureInputStatusChanged isSecure: Bool) {
        logModel.append(.secure(isSecure))
    }
    
    // Manual "Send Queue Now" menu action
    @objc private func sendQueueNow() {
        Task { [weak self] in
            guard let self else { return }
            // Pause background loop to avoid races with manual send
            self.sender?.stop()
            let sent = await self.sender?.processOnce(limit: 10) ?? 0
            self.sender?.start()
            self.logModel.append(.queueInfo("Manual send: \(sent) item(s)"))
        }
    }
}
