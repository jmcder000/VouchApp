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
        print("[Swap] ensureAccessibility(prompt:\(prompt))  trusted=\(AXIsProcessTrusted())")
        if AXIsProcessTrusted() { return true }
        if prompt {
            // kAXTrustedCheckOptionPrompt is Unmanaged<CFString> on some SDKs
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
            let options: CFDictionary = [key: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        print("[Swap] after prompt  trusted=\(AXIsProcessTrusted())")
        return AXIsProcessTrusted()
    }

    /// Replace the last occurrence of `original` with `replacement` in the currently focused text element.
    /// Returns true on success.
    func replaceLastOccurrence(original: String, with replacement: String) async -> Bool {
        print("[Swap] replaceLastOccurrence()  original='\(short(original))'  replacement='\(short(replacement))'")
        print("[Swap] AX trusted? \(AXIsProcessTrusted())")

        guard AXIsProcessTrusted() else { return false }

        guard let focused = focusedElement() else {
            print("[Swap] focusedElement() == nil")
            return false
        }
        print("[Swap] focused: \(describe(elem: focused))")

        guard let elem = resolveTextContainer(start: focused) ?? resolveViaWindowAndAppFallback(from: focused) else {
            print("[Swap] resolveTextContainer: could not find a text-capable element (down/up/window/app)")
            return false
        }
        if elem as CFTypeRef === focused as CFTypeRef {
            print("[Swap] text container == focused")
        } else {
            print("[Swap] text container resolved: \(describe(elem: elem))")
        }

        
        // 1) Read full/visible field text (kAXValue, kAXNumberOfCharacters, or kAXVisibleCharacterRange)
        guard let (fieldValue, _, base) = copyFullText(from: elem) else {
            print("[Swap] copyFullText() failed (no kAXValue and parameterized text failed)")
            return false
        }
        print("[Swap] fullText length = \((fieldValue as NSString).length)  baseOffset=\(base)")

        return await replaceInValue(fieldValue, in: elem, baseOffset: base, original: original, replacement: replacement)  }

    // MARK: - Internals

    private func replaceInValue(_ value: String, in elem: AXUIElement, baseOffset: Int, original: String, replacement: String) async -> Bool {
        // 2) Find last occurrence using normalized mapping
        guard let targetRange = normalizedBackMappedRange(of: original, in: value) else {
            print("[Swap] normalizedBackMappedRange() failed — couldn't locate chunk in field")
            return false
        }
        let absRange = NSRange(location: baseOffset + targetRange.location, length: targetRange.length)
        print("[Swap] targetRange (local) = \(targetRange.location)..<\(targetRange.location+targetRange.length)  abs=\(absRange.location)..<\(absRange.location+absRange.length)")
        
        // 2.5) Make sure the owning application is on top (keystrokes go to it)
        print("[Swap] raising owning application…")
        raiseOwningApplication(of: elem)
        
        // 3) Try to set selection range to the target (character-based)

        // 3) Try to set selection range to the target
        print("[Swap] setSelectedTextRange() attempting…")
        if !setSelectedTextRange(elem, absRange) {
            print("[Swap] setSelectedTextRange() returned false, trying kAXValue replacement fallback")
            // As a coarse fallback (simple text fields): set the whole value (keeps selection logic minimal)
            let ns = value as NSString
            let newValue = ns.replacingCharacters(in: targetRange, with: replacement)
            let ok = setStringAttribute(elem, kAXValueAttribute as CFString, newValue)
            print("[Swap] kAXValueAttribute set = \(ok)")
            return ok
        }
        print("[Swap] selection set OK — typing replacement")

        // 4) Insert replacement. Prefer typing; verify; fall back to paste if needed.
        typeUnicodeString(replacement)
        
        // Briefly yield so the target app can process the event before we verify
        try? await Task.sleep(nanoseconds: 60_000_000) // 60ms
        
        if verifyReplacement(in: elem, at: absRange.location, expected: replacement) {
            return true
        }
        
        // Fallback: pasteboard + Paste (attempt plain-text chord first, then Cmd+V)
        await pasteReplacement(replacement, preferPlain: true)
        
        // Optional verification again (best-effort)
        try? await Task.sleep(nanoseconds: 60_000_000)
        let ok = verifyReplacement(in: elem, at: absRange.location, expected: replacement)
        print("[Swap] verifyReplacement() after paste = \(ok)")
        return true
    }

    // MARK: - AX helpers
    
    /// Find a text-capable element starting at `start`:
    /// 1) If `start` itself is text-capable, return it
    /// 2) Breadth-first search into descendants (bounded)
    /// 3) Fall back to walking up parents (legacy)
    private func resolveTextContainer(start: AXUIElement) -> AXUIElement? {
        if isTextCapable(start) {
            print("[Swap] resolve: start is text-capable")
            return start
        }
        if let down = findTextContainerDown(start: start, maxDepth: 6, maxNodes: 600) {
            print("[Swap] resolve: found descendant text-capable")
            return down
        }
        if let up = findTextContainer(start: start) {
            print("[Swap] resolve: found ancestor text-capable")
            return up
        }
        return nil
    }
    
    /// Quick predicate: does this AX element plausibly back editable/readable text?
    /// Be strict: scrollbars/sliders have kAXValue too (numeric), which we must *not* treat as text.
    private func isTextCapable(_ e: AXUIElement) -> Bool {
        // 1) Role-based whitelist (most robust and fast)
        if let r = role(of: e), ["AXTextArea","AXTextField","AXWebArea","AXText","AXStaticText"].contains(r) {
            return true
        }
        // 2) Character-count support is a strong indicator for rich editors
        if supportsAttribute(e, kAXNumberOfCharactersAttribute as CFString) {
            return true
        }
        
        // 2.5) Selection/insertion support is also a strong indicator (rich editors)
        if supportsAttribute(e, kAXSelectedTextRangeAttribute as CFString) ||
           supportsAttribute(e, kAXSelectedTextAttribute as CFString) {
            return true
        }
        // 3) kAXValue counts only if it's an actual String (not NSNumber/Double/etc)
        var out: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &out) == .success,
           out is String {
            return true
        }
        return false
    }
    
    /// Breadth‑first search DOWN the tree for a text-capable element (Pages/Web editors).
    private func findTextContainerDown(start: AXUIElement, maxDepth: Int, maxNodes: Int) -> AXUIElement? {
        struct Node { let elem: AXUIElement; let depth: Int }
        var queue: [Node] = [Node(elem: start, depth: 0)]
        var seen = Set<UnsafeMutableRawPointer>()
        var visited = 0
    
        func id(_ e: AXUIElement) -> UnsafeMutableRawPointer {
            Unmanaged.passUnretained(e).toOpaque()
        }
    
        while !queue.isEmpty {
            var node = queue.removeFirst()
            let eid = id(node.elem)
            if seen.contains(eid) { continue }
            seen.insert(eid)
            visited += 1
            if visited > maxNodes { print("[Swap] BFS cap hit at \(visited) nodes"); break }
    
            if node.depth > 0 && isTextCapable(node.elem) {
                print("[Swap] BFS hit text-capable at depth \(node.depth): \(describe(elem: node.elem))")
                return node.elem
            }
            if node.depth >= maxDepth { continue }
    
            let kids = children(of: node.elem)
            if !kids.isEmpty {
                let roles = kids.compactMap { role(of: $0) }
                print("[Swap] BFS children of \(short(describe(elem: node.elem), max: 28)) → \(kids.count)  roles=\(roles.joined(separator: ","))")
            } else {
                print("[Swap] BFS children of \(short(describe(elem: node.elem), max: 28)) → 0")
            }
            // Small heuristic: scan likely text roles first
            let preferredRoles: Set<String> = ["AXTextArea","AXTextField","AXWebArea","AXText"]
            let prioritized = kids.sorted { (a, b) -> Bool in
                (role(of: a).map { preferredRoles.contains($0) } ?? false) &&
                !(role(of: b).map { preferredRoles.contains($0) } ?? false)
            }
            for c in prioritized {
                queue.append(Node(elem: c, depth: node.depth + 1))
            }
        }
        print("[Swap] BFS down found nothing (visited=\(visited))")
        return nil
    }
    
    /// Children helper: try common containers in order
    private func children(of elem: AXUIElement) -> [AXUIElement] {
        func readArray(_ attr: CFString) -> [AXUIElement] {
            var out: CFTypeRef?
            guard AXUIElementCopyAttributeValue(elem, attr, &out) == .success else { return [] }
            return (out as? [AXUIElement]) ?? []
        }
        let a = readArray(kAXChildrenAttribute as CFString)
        if !a.isEmpty { return a }
        let b = readArray(kAXVisibleChildrenAttribute as CFString)
        if !b.isEmpty { return b }
        let c = readArray(kAXContentsAttribute as CFString)
        if !c.isEmpty { return c }
        return []
    }
    
    /// Role helper (for logging/priority)
    private func role(of elem: AXUIElement) -> String? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &out) == .success,
              let s = out as? String else { return nil }
        return s
    }

    private func findTextContainer(start: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = start
        while let e = current {
            let hasValue = supportsAttribute(e, kAXValueAttribute as CFString)
            let hasNChars = supportsAttribute(e, kAXNumberOfCharactersAttribute as CFString)
            print("[Swap] walk: \(describe(elem: e))  value:\(hasValue)  nChars:\(hasNChars)")
            if hasValue || hasNChars {
                return e
            }
            current = parent(of: e)
        }
        return nil
    }
    
    private func parent(of elem: AXUIElement) -> AXUIElement? {
        var out: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(elem, kAXParentAttribute as CFString, &out)
        guard err == .success, let p = out else { return nil }
        return (p as! AXUIElement)
    }
    
    private func supportsAttribute(_ elem: AXUIElement, _ attr: CFString) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(elem, &names) == .success,
              let list = names as? [String] else { return false }
        return list.contains(attr as String)
    }

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
    
    private func copyFullText(from elem: AXUIElement) -> (String, Int, Int)? {
        if let s = copyStringAttribute(elem, kAXValueAttribute as CFString) {
            print("[Swap] copyFullText: using kAXValue (len=\((s as NSString).length))")
            return (s, (s as NSString).length, 0)
        }
        // Fallback: parameterized text access (common in Pages/WebKit/Chromium)
        var out: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXNumberOfCharactersAttribute as CFString, &out) == .success,
           let num = out as? NSNumber {
            let length = max(0, num.intValue)
            var cr = CFRange(location: 0, length: length)
            guard let axRange = AXValueCreate(.cfRange, &cr) else { return nil }
            var strOut: CFTypeRef?
            // Try plain string first
            if AXUIElementCopyParameterizedAttributeValue(elem, kAXStringForRangeParameterizedAttribute as CFString, axRange, &strOut) == .success,
               let s = strOut as? String {
                print("[Swap] copyFullText: using kAXStringForRange (len=\(length))")
                return (s, length, 0)
            }
            // Then attributed string
            if AXUIElementCopyParameterizedAttributeValue(elem, kAXAttributedStringForRangeParameterizedAttribute as CFString, axRange, &strOut) == .success,
               let a = strOut as? NSAttributedString {
                print("[Swap] copyFullText: using kAXAttributedStringForRange (len=\(length))")
                return (a.string, length, 0)
            }
            print("[Swap] copyFullText: parameterized read FAILED (length=\(length))")
        }
        // Last resort: visible character range (rich editors often expose this)
        var vrOut: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXVisibleCharacterRangeAttribute as CFString, &vrOut) == .success,
           let raw = vrOut,
           CFGetTypeID(raw) == AXValueGetTypeID() {
            let axVal = raw as! AXValue
            if AXValueGetType(axVal) == .cfRange {
                var cr = CFRange(location: 0, length: 0)
                if AXValueGetValue(axVal, .cfRange, &cr) {
                    var axRange = cr
                    guard let rangeVal = AXValueCreate(.cfRange, &axRange) else { return nil }
                    var strOut: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(elem, kAXStringForRangeParameterizedAttribute as CFString, rangeVal, &strOut) == .success,
                       let s = strOut as? String {
                        print("[Swap] copyFullText: using kAXVisibleCharacterRange (len=\(cr.length), base=\(cr.location))")
                        return (s, cr.length, cr.location)
                    }
                    if AXUIElementCopyParameterizedAttributeValue(elem, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeVal, &strOut) == .success,
                       let a = strOut as? NSAttributedString {
                        print("[Swap] copyFullText: using kAXVisibleCharacterRange (attributed) (len=\(cr.length), base=\(cr.location))")
                        return (a.string, cr.length, cr.location)
                    }
                }
            }
        }
        print("[Swap] copyFullText: no kAXValue and no parameterized text available")
        return nil
    }

    private func setSelectedTextRange(_ elem: AXUIElement, _ nsRange: NSRange) -> Bool {
        var settable: DarwinBoolean = false
        _ = AXUIElementIsAttributeSettable(elem, kAXSelectedTextRangeAttribute as CFString, &settable)
        guard settable.boolValue else {
            print("[Swap] setSelectedTextRange: attribute not settable")
            return false
        }


        var cf = CFRange(location: nsRange.location, length: nsRange.length)
        guard let ax = AXValueCreate(.cfRange, &cf) else {
            print("[Swap] setSelectedTextRange: AXValueCreate failed")
            return false
        }
        let ok = AXUIElementSetAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, ax) == .success
        print("[Swap] setSelectedTextRange: set = \(ok)")
        return ok
    }
    
    /// Read back the substring at a location to verify that insertion stuck.
    private func verifyReplacement(in elem: AXUIElement, at start: Int, expected: String) -> Bool {
        let wantLen = (expected as NSString).length
        guard wantLen >= 0 else { return false }
        let range = NSRange(location: start, length: wantLen)
        let got = readString(for: range, in: elem) ?? ""
        let pass = (got == expected)
        print("[Swap] verify: expect='\(short(expected))' got='\(short(got))'  pass=\(pass)")
        return pass
    }
    
    private func readString(for range: NSRange, in elem: AXUIElement) -> String? {
        var cr = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cr) else { return nil }
        var out: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(elem, kAXStringForRangeParameterizedAttribute as CFString, axRange, &out) == .success,
           let s = out as? String {
            return s
        }
        if AXUIElementCopyParameterizedAttributeValue(elem, kAXAttributedStringForRangeParameterizedAttribute as CFString, axRange, &out) == .success,
           let a = out as? NSAttributedString {
            return a.string
        }
        return nil
    }
    
    // Bring the owning AXApplication to the front so keystrokes/paste hit it.
    private func raiseOwningApplication(of elem: AXUIElement) {
        var app: AXUIElement? = elem
        while let e = app {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == kAXApplicationRole as String {
                let ok = AXUIElementPerformAction(e, kAXRaiseAction as CFString)
                print("[Swap] raise AXApplication: \(ok == .success)")
                return
            }
            app = parent(of: e)
        }
    }

    // MARK: - Synthetic typing

    private func typeUnicodeString(_ text: String) {
        print("[Swap] typing '\(short(text))'")
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
    
    // MARK: - Paste fallback
    
    private func pasteReplacement(_ text: String, preferPlain: Bool) async {
        print("[Swap] paste fallback  preferPlain=\(preferPlain)  text='\(short(text))'")
        let pb = NSPasteboard.general
        // Snapshot current pasteboard items (types+data) to restore later
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
    
        // Send Paste (try Paste and Match Style chord first if requested)
        if preferPlain {
            // ⌥⇧⌘V is common in WebKit/Pages; harmless where unsupported
            sendKeyCombo(key: CGKeyCode(kVK_ANSI_V), flags: [.maskCommand, .maskShift, .maskAlternate])
        } else {
            sendKeyCombo(key: CGKeyCode(kVK_ANSI_V), flags: [.maskCommand])
        }
        // Give the target app a moment to consume the paste, then restore clipboard
        try? await Task.sleep(nanoseconds: 120_000_000)
        pb.clearContents()
        // Rebuild items
        let items = saved.map { pairs -> NSPasteboardItem in
            let it = NSPasteboardItem()
            for (t, d) in pairs { it.setData(d, forType: t) }
            return it
        }
        pb.writeObjects(items)
    }
    
    private func sendKeyCombo(key: CGKeyCode, flags: CGEventFlags) {
        print("[Swap] sendKeyCombo key=\(key) flags=\(flags)")
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)!
        keyDown.flags = flags
        keyDown.post(tap: .cgSessionEventTap)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)!
        keyUp.flags = flags
        keyUp.post(tap: .cgSessionEventTap)
    }
    
    // MARK: - Window/App fallback search
    
    /// If focused element search fails (Pages case), search the focused window, then all app windows.
    private func resolveViaWindowAndAppFallback(from start: AXUIElement) -> AXUIElement? {
        // 1) Get the AXApplication for the frontmost app.
        guard let appElem = frontmostApplicationElement() else {
            print("[Swap] window/app fallback: no frontmost application element")
            return nil
        }
        // 2) Try focused window first (most likely to contain caret).
        if let win = focusedWindow(of: appElem) {
            print("[Swap] window fallback: searching focused window…")
            if let hit = bfsFindActiveText(in: win, label: "FocusedWindow") {
                return hit
            }
        } else {
            print("[Swap] window fallback: kAXFocusedWindow not available")
        }
        // 3) Try all app windows (bounded).
        let wins = allWindows(of: appElem)
        print("[Swap] app fallback: searching \(wins.count) window(s)…")
        for (i, w) in wins.enumerated() {
            if let hit = bfsFindActiveText(in: w, label: "AppWindow[\(i)]") {
                return hit
            }
        }
        return nil
    }
    
    private func frontmostApplicationElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }
    
    private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &out) == .success,
              let raw = out,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        // Perform a non-optional cast after the CF type check
        let win: AXUIElement = raw as! AXUIElement
        return win
    }
    
    private func allWindows(of app: AXUIElement) -> [AXUIElement] {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &out) == .success,
              let arr = out as? [AXUIElement] else {
            return []
        }
        return arr
    }
    
    /// Prefer a text-capable element that appears active (focused/selection/insertion present).
    private func bfsFindActiveText(in root: AXUIElement, label: String) -> AXUIElement? {
        struct Node { let e: AXUIElement; let d: Int }
        var q: [Node] = [Node(e: root, d: 0)]
        var seen = Set<UnsafeMutableRawPointer>()
        var visited = 0
        let maxDepth = 12
        let maxNodes = 5000
    
        func id(_ e: AXUIElement) -> UnsafeMutableRawPointer { Unmanaged.passUnretained(e).toOpaque() }
        func isActive(_ e: AXUIElement) -> Bool {
            // Focused attribute OR selection/insertion APIs present
            var out: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXFocusedAttribute as CFString, &out) == .success,
               let b = out as? Bool, b { return true }
            if supportsAttribute(e, kAXSelectedTextRangeAttribute as CFString) ||
               supportsAttribute(e, kAXSelectedTextAttribute as CFString) {
                return true
            }
            return false
        }
    
        print("[Swap] \(label): BFS start")
        while !q.isEmpty {
            let n = q.removeFirst()
            let eid = id(n.e)
            if seen.contains(eid) { continue }
            seen.insert(eid)
            visited += 1
            if visited > maxNodes { print("[Swap] \(label): BFS cap hit at \(visited) nodes"); break }
    
            if isTextCapable(n.e) && isActive(n.e) {
                print("[Swap] \(label): found active text element at depth \(n.d): \(describe(elem: n.e))")
                return n.e
            }
            if n.d >= maxDepth { continue }
            let kids = children(of: n.e)
            for c in kids { q.append(Node(e: c, d: n.d + 1)) }
        }
        print("[Swap] \(label): BFS found no active text element (visited=\(visited))")
        return nil
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
    
    // MARK: - Tiny debug helpers
    
    private func short(_ s: String, max: Int = 48) -> String {
        let ns = s as NSString
        if ns.length <= max { return s }
        let head = ns.substring(with: NSRange(location: 0, length: max))
        return head + "…(\(ns.length))"
    }
    
    private func describe(elem: AXUIElement) -> String {
        func str(_ attr: CFString) -> String? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(elem, attr, &v) == .success else { return nil }
            if let s = v as? String { return s }
            return nil
        }
        let role = str(kAXRoleAttribute as CFString) ?? "?"
        let sub  = str(kAXSubroleAttribute as CFString)
        let title = str(kAXTitleAttribute as CFString)
        return "role=\(role)\(sub != nil ? "/\(sub!)" : "")\(title != nil ? " title='\(short(title!))'" : "")"
    }

}
