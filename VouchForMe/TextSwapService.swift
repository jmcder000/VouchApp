//
//  TextSwapService.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


//  TextSwapService.swift
//  VouchForMe
//
//  Replaces the last occurrence of a chunk in the focused text element using
//  Accessibility selection + synthetic typing. Falls back gracefully.

import AppKit
import ApplicationServices
import Carbon

@MainActor
final class TextSwapService {

    // MARK: - Public API

    /// Ensure we have Accessibility permission. If `prompt == true`, shows the system prompt once.
    @discardableResult
    func ensureAccessibility(prompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() { return true }
        if prompt {
            // kAXTrustedCheckOptionPrompt is Unmanaged<CFString> on some SDKs
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
            let options: CFDictionary = [key: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    /// Replace the last occurrence of `original` with `replacement` in the currently focused text element.
    /// Returns true on success.
    func replaceLastOccurrence(original: String, with replacement: String) async -> Bool {
        guard AXIsProcessTrusted() else { return false }

        guard let elem = focusedElement() else { return false }

        // 1) Read field value
        guard let fieldValue = copyStringAttribute(elem, kAXValueAttribute as CFString) else {
            return false
        }
        return await replaceInValue(fieldValue, in: elem, original: original, replacement: replacement)
    }

    // MARK: - Internals

    private func replaceInValue(_ value: String, in elem: AXUIElement, original: String, replacement: String) async -> Bool {
        // 2) Find last occurrence using normalized mapping
        guard let targetRange = normalizedBackMappedRange(of: original, in: value) else {
            return false
        }

        // 3) Try to set selection range to the target
        if !setSelectedTextRange(elem, targetRange) {
            // As a coarse fallback (simple text fields): set the whole value (keeps selection logic minimal)
            let ns = value as NSString
            let newValue = ns.replacingCharacters(in: targetRange, with: replacement)
            return setStringAttribute(elem, kAXValueAttribute as CFString, newValue)
        }

        // 4) Type the replacement (replaces selected text)
        typeUnicodeString(replacement)
        return true
    }

    // MARK: - AX helpers

    private func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var out: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &out)
        guard err == .success, let elem = out else { return nil }
        return (elem as! AXUIElement)
    }

    private func copyStringAttribute(_ elem: AXUIElement, _ attr: CFString) -> String? {
        var out: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(elem, attr, &out)
        guard err == .success, let str = out as? String else { return nil }
        return str
    }

    private func setStringAttribute(_ elem: AXUIElement, _ attr: CFString, _ value: String) -> Bool {
        let cf = value as CFTypeRef
        return AXUIElementSetAttributeValue(elem, attr, cf) == .success
    }

    private func setSelectedTextRange(_ elem: AXUIElement, _ nsRange: NSRange) -> Bool {
        var settable: DarwinBoolean = false
        _ = AXUIElementIsAttributeSettable(elem, kAXSelectedTextRangeAttribute as CFString, &settable)
        guard settable.boolValue else { return false }

        var cf = CFRange(location: nsRange.location, length: nsRange.length)
        guard let ax = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, ax) == .success
    }

    // MARK: - Synthetic typing

    private func typeUnicodeString(_ text: String) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
        text.utf16.withContiguousStorageIfAvailable { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        } ?? {
            let arr = Array(text.utf16)
            arr.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
        }()
        down.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
        up.post(tap: .cgSessionEventTap)
    }

    // MARK: - Normalized search with back-mapping

    /// Find the last occurrence of `needle` (normalized whitespace like your chunk) in `haystack`,
    /// mapping the match back to an `NSRange` in the original (non-normalized) `haystack`.
    private func normalizedBackMappedRange(of needle: String, in haystack: String) -> NSRange? {
        let (normHay, map) = collapseWhitespaceWithMap(haystack)
        let normNeedle     = collapseWhitespace(needle)

        let nsNormHay = normHay as NSString
        let r = nsNormHay.range(of: normNeedle, options: [.backwards])
        guard r.location != NSNotFound else { return nil }

        // Map normalized indices back to original UTF16 offsets
        let startNorm = r.location
        let endNorm   = r.location + r.length

        let startOrig = startNorm < map.count ? map[startNorm] : (haystack as NSString).length
        let endOrig   = endNorm   < map.count ? map[endNorm]   : (haystack as NSString).length

        let loc = min(max(0, startOrig), (haystack as NSString).length)
        let len = max(0, endOrig - startOrig)
        return NSRange(location: loc, length: len)
    }

    private func collapseWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Returns (normalizedString, map) where `map[normIndex] = original UTF16 index` for that character.
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
