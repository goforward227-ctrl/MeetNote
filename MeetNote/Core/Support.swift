import Foundation
import os

let appLog = Logger(subsystem: "local.meetnote.MeetNote", category: "app")

/// 外部APIの失敗を表す共通エラー。
struct APIError: LocalizedError {
    let service: String
    let status: Int?
    let message: String
    var retryAfter: Double? = nil

    var isRetryable: Bool {
        guard let status else { return true }
        return status == 408 || status == 409 || status == 429 || status >= 500
    }

    var errorDescription: String? {
        if let status {
            return "\(service) APIエラー（HTTP \(status)）：\(message)"
        }
        return "\(service) APIエラー：\(message)"
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Redactor {
    /// ログやエラー表示に出す前に、APIキーらしき文字列を伏せる。
    static func mask(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where secret.count >= 8 {
            result = result.replacingOccurrences(of: secret, with: maskedForm(of: secret))
        }
        let patterns = ["sk-ant-[A-Za-z0-9_\\-]{8,}", "sk_[A-Za-z0-9]{16,}", "xi-api-key:\\s*\\S+"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "****")
        }
        return result
    }

    static func maskedForm(of secret: String) -> String {
        "\(secret.prefix(4))****"
    }
}

enum Retry {
    /// 一時的な失敗（429・5xx・通信エラー）だけを、最大 `maxRetries` 回まで再試行する。
    static func run<T>(
        maxRetries: Int = 2,
        onRetry: (_ attempt: Int, _ error: Error) -> Void = { _, _ in },
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxRetries, isRetryable(error) else { throw error }
                attempt += 1
                onRetry(attempt, error)
                let fallback = pow(2.0, Double(attempt)) * 2
                let wait = min((error as? APIError)?.retryAfter ?? fallback, 60)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let api = error as? APIError { return api.isRetryable }
        if let url = error as? URLError { return url.code != .cancelled }
        return false
    }
}

extension HTTPURLResponse {
    var retryAfterSeconds: Double? {
        value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
    }
}

enum APIErrorBody {
    /// エラーレスポンスの本文から、人が読めるメッセージを取り出す。
    static func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let detail = object["detail"] as? [String: Any], let message = detail["message"] as? String {
                return message
            }
            if let detail = object["detail"] as? [[String: Any]] {
                let messages = detail.compactMap { $0["msg"] as? String }
                if !messages.isEmpty { return messages.joined(separator: " / ") }
            }
            if let detail = object["detail"] as? String { return detail }
            if let message = object["message"] as? String { return message }
        }
        let text = String(data: data.prefix(500), encoding: .utf8) ?? ""
        return text.isEmpty ? "（本文なし）" : text
    }
}
