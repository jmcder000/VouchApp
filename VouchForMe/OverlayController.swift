//
//  OverlayController.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private let model: OverlayModel
    private var hosting: NSHostingController<OverlayView>!
    private var panel: NSPanel!

    init(model: OverlayModel) {
        self.model = model
        configurePanel()
    }

    private func configurePanel() {
        hosting = NSHostingController(rootView: OverlayView(model: model, onClose: { [weak self] in
            self?.hide()
        }))

        // Non-activating, floating, transparent panel
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                        styleMask: [.nonactivatingPanel, .hudWindow],
                        backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentViewController = hosting
    }

    func show() {
        guard !panel.isVisible else { reposition(); return }
        panel.orderFrontRegardless()
        reposition()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle(_ on: Bool) {
        on ? show() : hide()
    }

    /// Position top-right with a safe inset; re-evaluate after content changes.
    func reposition() {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 18
        hosting.view.layoutSubtreeIfNeeded()
        let fit = hosting.view.fittingSize
        let width = max(380, min(460, fit.width.rounded(.up)))
        let height = max(140, fit.height.rounded(.up))

        var frame = NSRect(
            x: screen.visibleFrame.maxX - width - margin,
            y: screen.visibleFrame.maxY - height - margin,
            width: width, height: height
        )
        panel.setFrame(frame, display: true, animate: false)
    }
}
