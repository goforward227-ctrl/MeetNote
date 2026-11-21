import Foundation

/// 文字起こしの共通形式。どのプロバイダーの結果もこの形に正規化する。
struct TranscriptSegment: Codable, Equatable {
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

struct NormalizedTranscript: Codable, Equatable {
    var segments: [TranscriptSegment]
}

struct TranscriptionRequest {
    var fileURL: URL
    var languageCode = "ja"
    var diarize = true
    /// 用語集（フェーズ3で使う）。空なら送らない。
    var keyterms: [String] = []
}

struct TranscriptionResult {
    /// APIレスポンスの生データ（transcript.json に保存する）。
    var rawJSON: Data
    var transcript: NormalizedTranscript
}

/// 文字起こしAPIの差し替え口。ElevenLabs 以外（OpenAI など）を足すときはこれを実装する。
protocol TranscriptionProvider {
    var providerName: String { get }
    var modelID: String { get }
    /// 1回のリクエストで送れる音声の長さの上限（秒）。超える場合は呼び出し側が分割する。
    var maxDurationSeconds: Double { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

enum SpeakerLabel {
    /// 0始まりの番号を A, B, C… に変える。27人目以降は番号で表す。
    static func label(for index: Int) -> String {
        index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : "\(index + 1)"
    }
}

enum TranscriptFormatter {
    /// 同じ話者が連続する発言を1ブロックにまとめる。
    static func mergedBlocks(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var blocks: [TranscriptSegment] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = blocks.last, last.speaker == segment.speaker {
                last.text += needsSpace(between: last.text, and: text) ? " " + text : text
                last.end = segment.end
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(TranscriptSegment(speaker: segment.speaker, start: segment.start, end: segment.end, text: text))
            }
        }
        return blocks
    }

    /// `[00:12:34] 話者A：発言内容` の形式の行を作る。
    static func lines(_ transcript: NormalizedTranscript) -> [String] {
        mergedBlocks(transcript.segments).map {
            "[\(timestamp($0.start))] 話者\($0.speaker)：\($0.text)"
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// 英単語どうしをつなぐときだけ空白を入れる（日本語は詰める）。
    private static func needsSpace(between left: String, and right: String) -> Bool {
        guard let a = left.unicodeScalars.last, let b = right.unicodeScalars.first else { return false }
        return a.isASCII && b.isASCII && !CharacterSet.whitespaces.contains(a)
    }
}
