//
//  LogModel.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


//  LogModel.swift

import Foundation
import SwiftUI
import AppKit


final class LogModel: ObservableObject {
    struct Entry: Identifiable {
        enum Kind {
            case chunk(String)
            case secure(Bool)
            case window(WindowSnapshot)   // NEW: show captured window snapshot
            case payload(PayloadPreview)  // NEW: combined chunk+window preview
            case queueInfo(String)        // NEW: back-pressure or queue events

        }
        let id = UUID()
        let ts = Date()
        let kind: Kind
    }

    @Published var entries: [Entry] = []

    func append(_ kind: Entry.Kind) {
        DispatchQueue.main.async {
            self.entries.insert(Entry(kind: kind), at: 0)
            // Keep log short for demo
            if self.entries.count > 200 { self.entries.removeLast(self.entries.count - 200) }
        }
    }
}


struct PayloadPreview {
    let appName: String
    let windowTitle: String
    let text: String
    let image: NSImage?        // optional (nil if no screenshot)
}
