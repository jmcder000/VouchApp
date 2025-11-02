//
//  HotKeyCenter.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


//  HotKeyCenter.swift
//  VouchForMe
//
//  Global hotkey via Carbon. Calls a Swift closure on press.

import Cocoa
import Carbon


final class HotKeyCenter {
    typealias Handler = () -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: Handler = {}   // non-optional, default no-op

    // We keep the ID so the callback can verify it came from *our* hotkey.
    private var hotKeyID = EventHotKeyID(signature: OSType(0x56464D31), id: 1) // 'VFM1'

    func register(keyCode: UInt32, modifiers: UInt32, onPress: @escaping Handler){
        unregister()
        self.handler = onPress

        // Install handler for key pressed events
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()

            var incomingID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout.size(ofValue: incomingID),
                                           nil,
                                           &incomingID)
            guard status == noErr else { return noErr }

            // Ensure this is *our* hotkey
            if incomingID.signature == center.hotKeyID.signature && incomingID.id == center.hotKeyID.id {
                // Bounce to main to safely touch @MainActor UI
                DispatchQueue.main.async {
                    center.handler()   // handler is always set (no-op by default)
                }
            }

            return noErr
        }, 1, &eventType, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &eventHandlerRef)

        // Register the actual hotkey (system-wide)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            // Best-effort cleanup if registration failed
            if let eh = eventHandlerRef { RemoveEventHandler(eh); eventHandlerRef = nil }
            self.handler = {}   // reset to no-op instead of nil
        }
    }

    func unregister() {
        if let hk = hotKeyRef {
            UnregisterEventHotKey(hk)
        }
        if let eh = eventHandlerRef {
            RemoveEventHandler(eh)
        }
        hotKeyRef = nil
        eventHandlerRef = nil
        handler = {}

    }

    deinit { unregister() }
}
