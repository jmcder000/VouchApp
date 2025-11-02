//
//  UnderlineCoordinator.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


// UnderlineCoordinator.swift
// Orchestrates Accessibility observation & underlines based on OverlayModel verdicts.

import AppKit
import Combine
import ApplicationServices

@MainActor
final class UnderlineCoordinator {

    private let model: OverlayModel
    private let locator = AXTextLocator()
    private let ants = AntsOverlayManager()

    private var cancellables: Set<AnyCancellable> = []
    private var frontAppPID: pid_t?
    private var appObserver: AXObserver?
    private var elemObserver: AXObserver?
    private var observedElement: AXUIElement?

    // The currently-underlined chunk & resolved range (in last focused element’s text)
    private var activeChunk: String?
    private var activeRange: NSRange?

    init(model: OverlayModel) {
        self.model = model
    }

    func start() {
        // Ensure AX permission (prompt once if missing)
        guard locator.ensureTrusted(prompt: true) else { return }

        // React when items change (e.g., a correction arrives)
        model.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reevaluateFromModel() }
            .store(in: &cancellables)

        // Track frontmost app changes to re-attach observers
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let self else { return }
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.attachAppObserver(pid: app.processIdentifier)
                    self.attachFocusedElementObserver() // will update on first focus change
                    self.recomputeUnderlines()
                }
            }
        }

        // Attach to current frontmost app at startup
        if let app = NSWorkspace.shared.frontmostApplication {
            attachAppObserver(pid: app.processIdentifier)
        }
        attachFocusedElementObserver()
        recomputeUnderlines()
    }

    func shutdown() {
        ants.clear()
        activeChunk = nil
        activeRange = nil
        if let obs = appObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes) }
        if let obs = elemObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes) }
        appObserver = nil; elemObserver = nil; observedElement = nil
        NotificationCenter.default.removeObserver(self)
        cancellables.removeAll()
    }

    // MARK: Model → decision

    /// Look at the newest item; if there’s a correction, set it active; otherwise clear.
    private func reevaluateFromModel() {
        guard let item = model.items.first else { ants.clear(); activeChunk = nil; activeRange = nil; return }
        switch item.verdict {
        case .corrected:
            activeChunk = item.chunk
            // Range will be resolved on the next recompute
            recomputeUnderlines()
        default:
            // No correction → hide
            ants.clear(); activeChunk = nil; activeRange = nil
        }
    }

    // MARK: AX observing

    private func attachAppObserver(pid: pid_t) {
        guard frontAppPID != pid else { return }
        frontAppPID = pid

        // Tear down existing app observer
        if let obs = appObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            appObserver = nil
        }

        var obs: AXObserver?
        let err = AXObserverCreate(pid, { observer, element, notification, refcon in
            // AXObserverCallback parameter order: (observer, element, notification, refcon)
            guard let refcon else { return }
            let coordinator = Unmanaged<UnderlineCoordinator>.fromOpaque(refcon).takeUnretainedValue()
            // Hop to main actor before touching AppKit / @MainActor methods
            Task { @MainActor in
                if (notification as String) == (kAXFocusedUIElementChangedNotification as String) {
                    coordinator.attachFocusedElementObserver()
                    coordinator.recomputeUnderlines()
                }
            }
        }, &obs)
        guard err == .success, let observer = obs else { return }
        appObserver = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)

    }

    private func attachFocusedElementObserver() {
        // Remove previous element observer
        if let obs = elemObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            elemObserver = nil
            observedElement = nil
        }
        guard let el = locator.focusedElement() else { return }
        observedElement = el

        // Element-level observer
        var obs: AXObserver?
        // We need a PID for AXObserverCreate; derive from element's app
        var pid: pid_t = 0
        if AXUIElementGetPid(el, &pid) != .success { return }

        let err = AXObserverCreate(pid, { observer, element, notification, refcon in
            guard let refcon else { return }
            let coordinator = Unmanaged<UnderlineCoordinator>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                // Any text/layout change → recompute
                coordinator.recomputeUnderlines()
            }
        }, &obs)
        guard err == .success, let observer = obs else { return }
        elemObserver = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        // Watch relevant notifications on the focused element
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, el, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, el, kAXSelectedTextChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, el, kAXLayoutChangedNotification as CFString, refcon)

    }

    // MARK: Core recompute

    private func recomputeUnderlines() {
        guard let chunk = activeChunk,
              let elem = observedElement ?? locator.focusedElement(),
              let full = locator.copyStringValue(elem), !full.isEmpty else {
            ants.clear(); activeRange = nil; return
        }

        // Resolve the chunk's NSRange in the current field text
        let range: NSRange
        if let cached = activeRange {
            range = cached
        } else if let r = locator.normalizedBackMappedRange(of: chunk, in: full) {
            activeRange = r; range = r
        } else {
            ants.clear(); activeRange = nil; return
        }

        // Ask AX for per-character rects (top-left), merge to line segments → convert to bottom-left global
        let rectsTL = locator.axScreenRects(for: elem, range: range)
        guard !rectsTL.isEmpty else { ants.clear(); return }

        let rectsBL = rectsTL.map { locator.convertAXTopLeftToBottomLeft($0) }
        ants.setGlobalUnderlines(rectsBL, locator: locator)
    }
}
