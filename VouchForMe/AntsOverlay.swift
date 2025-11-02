//
//  AntsOverlay.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//
//  Animated marching-ants underline overlay, one transparent panel per screen.

import AppKit
import QuartzCore

/// Manages one overlay per display. You feed it global (bottom-left) rects; it renders per-screen lines.
@MainActor
final class AntsOverlayManager {

    @MainActor
    private final class ScreenOverlay {
        let screen: NSScreen
        let panel: NSPanel
        let view: AntsView

        init(screen: NSScreen) {
            self.screen = screen

            // Fullscreen, transparent, non-activating, click-through panel
            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false, screen: screen)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = true

            let v = AntsView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.wantsLayer = true
            panel.contentView = v

            self.panel = panel
            self.view = v
        }

        func show()   { panel.orderFrontRegardless() }
        func hide()   { panel.orderOut(nil) }
        func updateSize() {
            panel.setFrame(screen.frame, display: true)
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
        }

        func setLocalRects(_ rects: [CGRect]) {
            view.setUnderlines(rects)
            if rects.isEmpty { hide() } else { show() }
        }
    }

    @MainActor
    private final class AntsView: NSView {
        private var lineLayers: [CAShapeLayer] = []
        private var displayScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

        override var isFlipped: Bool { false } // bottom-left coordinates

        func setUnderlines(_ rects: [CGRect]) {
            wantsLayer = true
            guard let root = layer else { return }

            // Ensure we have N layers
            if rects.count != lineLayers.count {
                // Rebuild
                root.sublayers?.forEach { $0.removeFromSuperlayer() }
                lineLayers.removeAll(keepingCapacity: false)
                for _ in rects {
                    let l = CAShapeLayer()
                    l.fillColor = NSColor.clear.cgColor
                    l.strokeColor = NSColor.systemOrange.cgColor
                    l.lineWidth = max(1, 1.5 * displayScale / 2)
                    l.lineDashPattern = [4, 3] as [NSNumber]
                    l.lineJoin = .miter
                    root.addSublayer(l)
                    lineLayers.append(l)

                    // Animate dash phase for "marching ants"
                    let anim = CABasicAnimation(keyPath: "lineDashPhase")
                    anim.fromValue = 0
                    anim.toValue = 7
                    anim.duration = 0.6
                    anim.repeatCount = .infinity
                    l.add(anim, forKey: "ants")
                }
            }

            // Update geometry
            for (i, r) in rects.enumerated() {
                guard i < lineLayers.count else { break }
                let y = r.minY + max(1, floor(min(3, r.height * 0.12))) // a few px above bottom
                let path = CGMutablePath()
                path.move(to: CGPoint(x: r.minX, y: y))
                path.addLine(to: CGPoint(x: r.maxX, y: y))
                lineLayers[i].path = path
            }
        }
    }

    // State
    private var overlays: [NSScreen: ScreenOverlay] = [:]

    init() {
        rebuildOverlays()
        // Track screen additions/removals & scale changes
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screensChanged() {
        rebuildOverlays()
    }

    private func rebuildOverlays() {
        // Hide and drop any overlays for screens that no longer exist
        let existing = Set(overlays.keys)
        let current  = Set(NSScreen.screens)
        for s in existing.subtracting(current) { overlays[s]?.hide(); overlays.removeValue(forKey: s) }
        // Create overlays for new screens
        for s in current.subtracting(existing) { overlays[s] = ScreenOverlay(screen: s) }
        // Resize existing to new frames
        for s in current { overlays[s]?.updateSize() }
    }

    /// Clears all underlines.
    func clear() {
        for (_, o) in overlays { o.setLocalRects([]) }
    }

    /// Sets global (bottom-left) rects; they will be split per-screen and drawn.
    func setGlobalUnderlines(_ rectsBL: [CGRect], locator: AXTextLocator) {
        guard !rectsBL.isEmpty else { clear(); return }
        var byScreen: [NSScreen: [CGRect]] = [:]
        for r in rectsBL {
            guard let s = locator.screenFor(r) else { continue }
            let local = locator.convertGlobalToScreenLocal(r, on: s)
            byScreen[s, default: []].append(local)
        }
        // Apply per-screen
        for (s, overlay) in overlays {
            overlay.setLocalRects(byScreen[s] ?? [])
        }
    }
}
