import Foundation

struct ClaudeUsage: Equatable {
    var inputTokens = 0
    var outputTokens = 0

    static func + (lhs: ClaudeUsage, rhs: ClaudeUsage) -> ClaudeUsage {
        ClaudeUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }
}

struct ClaudeResult {
    var text: String
    var usage: ClaudeUsage
    /// 実際に応答を返したモデル（フォールバックが起きた場合は指定と異なる）。
    var servedModel: String?
}

/// ストリーミング応答（SSE）の `data:` 行を1つずつ受け取り、本文と使用量を組み立てる。
struct ClaudeStreamAccumulator {
    private(set) var text = ""
    private(set) var usage = ClaudeUsage()
    private(set) var model: String?
    private(set) var stopReason: String?
    private(set) var refusalCategory: String?

    private var baseInputTokens = 0
    private var cacheTokens = 0

    mutating func consume(_ data: Data) throws {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        switch type {
        case "message_start":
            let message = event["message"] as? [String: Any]
            model = message?["model"] as? String ?? model
            applyUsage(message?["usage"] as? [String: Any])
        case "content_block_start":
            let block = event["content_block"] as? [String: Any]
            switch block?["type"] as? String {
            case "fallback":
                // 最初のモデルが辞退して別のモデルに切り替わった。それまでの途中出力は捨てる。
                text = ""
                model = (block?["to"] as? [String: Any])?["model"] as? String ?? model
            case "text":
                text += block?["text"] as? String ?? ""
            default:
                break
            }
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            if delta?["type"] as? String == "text_delta" {
                text += delta?["text"] as? String ?? ""
            }
        case "message_delta":
            let delta = event["delta"] as? [String: Any]
            stopReason = delta?["stop_reason"] as? String ?? stopReason
            let details = (delta?["stop_details"] ?? event["stop_details"]) as? [String: Any]
            refusalCategory = details?["category"] as? String ?? refusalCategory
            applyUsage(event["usage"] as? [String: Any])
        case "error":
            let error = event["error"] as? [String: Any]
            let kind = error?["type"] as? String
            throw APIError(
                service: "Anthropic",
                status: kind == "overloaded_error" ? 529 : nil,
                message: error?["message"] as? String ?? "ストリーミング中にエラーが発生しました。"
            )
        default:
            break
        }
    }

    private mutating func applyUsage(_ dictionary: [String: Any]?) {
        guard let dictionary else { return }
        if let value = dictionary["input_tokens"] as? Int { baseInputTokens = value }
        if dictionary["cache_read_input_tokens"] != nil || dictionary["cache_creation_input_tokens"] != nil {
            cacheTokens = (dictionary["cache_read_input_tokens"] as? Int ?? 0)
                + (dictionary["cache_creation_input_tokens"] as? Int ?? 0)
        }
        if let value = dictionary["output_tokens"] as? Int { usage.outputTokens = value }
        usage.inputTokens = baseInputTokens + cacheTokens
    }
}

/// Anthropic Messages API のクライアント（公式のSwift SDKが無いため、HTTPで直接呼ぶ）。
struct ClaudeClient {
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// 安全分類器による辞退のとき、サーバー側で別モデルに自動で切り替える機能に対応するモデル。
    static let fallbackCapableModels: Set<String> = [
        "claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5", "claude-fable-5-2", "claude-fable-5-1",
    ]

    let apiKey: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func generate(model: String, system: String, user: String, maxTokens: Int = 32_000) async throws -> ClaudeResult {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if Self.fallbackCapableModels.contains(model) {
            body["fallbacks"] = "default"
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(service: "Anthropic", status: nil, message: "応答を受け取れませんでした。")
        }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 20_000 { break }
            }
            throw APIError(
                service: "Anthropic",
                status: http.statusCode,
                message: Redactor.mask(APIErrorBody.message(from: data), secrets: [apiKey]),
                retryAfter: http.retryAfterSeconds
            )
        }

        var accumulator = ClaudeStreamAccumulator()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            try accumulator.consume(Data(payload.utf8))
        }

        switch accumulator.stopReason {
        case "refusal":
            let category = accumulator.refusalCategory.map { "（分類：\($0)）" } ?? ""
            throw AppError("Claudeがこの内容の処理を辞退しました\(category)。設定で別のモデルを選ぶと通る場合があります。")
        case "max_tokens":
            throw AppError("議事録が出力の上限に達して途中で切れました。会議が長すぎる可能性があります。")
        case nil:
            throw APIError(service: "Anthropic", status: nil, message: "応答が途中で切れました。")
        default:
            break
        }

        let text = accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AppError("Claudeから空の応答が返りました。")
        }
        return ClaudeResult(text: text, usage: accumulator.usage, servedModel: accumulator.model)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10 * 60
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: configuration)
    }()
}
