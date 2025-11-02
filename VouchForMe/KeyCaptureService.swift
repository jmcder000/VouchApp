//  KeyCaptureService.swift
import Foundation
import CoreGraphics
import Carbon
// import AppKit  // Not needed; avoid AppKit on the tap thread

protocol KeyCaptureServiceDelegate: AnyObject {
    func keyCaptureService(_ service: KeyCaptureService, didCaptureChunk text: String)
    func keyCaptureService(_ service: KeyCaptureService, secureInputStatusChanged isSecure: Bool)
    /// Called when the service auto-stops due to extended idle time.
    func keyCaptureServiceDidAutoStop(_ service: KeyCaptureService)
}



final class KeyCaptureService {

    weak var delegate: KeyCaptureServiceDelegate?
    private var hadNewTextSinceLastEmit = false
    private var lastEmittedChunk: String?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?

    private(set) var isCapturing = false

    // Buffer
    private var textBuffer = ""
    private let maxBufferSize = 1000
    private var lastKeyTime = Date()
    private var chunkTimer: Timer?

    // Secure input
    private var isSecureInputActive = false
    private var consecutiveEmptyKeys = 0

    // Config
    var idleTimeoutSeconds: TimeInterval = 2.5              // idle -> emit
    var autoStopAfterIdle: TimeInterval? = 300              // 5 minutes -> stop (nil to disable)
    var minChunkLength = 10
    var ignoreCommandAndControl = true

    // For quick demo feedback (optional)
    var debugMinChunkLengthForTesting: Int? = nil

    deinit { stopCapture() }

    /// Asynchronous start. Calls completion(true) only if the event tap is created & enabled.
    func startCapture(completion: @escaping (Bool) -> Void) {
        guard !isCapturing else { completion(true); return }

        // Ensure permission
        let pm = InputPermissionManager()
        guard pm.isInputMonitoringGranted() else {
            print("⚠️ Input Monitoring permission not granted")
            completion(false)
            return
        }

        // Prime state (but don't mark capturing yet)
        textBuffer = ""
        lastKeyTime = Date()
        consecutiveEmptyKeys = 0
        hadNewTextSinceLastEmit = false
        if let debugLen = debugMinChunkLengthForTesting { minChunkLength = debugLen }
        
        // If a tap already exists (we previously paused), just re-enable it.
        let mode: CFRunLoopMode = CFRunLoopMode.commonModes
        if let tap = self.eventTap, let rl = self.tapRunLoop {
            CFRunLoopPerformBlock(rl, mode as CFTypeRef){
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            CFRunLoopWakeUp(rl)
            self.isCapturing = true
            self.startChunkTimer()
            print("▶︎ Keystroke capture resumed")
            completion(true)
            return
        }

        // Event-tap thread
        let thread = Thread { [weak self] in
            guard let self else { return }

            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

            let callback: CGEventTapCallBack = { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<KeyCaptureService>.fromOpaque(userInfo).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = service.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }

                if type == .keyDown { service.handleEvent(event) }
                return Unmanaged.passUnretained(event)
            }

            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                print("❌ Failed to create event tap (permissions? sandbox off?)")
                DispatchQueue.main.async {
                    self.cleanupAfterStop()
                    completion(false)
                }
                return
            }

            self.eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            let rl = CFRunLoopGetCurrent()
            self.tapRunLoop = rl

            let mode: CFRunLoopMode = CFRunLoopMode.commonModes
            CFRunLoopAddSource(rl, source, mode)
            CGEvent.tapEnable(tap: tap, enable: true)

            // Mark capturing + start idle timer on main now that the tap is live
            DispatchQueue.main.async {
                self.isCapturing = true
                self.startChunkTimer()
                print("✓ Keystroke capture started")
                completion(true)
            }

            CFRunLoopRun()
        }

        // Avoid priority inversion warnings
        thread.qualityOfService = .userInteractive
        thread.name = "KeyCaptureService.EventTap"
        tapThread = thread
        thread.start()
    }

    func stopCapture() {
        guard isCapturing else { return }

        if !textBuffer.isEmpty { emitWholeBufferOnce() }

        // Stop timer
        chunkTimer?.invalidate(); chunkTimer = nil

        // Tear down tap on its run loop
        let mode: CFRunLoopMode = CFRunLoopMode.commonModes
        // Pause (disable) the existing tap on its run loop—no removal, no thread stop.
        if let rl = tapRunLoop, let tap = eventTap {
            CFRunLoopPerformBlock(rl, mode as CFTypeRef) {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            CFRunLoopWakeUp(rl)
        }
        
        isCapturing = false
        hadNewTextSinceLastEmit = false
        print("⏸ Keystroke capture paused")

    }

    // MARK: - Event handling (CoreGraphics-only)

    private func handleEvent(_ event: CGEvent) {
        // If paused/stopped, drop events immediately—even if the OS tap hasn't been disabled yet.
        if !isCapturing { return }

        checkSecureInput()

        if ignoreCommandAndControl {
            let flags = event.flags
            if flags.contains(.maskCommand) || flags.contains(.maskControl) {
                lastKeyTime = Date()
                return
            }
        }

        if let text = extractText(from: event), !text.isEmpty {
            consecutiveEmptyKeys = 0
            appendText(text)
        } else {
            consecutiveEmptyKeys += 1
            if consecutiveEmptyKeys > 5 { detectSecureInput() }
        }

        lastKeyTime = Date()
    }

    func shutdown() {
        let mode: CFRunLoopMode = CFRunLoopMode.commonModes
        if isCapturing { stopCapture() }
        guard let rl = tapRunLoop, let source = runLoopSource else { return }
        CFRunLoopPerformBlock(rl, mode as CFTypeRef) { [weak self] in
            guard let self else { return }
            if let tap = self.eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
            CFRunLoopRemoveSource(rl, source, .commonModes)
            self.runLoopSource = nil
            self.eventTap = nil
            CFRunLoopStop(rl)
        }
        CFRunLoopWakeUp(rl)
        cleanupAfterStop()
        tapThread = nil
        print("✓ Keystroke capture stopped (shutdown)")
    }

    private func extractText(from event: CGEvent) -> String? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch Int(keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "\n"
        case kVK_Tab:                           return "\t"
        case kVK_Space:                         return " "
        case kVK_Delete:
            if !textBuffer.isEmpty { _ = textBuffer.popLast() }
            return nil
        default:
            var buffer = [UniChar](repeating: 0, count: 32)
            var actualLen = 0
            buffer.withUnsafeMutableBufferPointer { ptr in
                event.keyboardGetUnicodeString(
                    maxStringLength: ptr.count,
                    actualStringLength: &actualLen,
                    unicodeString: ptr.baseAddress!
                )
            }
            guard actualLen > 0 else { return "" }
            let n = min(actualLen, buffer.count)
            return String(utf16CodeUnits: buffer, count: n)
        }
    }

    // MARK: - Buffer / chunking

    private func appendText(_ text: String) {
        textBuffer.append(text)

        // If the appended piece contains any non-whitespace (not just spaces/newlines),
        // we mark that "real" text has been typed since last emit.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            hadNewTextSinceLastEmit = true
        }

        if textBuffer.count > maxBufferSize {
            textBuffer.removeFirst(textBuffer.count - maxBufferSize)
        }
        
        // Flush immediately when the user hits Enter (newline),
        // but only if meaningful text has been typed since last emit.
        if text.contains("\n") {
            let trimmedLen = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines).count
            if hadNewTextSinceLastEmit && trimmedLen >= minChunkLength {
                emitWholeBufferOnce()
            }
            return
        }

        // Try to emit at the *last* sentence boundary (". " | "? " | "! ") + Capital
        if tryEmitAtSentenceBoundary() {
            return
        }

        // Otherwise do nothing here; idle timer will take care of flushing if needed
    }

    /// MVP: Find last [". ", "? ", "! "] + Capital; emit up to the punctuation, leave next sentence in buffer.
    private func tryEmitAtSentenceBoundary() -> Bool {
        guard let punctIdx = lastSentenceBoundaryIndex(in: textBuffer) else { return false }

        // chunk = [start .. dot], remainder = after the space (i.e., at the Capital)
        let s = textBuffer
        let afterSpaceIdx = s.index(punctIdx, offsetBy: 2) // punct + ' ' then Capital
        let rawChunk = String(s[s.startIndex...punctIdx])
        let remainder = afterSpaceIdx < s.endIndex ? String(s[afterSpaceIdx...]) : ""

        // Reset working state to the remainder
        textBuffer = remainder
        hadNewTextSinceLastEmit = false

        // Normalize & emit (with dedupe & length check)
        let normalized = normalize(rawChunk)
        sendChunkIfUseful(normalized)
        return true
    }

    /// Scan from the end for ('.'|'?'|'!') + ' ' + Capital; return the punctuation index if found.
    private func lastSentenceBoundaryIndex(in s: String) -> String.Index? {
        guard s.count >= 3 else { return nil }
        var i = s.index(before: s.endIndex)
        while i > s.startIndex {
            let ch = s[i]
            if ch.isUppercase {
                let spaceIdx = s.index(before: i)
                if s[spaceIdx] == " " {
                    if spaceIdx > s.startIndex {
                        let punctIdx = s.index(before: spaceIdx)
                        let punct = s[punctIdx]
                        if punct == "." || punct == "?" || punct == "!" {
                            return punctIdx
                        }
                    }
                }
            }
            i = s.index(before: i)
       }
        return nil
    }

     /// Emit the *whole* current buffer (used by idle flush or stop).

    private func emitWholeBufferOnce() {

        guard !textBuffer.isEmpty else { return }

        let normalized = normalize(textBuffer)

        textBuffer = ""

        hadNewTextSinceLastEmit = false

        sendChunkIfUseful(normalized)

    }



    private func normalize(_ raw: String) -> String {

        raw.components(separatedBy: .whitespacesAndNewlines)

            .filter { !$0.isEmpty }

            .joined(separator: " ")

    }



    private func sendChunkIfUseful(_ normalized: String) {

        guard normalized.count >= minChunkLength else { return }

        if let last = lastEmittedChunk, last == normalized { return } // de-dupe

        lastEmittedChunk = normalized



        let deliver = { [weak self] in

            guard let self else { return }

            self.delegate?.keyCaptureService(self, didCaptureChunk: normalized)

        }

        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }

    }



    // MARK: - Idle timer (emit + auto-stop)



    private func startChunkTimer() {

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in

            guard let self else { return }

            let idle = Date().timeIntervalSince(self.lastKeyTime)



            // Idle-based emit (only if user actually typed since last emit)

            if idle >= self.idleTimeoutSeconds && self.hadNewTextSinceLastEmit && !self.textBuffer.isEmpty {

                self.emitWholeBufferOnce()

            }



            // Auto-stop after extended idle (default: 5 minutes)

            if let cutoff = self.autoStopAfterIdle, idle >= cutoff {

                self.stopCapture()

                // Notify UI so it can update the icon/menu state

                self.delegate?.keyCaptureServiceDidAutoStop(self)

            }

        }

        chunkTimer = timer

        RunLoop.main.add(timer, forMode: .common)

    }



    // MARK: - Secure Input



    private func checkSecureInput() {

        let nowSecure = IsSecureEventInputEnabled()

        if nowSecure != isSecureInputActive {

            isSecureInputActive = nowSecure

            let notify = { [weak self] in

                guard let self else { return }

                self.delegate?.keyCaptureService(self, secureInputStatusChanged: nowSecure)

            }

            if Thread.isMainThread { notify() } else { DispatchQueue.main.async(execute: notify) }

        }

    }



    private func detectSecureInput() {

        if !isSecureInputActive {

            isSecureInputActive = true

            let notify = { [weak self] in

                guard let self else { return }

                self.delegate?.keyCaptureService(self, secureInputStatusChanged: true)

            }

            if Thread.isMainThread { notify() } else { DispatchQueue.main.async(execute: notify) }

        }

    }

    // MARK: - Cleanup

    private func cleanupAfterStop() {
        isCapturing = false
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        hadNewTextSinceLastEmit = false
    }
}
