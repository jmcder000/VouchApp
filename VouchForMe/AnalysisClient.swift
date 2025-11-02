//
//  AnalysisClient.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//

import Foundation

struct AnalysisServerResponse: Codable {
    let replacementChunk: String?
}


struct AnalysisClientConfig {
    let baseURL: URL     // e.g. http://127.0.0.1:3000
    let timeoutSeconds: TimeInterval

    init(baseURL: URL = URL(string: "http://127.0.0.1:3000")!,
         timeoutSeconds: TimeInterval = 120) {
        self.baseURL = baseURL
        self.timeoutSeconds = timeoutSeconds
    }
}

final class AnalysisClient {
    private let cfg: AnalysisClientConfig
    private let session: URLSession
    private let encoder: JSONEncoder

    init(config: AnalysisClientConfig = AnalysisClientConfig()) {
        self.cfg = config

        let conf = URLSessionConfiguration.default
        conf.timeoutIntervalForRequest = config.timeoutSeconds
        conf.timeoutIntervalForResource = max(60, config.timeoutSeconds)
        self.session = URLSession(configuration: conf)

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    /// POSTs a payload to /analyze. Throws on transport or non-2xx responses.
    @discardableResult
    func postPayload(_ payload: AnalysisPayload, requestId: String? = nil) async throws -> HTTPURLResponse {
        let url = cfg.baseURL.appendingPathComponent("analyze")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = cfg.timeoutSeconds

        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let requestId {
            req.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        }
        req.httpBody = try encoder.encode(payload)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AnalysisClient", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Server \(http.statusCode): \(body)"])
        }
        return http
    }

    /// Simple health check against GET /healthz.
    func healthCheck() async -> Bool {
        do {
            let url = cfg.baseURL.appendingPathComponent("healthz")
            let (_, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }
    
    func submitForResult(_ payload: AnalysisPayload, requestId: String? = nil)
        async throws -> (AnalysisServerResponse?, HTTPURLResponse)
    {
        let url = cfg.baseURL.appendingPathComponent("analyze")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = cfg.timeoutSeconds
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let requestId { req.setValue(requestId, forHTTPHeaderField: "X-Request-Id") }
        req.httpBody = try encoder.encode(payload)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AnalysisClient", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Server \(http.statusCode): \(body)"])
        }

        // Try strict decode. If analyzer is in Metorial mode (freeform text), this will fail -> nil.
        let parsed = try? JSONDecoder().decode(AnalysisServerResponse.self, from: data)
        return (parsed, http)
    }

}
