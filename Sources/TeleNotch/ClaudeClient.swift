import Foundation

/// Minimal streaming client for the Claude Messages API (raw HTTP; there is no official Swift SDK).
enum ClaudeClient {
    enum Failure: LocalizedError {
        case noKey, http(Int, String), refused, api(String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "Add your Anthropic API key in TeleNotch Settings."
            case .http(let code, let msg): return "Claude API error \(code): \(msg)"
            case .refused: return "Claude declined to answer this one."
            case .api(let msg): return "Claude API error: \(msg)"
            }
        }
    }

    /// Streams the text of one reply. `onText` is called on the main queue with each new piece.
    static func stream(system: String, user: String, maxTokens: Int = 4000, effort: String = "low",
                       onText: @escaping (String) -> Void) async throws {
        // Retry brief failures (network blips, rate limits, overloaded servers) like the official SDKs do,
        // but only while nothing has been shown yet, so a retry never repeats text.
        var sent = false
        var attempt = 0
        while true {
            do {
                try await streamOnce(system: system, user: user, maxTokens: maxTokens, effort: effort) { piece in
                    sent = true
                    onText(piece)
                }
                return
            } catch {
                attempt += 1
                guard !sent, attempt < 3, isRetryable(error), !Task.isCancelled else { throw error }
                try await Task.sleep(for: .milliseconds(attempt == 1 ? 400 : 1200))
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case Failure.http(let code, _): return code == 408 || code == 409 || code == 429 || code >= 500
        case Failure.api: return true    // e.g. "overloaded" sent mid-stream
        case let e as URLError: return e.code != .cancelled
        default: return false
        }
    }

    private static func streamOnce(system: String, user: String, maxTokens: Int, effort: String,
                                   onText: @escaping (String) -> Void) async throws {
        guard let key = Keychain.apiKey else { throw Failure.noKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Server-side fallback: if the model's safety classifier declines, the API retries on a fallback model.
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": Prefs.model,
            "max_tokens": maxTokens,
            "stream": true,
            "fallbacks": "default",
            "output_config": ["effort": effort],
            // The system prompt never changes, so it is cached between calls.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var data = Data()
            for try await b in bytes { data.append(b) }
            throw Failure.http(status, errorMessage(data) ?? String(decoding: data, as: UTF8.self))
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    await MainActor.run { onText(text) }
                }
            case "message_delta":
                if let d = obj["delta"] as? [String: Any], d["stop_reason"] as? String == "refusal" { throw Failure.refused }
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
                throw Failure.api(msg)
            default:
                break
            }
        }
    }

    /// Convenience: the whole reply as one string.
    static func complete(system: String, user: String, maxTokens: Int = 4000, effort: String = "low") async throws -> String {
        var out = ""
        try await stream(system: system, user: user, maxTokens: maxTokens, effort: effort) { out += $0 }
        return out
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return nil }
        return err["message"] as? String
    }
}
