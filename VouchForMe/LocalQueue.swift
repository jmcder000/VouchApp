//
//  LocalQueue.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


//
//  LocalQueue.swift
//  VouchForMe
//
//  Phase 4: Simple on-disk spool + in-memory index with back-pressure
//

import Foundation

/// A minimal durable queue that writes each payload as one JSON file under
/// ~/Library/Application Support/VouchForMe/OutboundQueue
///
/// This does *not* send over the network. Phase 5 will read/dequeue and POST.
final class LocalQueue {

    struct EnqueueResult {
        let url: URL
        let droppedCount: Int
    }

    private let io = DispatchQueue(label: "VouchForMe.LocalQueue.io")
    private let dir: URL
    private(set) var pending: [URL] = []        // in-memory index of files sorted oldest→newest
    private let encoder = JSONEncoder()

    /// Back-pressure: when queue exceeds this many items on disk, drop oldest.
    let maxOnDisk: Int

    init(maxOnDisk: Int = 100) {
        self.maxOnDisk = maxOnDisk

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("VouchForMe", isDirectory: true)
        self.dir = base.appendingPathComponent("OutboundQueue", isDirectory: true)

        io.sync {
            try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
            self.reloadIndex()
        }
    }

    /// Rebuild in-memory index from disk (sorted by filename which is timestamp-prefixed).
    private func reloadIndex() {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        pending = items
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    /// Adds a payload to the spool and enforces back-pressure. Completion called on main.
    func enqueue(_ payload: AnalysisPayload, completion: ((EnqueueResult) -> Void)? = nil) {
        io.async {
            // Name: 1698955530123_UUID.json (ms + uuid)
            let ts = UInt64(Date().timeIntervalSince1970 * 1000)
            let name = "\(ts)_\(UUID().uuidString).json"
            let url = self.dir.appendingPathComponent(name, isDirectory: false)

            // Encode pretty for easier debugging
            self.encoder.outputFormatting = [.sortedKeys]
            do {
                let data = try self.encoder.encode(payload)
                try data.write(to: url, options: [.atomic])
            } catch {
                // If write fails, we simply skip adding to index
                DispatchQueue.main.async {
                    completion?(EnqueueResult(url: url, droppedCount: 0))
                }
                return
            }

            // Update in-memory list
            self.pending.append(url)

            // Back-pressure: drop oldest files above cap
            var dropped = 0
            if self.pending.count > self.maxOnDisk {
                let overflow = self.pending.count - self.maxOnDisk
                let toDrop = self.pending.prefix(overflow)
                for u in toDrop {
                    try? FileManager.default.removeItem(at: u)
                }
                self.pending.removeFirst(overflow)
                dropped = overflow
            }

            DispatchQueue.main.async {
                completion?(EnqueueResult(url: url, droppedCount: dropped))
            }
        }
    }

    /// Returns the URL for the next payload (oldest), without removing it.
    func peekNext() -> URL? {
        return io.sync { pending.first }
    }

    /// Reads + removes the next payload (oldest). Returns (payload, url) or nil if empty.
    func dequeue() -> (AnalysisPayload, URL)? {
        return io.sync {
            guard let url = pending.first,
                  let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(AnalysisPayload.self, from: data)
            else { return nil }
            // Remove file and update index
            try? FileManager.default.removeItem(at: url)
            pending.removeFirst()
            return (payload, url)
        }
    }

    /// Removes a specific URL from disk/index (e.g., after successful send when you only peeked).
    func remove(_ url: URL) {
        io.async {
            try? FileManager.default.removeItem(at: url)
            if let i = self.pending.firstIndex(of: url) {
                self.pending.remove(at: i)
            }
        }
    }

    /// Current count of spooled payloads
    var count: Int { io.sync { pending.count } }
}
