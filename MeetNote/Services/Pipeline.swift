import AVFoundation
import Foundation

enum PipelineStage: String {
    case converting = "変換中"
    case transcribing = "文字起こし中"
    case summarizing = "議事録作成中"
}

enum AudioSource {
    /// 既存の音声・動画ファイル。
    case file(URL)
    /// アプリで録音した生データ（マイクとシステム音声が別ファイル）。
    case recording(RecordingFiles)

    var displayName: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .recording: return "録音"
        }
    }
}

struct PipelineInput {
    var source: AudioSource
    var title: String
    /// 会議の日時。ファイル読み込みの場合はファイルの作成日時を使う。
    var date: Date
}

struct PipelineOutput {
    /// できあがった議事録（議事録と発言録を1つにまとめた Markdown）。
    var documentURL: URL
    /// 議事録と音声が入っている、この会議のフォルダ。
    var folder: URL
    var durationSeconds: Double
    var estimatedCostUSD: Double?
}

/// 処理が途中で失敗したことを表す。`folder`（作業用フォルダ）には、そこまでに作れたファイル（音声など）が残っている。
struct PipelineFailure: LocalizedError {
    let folder: URL?
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

/// 音声ファイル → 圧縮 → 文字起こし → 発言録 → 議事録 → 保存、の一連の処理。
struct Pipeline {
    let settings: SettingsSnapshot
    let provider: TranscriptionProvider
    let claude: ClaudeClient
    let pricing: Pricing

    func run(_ input: PipelineInput, progress: @escaping (PipelineStage, String?) -> Void) async throws -> PipelineOutput {
        var folder: URL?
        do {
            let created = try Self.makeFolder(root: Self.workRoot, date: input.date, title: input.title)
            folder = created
            return try await run(input, folder: created, progress: progress)
        } catch {
            throw PipelineFailure(folder: folder, underlying: error)
        }
    }

    private func run(_ input: PipelineInput, folder: URL, progress: @escaping (PipelineStage, String?) -> Void) async throws -> PipelineOutput {
        let displayTitle = input.title.isEmpty ? "会議 \(MinutesGenerator.dateText(input.date))" : input.title

        // 1. 圧縮
        progress(.converting, nil)
        let audioURL = folder.appendingPathComponent("audio.m4a")
        let duration: Double
        switch input.source {
        case .file(let url):
            duration = try await AudioConverter.convert(source: url, destination: audioURL)
        case .recording(let recording):
            let mixed = try await RecordingMixer.composition(of: [recording.micURL, recording.systemURL])
            duration = try await AudioConverter.convert(asset: mixed, destination: audioURL)
            // 圧縮した音声を保存できたので、録音の生データは消す。
            recording.delete()
        }
        guard duration > 0.1 else { throw AppError("音声が短すぎます。") }

        // 2. 文字起こし（上限を超える長さなら分割して送り、結果をつなぐ）
        progress(.transcribing, nil)
        let parts = try await makeParts(audioURL: audioURL, duration: duration)
        defer { parts.filter { $0.isTemporary }.forEach { try? FileManager.default.removeItem(at: $0.url) } }

        var segments: [TranscriptSegment] = []
        var rawParts: [Data] = []
        for (index, part) in parts.enumerated() {
            if parts.count > 1 { progress(.transcribing, "\(index + 1)/\(parts.count)") }
            let result = try await Retry.run(onRetry: { attempt, error in
                progress(.transcribing, "再試行 \(attempt)/2")
                appLog.warning("文字起こしを再試行します（\(attempt)回目）：\(Redactor.mask(error.localizedDescription), privacy: .public)")
            }) {
                try await provider.transcribe(TranscriptionRequest(fileURL: part.url))
            }
            rawParts.append(result.rawJSON)
            for var segment in result.transcript.segments {
                segment.start += part.offset
                segment.end += part.offset
                // 分割した場合、話者ラベルは区間ごとに振り直されるので、区間番号を付けて区別する。
                if parts.count > 1 { segment.speaker = "\(index + 1)-\(segment.speaker)" }
                segments.append(segment)
            }
        }
        try Self.rawJSON(rawParts, offsets: parts.map(\.offset)).write(to: folder.appendingPathComponent("transcript.json"))

        let transcript = NormalizedTranscript(segments: segments)
        let lines = TranscriptFormatter.lines(transcript)
        guard !lines.isEmpty else {
            throw AppError("音声から発言を検出できませんでした。")
        }

        // 3. 議事録
        progress(.summarizing, nil)
        let generator = MinutesGenerator(client: claude, model: settings.claudeModel, systemPrompt: settings.minutesPrompt)
        let minutes = try await generator.generate(
            lines: lines,
            context: .init(title: displayTitle, date: input.date, durationSeconds: duration)
        )

        // 4. 保存：会議ごとのフォルダを作り、議事録（発言録つき）と音声の2つだけを置く
        let outputFolder = try Self.makeFolder(root: settings.saveRoot, date: input.date, title: input.title)
        let documentURL = outputFolder.appendingPathComponent(Self.documentName)
        let savedAudioURL = outputFolder.appendingPathComponent(Self.audioName)
        try Self.document(minutes: minutes.markdown, lines: lines)
            .write(to: documentURL, atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: audioURL, to: savedAudioURL)
        // 作業用のファイル（文字起こしの生データなど）は、成功したら残さない。
        try? FileManager.default.removeItem(at: folder)

        let sttCost = pricing.sttCost(model: provider.modelID, seconds: duration)
        let billedModel = minutes.servedModel.flatMap { pricing.claudeUSDPerMTok[$0] == nil ? nil : $0 } ?? settings.claudeModel
        let claudeCost = pricing.claudeCost(
            model: billedModel,
            inputTokens: minutes.usage.inputTokens,
            outputTokens: minutes.usage.outputTokens
        )
        let total: Double? = (sttCost != nil && claudeCost != nil) ? sttCost! + claudeCost! : nil
        return PipelineOutput(documentURL: documentURL, folder: outputFolder, durationSeconds: duration, estimatedCostUSD: total)
    }

    // MARK: - 分割

    private struct Part {
        var url: URL
        var offset: Double
        var isTemporary: Bool
    }

    private func makeParts(audioURL: URL, duration: Double) async throws -> [Part] {
        let limit = provider.maxDurationSeconds
        guard duration > limit else { return [Part(url: audioURL, offset: 0, isTemporary: false)] }

        let count = Int((duration / limit).rounded(.up))
        let length = duration / Double(count)
        var parts: [Part] = []
        for index in 0..<count {
            let offset = Double(index) * length
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("meetnote-part-\(UUID().uuidString).m4a")
            let range = CMTimeRange(
                start: CMTime(seconds: offset, preferredTimescale: 600),
                duration: CMTime(seconds: min(length, duration - offset), preferredTimescale: 600)
            )
            try await AudioConverter.convert(source: audioURL, destination: url, timeRange: range)
            parts.append(Part(url: url, offset: offset, isTemporary: true))
        }
        return parts
    }

    /// transcript.json の中身。分割しなかった場合はAPIレスポンスそのもの。
    static func rawJSON(_ parts: [Data], offsets: [Double]) throws -> Data {
        if parts.count == 1 { return parts[0] }
        let objects: [[String: Any]] = try zip(parts, offsets).map { data, offset in
            ["offset_seconds": offset, "response": try JSONSerialization.jsonObject(with: data)]
        }
        return try JSONSerialization.data(withJSONObject: ["parts": objects], options: [.prettyPrinted])
    }

    // MARK: - 保存先

    /// 処理中の作業用フォルダの置き場所。成功すれば消え、失敗したときだけ音声が残る。
    static var workRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MeetNote/Work")
    }

    /// 議事録の本文の後ろに、発言録を付ける。
    static func document(minutes: String, lines: [String]) -> String {
        "\(minutes)\n\n---\n\n## 発言録\n\n\(lines.joined(separator: "\n\n"))\n"
    }

    static let documentName = "議事録.md"
    static let audioName = "音声.m4a"

    static func folderName(date: Date, title: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let stamp = formatter.string(from: date)
        let cleaned = sanitize(title)
        return cleaned.isEmpty ? stamp : "\(stamp)_\(cleaned)"
    }

    /// フォルダ名に使えない文字を取り除く。
    static func sanitize(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(trimmed.prefix(60))
    }

    static func makeFolder(root: URL, date: Date, title: String) throws -> URL {
        let base = folderName(date: date, title: title)
        var candidate = root.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        do {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        } catch {
            throw AppError("フォルダを作れませんでした（\(root.path)）：\(error.localizedDescription)")
        }
        return candidate
    }
}
