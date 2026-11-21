import Foundation

/// ElevenLabs Speech to Text（Scribe）で文字起こしする。
/// 仕様：https://elevenlabs.io/docs/api-reference/speech-to-text/convert
struct ElevenLabsProvider: TranscriptionProvider {
    let providerName = "ElevenLabs"
    let modelID: String
    /// APIの上限は15時間・5GB。余裕を見て14時間で分割する。
    let maxDurationSeconds: Double = 14 * 3600

    private let apiKey: String
    private let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    init(apiKey: String, modelID: String) {
        self.apiKey = apiKey
        self.modelID = modelID
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        var fields: [(String, String)] = [
            ("model_id", modelID),
            ("language_code", request.languageCode),
            ("diarize", request.diarize ? "true" : "false"),
            ("timestamps_granularity", "word"),
            ("tag_audio_events", "false"),
        ]
        for term in request.keyterms {
            fields.append(("keyterms", term))
        }

        let boundary = "meetnote-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(boundary).body")
        try Self.writeMultipartBody(to: bodyURL, boundary: boundary, fields: fields, fileURL: request.fileURL)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await Self.session.upload(for: urlRequest, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(service: providerName, status: nil, message: "応答を受け取れませんでした。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(
                service: providerName,
                status: http.statusCode,
                message: Redactor.mask(APIErrorBody.message(from: data), secrets: [apiKey]),
                retryAfter: http.retryAfterSeconds
            )
        }
        return TranscriptionResult(rawJSON: data, transcript: try Self.normalize(data))
    }

    /// 文字起こしは音声の長さに応じて数分かかるので、応答待ちの時間を長く取る。
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30 * 60
        configuration.timeoutIntervalForResource = 3 * 3600
        return URLSession(configuration: configuration)
    }()

    // MARK: - リクエスト本文

    /// 音声をメモリに載せずに送れるよう、multipart の本文を一時ファイルに書く。
    static func writeMultipartBody(to bodyURL: URL, boundary: String, fields: [(String, String)], fileURL: URL) throws {
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: bodyURL)
        defer { try? out.close() }

        for (name, value) in fields {
            try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n"
        try out.write(contentsOf: Data(header.utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    // MARK: - レスポンスの正規化

    private struct Response: Decodable {
        let words: [Word]?
    }

    private struct Word: Decodable {
        let text: String
        let type: String?
        let start: Double?
        let end: Double?
        let speaker_id: String?
    }

    /// 話者が替わるか、これ以上の無音が空いたら、別の発言として区切る（秒）。
    static let pauseThreshold: Double = 2.0

    /// ElevenLabs のレスポンス（単語の列）を、話者ごとの発言の列に直す。
    static func normalize(_ data: Data) throws -> NormalizedTranscript {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AppError("文字起こし結果を読み取れませんでした：\(error.localizedDescription)")
        }

        var speakerLabels: [String: String] = [:]
        var segments: [TranscriptSegment] = []
        var current: TranscriptSegment?

        func flush() {
            if var segment = current {
                segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.text.isEmpty { segments.append(segment) }
            }
            current = nil
        }

        for word in response.words ?? [] {
            let type = word.type ?? "word"
            if type == "audio_event" { continue }
            if type == "spacing" {
                current?.text += word.text
                continue
            }

            let speakerID = word.speaker_id ?? "speaker_0"
            if speakerLabels[speakerID] == nil {
                speakerLabels[speakerID] = SpeakerLabel.label(for: speakerLabels.count)
            }
            let speaker = speakerLabels[speakerID]!
            let start = word.start ?? current?.end ?? 0
            let end = word.end ?? start

            if let segment = current, segment.speaker == speaker, start - segment.end <= pauseThreshold {
                current?.text += word.text
                current?.end = max(segment.end, end)
            } else {
                flush()
                current = TranscriptSegment(speaker: speaker, start: start, end: end, text: word.text)
            }
        }
        flush()
        return NormalizedTranscript(segments: segments)
    }
}
