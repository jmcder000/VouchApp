//
//  OutboxSender.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


//
//  OutboxSender.swift
//  VouchForMe
//
//  Phase 4.5: Background worker that drains LocalQueue to the Node endpoint
//

import Foundation

final class OutboxSender {
    private let queue: LocalQueue
    private let client: AnalysisClient
    private weak var logModel: LogModel?
    private var task: Task<Void, Never>?
    private var running = false
    private var attemptsByURL: [URL: Int] = [:]


    // Backoff settings
    private let minBackoff: TimeInterval = 1
    private let maxBackoff: TimeInterval = 60
    private let maxAttemptsPerItem: Int = 6


    init(queue: LocalQueue, client: AnalysisClient, logModel: LogModel) {
        self.queue = queue
        self.client = client
        self.logModel = logModel
    }

    func start() {
        guard !running else { return }
        running = true
        task = Task { [weak self] in
            guard let self else { return }
            var backoff = minBackoff

            // Optional health check on boot
            if await !self.client.healthCheck() {
                self.logModel?.append(.queueInfo("Analyzer server not reachable yet; will retry."))
            } else {
                self.logModel?.append(.queueInfo("Analyzer server is reachable."))
            }

            while !Task.isCancelled && self.running {
                // Peek first; if nothing to do, idle briefly.
                guard let url = self.queue.peekNext() else {
                    try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
                    continue
                }
                // Read & decode inside a synchronous autoreleasepool
                let payload: AnalysisPayload
                do {
                    payload = try autoreleasepool(invoking: { () throws -> AnalysisPayload in
                        let data = try Data(contentsOf: url)
                        return try JSONDecoder().decode(AnalysisPayload.self, from: data)
                    })
                } catch {
                    // If we can't decode the file, drop it to avoid blocking the queue.
                    let desc = (error as NSError).localizedDescription
                    await MainActor.run { [weak self] in
                        self?.logModel?.append(.queueInfo("Corrupt queued item: \(desc). Dropping."))
                    }
                    self.queue.remove(url)
                    continue
                }
                // Async work (network/backoff) happens *outside* the autoreleasepool
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.logModel?.append(.queueInfo("Sending 1 payload… (queue=\(self.queue.count))"))
                }
                do {
                    let reqId = url.lastPathComponent
                    _ = try await self.client.postPayload(payload, requestId: reqId)
                    self.queue.remove(url)
                    self.attemptsByURL[url] = nil
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.logModel?.append(.queueInfo("✓ Sent (queue=\(self.queue.count))"))
                    }
                    backoff = self.minBackoff // reset on success
                } catch {
                    let nsErr = error as NSError
                    var desc = nsErr.localizedDescription
                    if let urlErr = error as? URLError {
                        desc = "URLError(\(urlErr.code.rawValue)) \(urlErr.localizedDescription)"
                    }
                    
                    // Increment attempts and decide whether to dead-letter
                    let attempts = (self.attemptsByURL[url] ?? 0) + 1
                    self.attemptsByURL[url] = attempts
                    await MainActor.run { [weak self] in
                        self?.logModel?.append(.queueInfo("Send failed [attempt \(attempts)/\(self?.maxAttemptsPerItem ?? 0)]: \(desc)"))
                    }
                    if attempts >= self.maxAttemptsPerItem {
                        await MainActor.run { [weak self] in
                            self?.logModel?.append(.queueInfo("❗️Permanently failing item after \(attempts) attempts → moving to Dead Letters"))
                        }
                        self.queue.moveToDead(url, completion: nil)
                        self.attemptsByURL[url] = nil
                        backoff = self.minBackoff
                        continue
                    }
                    // Exponential backoff
                    let jitter = Double.random(in: 0...(backoff * 0.3))
                    let delay = UInt64((backoff + jitter) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delay)
                    backoff = min(backoff * 2, self.maxBackoff)
                }
            }
        }
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
    }

    /// Manual nudge: try to send up to `limit` items immediately, then return.
    @discardableResult
    func processOnce(limit: Int = 1) async -> Int {
        var sent = 0
        for _ in 0..<limit {
            guard let url = queue.peekNext() else { break }
            do {
                let data = try Data(contentsOf: url)
                let payload = try JSONDecoder().decode(AnalysisPayload.self, from: data)
                let reqId = url.lastPathComponent
                _ = try await client.postPayload(payload, requestId: reqId)

                queue.remove(url)
                attemptsByURL[url] = nil

                sent += 1
            } catch {
                // If manual send fails repeatedly, respect the same ceiling.
                let attempts = (attemptsByURL[url] ?? 0) + 1
                attemptsByURL[url] = attempts
                if attempts >= maxAttemptsPerItem {
                    queue.moveToDead(url, completion: nil)
                    attemptsByURL[url] = nil
                }
                break
            }
        }
        return sent
    }
}
