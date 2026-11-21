import Foundation

struct MinutesResult {
    var markdown: String
    var usage: ClaudeUsage
    var servedModel: String?
}

/// 発言録から議事録（Markdown）を作る。
struct MinutesGenerator {
    let client: ClaudeClient
    let model: String
    let systemPrompt: String
    /// 発言録がこの文字数を超えたら、分割して要約してから統合する（1時間の会議でおよそ2万文字）。
    var splitThreshold = 250_000

    struct Context {
        var title: String
        var date: Date
        var durationSeconds: Double
    }

    func generate(lines: [String], context: Context) async throws -> MinutesResult {
        let chunks = Self.split(lines: lines, threshold: splitThreshold)
        if chunks.count == 1 {
            let result = try await call(system: systemPrompt, user: Self.userMessage(context: context, body: chunks[0], part: nil))
            return MinutesResult(markdown: result.text, usage: result.usage, servedModel: result.servedModel)
        }

        var usage = ClaudeUsage()
        var partials: [String] = []
        var servedModel: String?
        for (index, chunk) in chunks.enumerated() {
            let part = (index + 1, chunks.count)
            let result = try await call(system: systemPrompt, user: Self.userMessage(context: context, body: chunk, part: part))
            usage = usage + result.usage
            partials.append("<part index=\"\(index + 1)\">\n\(result.text)\n</part>")
        }

        let mergeUser = """
        以下は、1つの長い会議の文字起こしを\(chunks.count)つに分けて、それぞれから作った議事録です（時系列順）。
        これらを1つの議事録に統合してください。重複はまとめ、後半で覆った決定は最終的な内容を採用し、
        決定事項・ToDo・論点・確認事項は漏らさず残してください。出力形式とルールは同じです。

        会議タイトル：\(context.title)
        日時：\(Self.dateText(context.date))

        \(partials.joined(separator: "\n\n"))
        """
        let merged = try await call(system: systemPrompt, user: mergeUser)
        usage = usage + merged.usage
        servedModel = merged.servedModel
        return MinutesResult(markdown: merged.text, usage: usage, servedModel: servedModel)
    }

    private func call(system: String, user: String) async throws -> ClaudeResult {
        try await Retry.run(onRetry: { attempt, error in
            appLog.warning("Claudeへの送信を再試行します（\(attempt)回目）：\(Redactor.mask(error.localizedDescription), privacy: .public)")
        }) {
            try await client.generate(model: model, system: system, user: user)
        }
    }

    static func userMessage(context: Context, body: String, part: (Int, Int)?) -> String {
        var header = """
        会議タイトル：\(context.title)
        日時：\(dateText(context.date))
        長さ：\(lengthText(context.durationSeconds))
        """
        if let part {
            header += "\n注意：これは会議全体を\(part.1)つに分けたうちの第\(part.0)部です。この部分に含まれる内容だけで議事録を作ってください。"
        }
        return "\(header)\n\n<transcript>\n\(body)\n</transcript>"
    }

    static func lengthText(_ seconds: Double) -> String {
        seconds < 90 ? "約\(max(1, Int(seconds.rounded())))秒" : "約\(Int((seconds / 60).rounded()))分"
    }

    /// 発言の行の途中で切らないように、行単位でほぼ均等に分ける。
    static func split(lines: [String], threshold: Int) -> [String] {
        let total = lines.reduce(0) { $0 + $1.count + 1 }
        guard total > threshold, lines.count > 1 else { return [lines.joined(separator: "\n")] }
        let parts = Int((Double(total) / Double(threshold)).rounded(.up))
        let target = total / parts + 1
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            if size + line.count > target, !current.isEmpty, chunks.count < parts - 1 {
                chunks.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日（E） HH:mm"
        return formatter.string(from: date)
    }
}
