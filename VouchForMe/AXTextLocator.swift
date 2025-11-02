//
//  AXTextLocator.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


// AXTextLocator.swift
// Maps Accessibility text ranges to screen rectangles and converts to per-screen overlay coords.

import AppKit
import ApplicationServices

/// Utilities for querying the focused text element and mapping string ranges to screen rects.
@MainActor
final class AXTextLocator {

    // MARK: Permission

    /// Returns true if the app is trusted for Accessibility (AX).
    func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Optionally triggers the system prompt to grant Accessibility.
    func ensureTrusted(prompt: Bool = false) -> Bool {
        if AXIsProcessTrusted() { return true }
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
            let opts: CFDictionary = [key: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    // MARK: Focused element & text

    /// Returns the focused accessibility element if any.
    func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var out: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &out)
        guard err == .success, let el = out else { return nil }
        return (el as! AXUIElement)
    }

    /// Copy the AXValue (string) for an element (if readable).
    func copyStringValue(_ elem: AXUIElement) -> String? {
        var out: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &out)
        guard err == .success, let str = out as? String else { return nil }
        return str
    }

    // MARK: Range → screen rects (top-left origin)

    /// Returns a list of screen-rects (top-left origin) for the given NSRange in the element's text.
    /// Implementation: query 1-char ranges and merge co-linear fragments (robust across wrapped lines).
    func axScreenRects(for elem: AXUIElement, range: NSRange) -> [CGRect] {
        let start = range.location
        let end   = range.location + range.length
        guard end > start else { return [] }

        var merged: [CGRect] = []
        var current: CGRect?
        let yTol: CGFloat = 1.5  // baseline tolerance in px

        for idx in start..<end {
            guard let r1 = axBoundsFor(elem: elem, cfRange: CFRange(location: idx, length: 1)) else { continue }

            if var run = current {
                // Same baseline? Merge horizontally.
                if abs(r1.minY - run.minY) <= yTol {
                    run = run.union(r1)
                    current = run
                } else {
                    merged.append(run)
                    current = r1
                }
            } else {
                current = r1
            }
        }
        if let run = current { merged.append(run) }
        return merged
    }

    /// Low-level: call kAXBoundsForRangeParameterizedAttribute
    private func axBoundsFor(elem: AXUIElement, cfRange: CFRange) -> CGRect? {
        var r = cfRange
        guard let rangeVal = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            elem,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeVal,
            &out
        )
        guard err == .success, let raw = out else { return nil }
        // Validate the CF runtime type before bridging.
        if CFGetTypeID(raw) == AXValueGetTypeID() {
            let ax = raw as! AXValue
            if AXValueGetType(ax) == .cgRect {
                var rect = CGRect.zero
                if AXValueGetValue(ax, .cgRect, &rect) { return rect }
            }
        }
        return nil
    }

    // MARK: Coordinate conversion

    /// Converts a top-left global (AX) rect into bottom-left global (AppKit) space.
    func convertAXTopLeftToBottomLeft(_ rectTL: CGRect) -> CGRect {
        let union = NSScreen.screens.reduce(NSRect.null) { NSUnionRect($0, $1.frame) }
        // union is in bottom-left coordinates. Its top edge is union.maxY.
        let flippedY = union.maxY - rectTL.origin.y - rectTL.size.height
        return CGRect(x: rectTL.origin.x, y: flippedY, width: rectTL.size.width, height: rectTL.size.height)
    }

    /// Convert global bottom-left rect to per-screen local rect (for a specific NSScreen).
    func convertGlobalToScreenLocal(_ rectBL: CGRect, on screen: NSScreen) -> CGRect {
        return rectBL.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    /// Heuristic: choose the screen whose frame overlaps the rect most.
    func screenFor(_ globalRectBL: CGRect) -> NSScreen? {
        var best: NSScreen?; var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let inter = s.frame.intersection(globalRectBL)
            let a = inter.width * inter.height
            if a > bestArea { best = s; bestArea = a }
        }
        return best ?? NSScreen.main
    }

    // MARK: Helpers: map a "chunk" back into the field's value (normalized whitespace)

    /// Collapses whitespace in both haystack and needle, finds last occurrence, and returns original-space NSRange.
    func normalizedBackMappedRange(of needle: String, in haystack: String) -> NSRange? {
        let (normHay, map) = collapseWhitespaceWithMap(haystack)
        let normNeedle     = collapseWhitespace(needle)

        let nsNormHay = normHay as NSString
        let r = nsNormHay.range(of: normNeedle, options: [.backwards])
        guard r.location != NSNotFound else { return nil }

        let startNorm = r.location
        let endNorm   = r.location + r.length

        let nsHay = haystack as NSString
        let startOrig = startNorm < map.count ? map[startNorm] : nsHay.length
        let endOrig   = endNorm   < map.count ? map[endNorm]   : nsHay.length

        let loc = min(max(0, startOrig), nsHay.length)
        let len = max(0, endOrig - startOrig)
        return NSRange(location: loc, length: len)
    }

    private func collapseWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func collapseWhitespaceWithMap(_ s: String) -> (String, [Int]) {
        let ns = s as NSString
        let len = ns.length
        var out: [unichar] = []; out.reserveCapacity(len)
        var map: [Int] = [];     map.reserveCapacity(len)

        var i = 0
        var lastWasWS = false
        let ws = CharacterSet.whitespacesAndNewlines as NSCharacterSet

        while i < len {
            let ch = ns.character(at: i)
            let isWS = ws.characterIsMember(ch)
            if isWS {
                if !lastWasWS {
                    out.append(32) // space
                    map.append(i)
                    lastWasWS = true
                }
            } else {
                out.append(ch)
                map.append(i)
                lastWasWS = false
            }
            i += 1
        }
        let norm = String(utf16CodeUnits: out, count: out.count)
        return (norm, map)
    }
}
