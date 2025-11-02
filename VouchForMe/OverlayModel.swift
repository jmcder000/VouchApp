//
//  OverlayModel.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


import Foundation
import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    enum Verdict {
        case checking
        case verified      // no replacement
        case corrected     // replacementChunk present
    }

    struct Item: Identifiable, Equatable {
        let id: String                  // correlation id (we'll use the queued filename)
        let ts: Date
        let appName: String
        let windowTitle: String
        let chunk: String
        var replacement: String?        // nil = verified
        var verdict: Verdict
        var isNewest: Bool = false

        var hasCorrection: Bool { replacement != nil }
    }

    @Published var appName: String = ""
    @Published var windowTitle: String = ""
    @Published private(set) var items: [Item] = []

    func setActiveWindow(appName: String, windowTitle: String) {
        self.appName = appName
        self.windowTitle = windowTitle
    }

    /// Add or update the latest item in "checking" state; keep only the last three.
    func upsertPending(id: String, appName: String, windowTitle: String, chunk: String) {
        // new pending item
        var item = Item(id: id, ts: Date(),
                        appName: appName, windowTitle: windowTitle,
                        chunk: chunk, replacement: nil, verdict: .checking, isNewest: true)

        // clear 'isNewest' on existing items
        for i in items.indices { items[i].isNewest = false }

        // if we already have this id, update text/metadata but keep order
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = item
        } else {
            items.insert(item, at: 0)
            if items.count > 3 { items.removeLast(items.count - 3) }
        }
        self.appName = appName
        self.windowTitle = windowTitle
    }

    /// Apply analyzer result; update verdict and replacement.
    func applyResult(id: String, replacementChunk: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[idx]
        item.replacement = replacementChunk?.nilIfBlank
        item.verdict = (item.replacement == nil) ? .verified : .corrected
        items[idx] = item  // reassign to publish change
    }
    
    func markApplied(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[idx]
        item.replacement = nil
        item.verdict = .verified
        items[idx] = item  // publish
    }

}

private extension String {
    var nilIfBlank: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : self
    }
}
