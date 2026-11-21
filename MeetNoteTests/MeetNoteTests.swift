import AVFoundation
import SwiftUI
import XCTest
@testable import MeetNote

final class TranscriptTests: XCTestCase {
    func testNormalizeGroupsWordsBySpeakerAndPause() throws {
        let json = """
        {"language_code":"jpn","text":"","words":[
          {"text":"おはよう","type":"word","start":0.0,"end":0.5,"speaker_id":"speaker_0"},
          {"text":"ございます","type":"word","start":0.5,"end":1.0,"speaker_id":"speaker_0"},
          {"text":"(笑い)","type":"audio_event","start":1.0,"end":1.2,"speaker_id":"speaker_0"},
          {"text":"はい","type":"word","start":1.5,"end":1.8,"speaker_id":"speaker_1"},
          {"text":"では","type":"word","start":10.0,"end":10.3,"speaker_id":"speaker_1"},
          {"text":"Hello","type":"word","start":10.4,"end":10.6,"speaker_id":"speaker_1"},
          {"text":" ","type":"spacing","start":10.6,"end":10.6,"speaker_id":"speaker_1"},
          {"text":"world","type":"word","start":10.6,"end":10.9,"speaker_id":"speaker_1"}
        ]}
        """
        let transcript = try ElevenLabsProvider.normalize(Data(json.utf8))
        XCTAssertEqual(transcript.segments, [
            TranscriptSegment(speaker: "A", start: 0.0, end: 1.0, text: "おはようございます"),
            TranscriptSegment(speaker: "B", start: 1.5, end: 1.8, text: "はい"),
            TranscriptSegment(speaker: "B", start: 10.0, end: 10.9, text: "ではHello world"),
        ])
    }

    func testLinesMergeConsecutiveSpeakerAndFormatTimestamp() {
        let transcript = NormalizedTranscript(segments: [
            TranscriptSegment(speaker: "A", start: 754, end: 760, text: "予算は300万円です。"),
            TranscriptSegment(speaker: "A", start: 765, end: 770, text: "来週までに決めます。"),
            TranscriptSegment(speaker: "B", start: 3725, end: 3730, text: "承知しました。"),
        ])
        XCTAssertEqual(TranscriptFormatter.lines(transcript), [
            "[00:12:34] 話者A：予算は300万円です。来週までに決めます。",
            "[01:02:05] 話者B：承知しました。",
        ])
    }

    func testSpeakerLabels() {
        XCTAssertEqual(SpeakerLabel.label(for: 0), "A")
        XCTAssertEqual(SpeakerLabel.label(for: 25), "Z")
        XCTAssertEqual(SpeakerLabel.label(for: 26), "27")
    }
}

final class ClaudeStreamTests: XCTestCase {
    private func feed(_ events: [String]) throws -> ClaudeStreamAccumulator {
        var accumulator = ClaudeStreamAccumulator()
        for event in events { try accumulator.consume(Data(event.utf8)) }
        return accumulator
    }

    func testAccumulatesTextAndUsage() throws {
        let result = try feed([
            #"{"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":100,"cache_read_input_tokens":20,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"考え中"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            ##"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"# 議事録"}}"##,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\n本文"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#,
            #"{"type":"message_stop"}"#,
        ])
        XCTAssertEqual(result.text, "# 議事録\n本文")
        XCTAssertEqual(result.usage, ClaudeUsage(inputTokens: 120, outputTokens: 42))
        XCTAssertEqual(result.stopReason, "end_turn")
        XCTAssertEqual(result.model, "claude-sonnet-5-5")
    }

    func testFallbackDiscardsPartialOutput() throws {
        let result = try feed([
            #"{"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":10}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"途中まで"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-sonnet-5-5"},"to":{"model":"claude-sonnet-5"}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"やり直し"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
        ])
        XCTAssertEqual(result.text, "やり直し")
        XCTAssertEqual(result.model, "claude-sonnet-5")
    }

    func testErrorEventThrows() {
        XCTAssertThrowsError(try feed([#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])) { error in
            XCTAssertTrue(Retry.isRetryable(error))
        }
    }
}

final class SupportTests: XCTestCase {
    func testMaskHidesKeys() {
        let key = "sk_0123456789abcdef0123456789abcdef"
        let masked = Redactor.mask("invalid key \(key) / sk-ant-api03-AbCdEfGh12345678", secrets: [key])
        XCTAssertFalse(masked.contains("0123456789abcdef"))
        XCTAssertFalse(masked.contains("AbCdEfGh"))
    }

    func testRetryability() {
        XCTAssertTrue(APIError(service: "x", status: 429, message: "").isRetryable)
        XCTAssertTrue(APIError(service: "x", status: 503, message: "").isRetryable)
        XCTAssertFalse(APIError(service: "x", status: 401, message: "").isRetryable)
        XCTAssertFalse(APIError(service: "x", status: 422, message: "").isRetryable)
    }

    func testFolderName() {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute) = (2026, 11, 21, 10, 30)
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(Pipeline.folderName(date: date, title: "A社/定例: 11月"), "2026-11-21_1030_A社 定例 11月")
        XCTAssertEqual(Pipeline.folderName(date: date, title: "  "), "2026-11-21_1030")
    }

    func testLengthText() {
        XCTAssertEqual(MinutesGenerator.lengthText(6.8), "約7秒")
        XCTAssertEqual(MinutesGenerator.lengthText(1800), "約30分")
    }

    func testDocumentCombinesMinutesAndTranscript() throws {
        let text = Pipeline.document(minutes: "# 定例\n\n## 要約\n- 決まった", lines: ["[00:00:01] 話者A：はい", "[00:00:05] 話者B：了解"])
        XCTAssertEqual(text, "# 定例\n\n## 要約\n- 決まった\n\n---\n\n## 発言録\n\n[00:00:01] 話者A：はい\n\n[00:00:05] 話者B：了解\n")

        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute) = (2026, 11, 21, 10, 30)
        let date = Calendar.current.date(from: components)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetnote-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // 同じ日時・同じタイトルの会議は、別のフォルダになる。
        XCTAssertEqual(try Pipeline.makeFolder(root: root, date: date, title: "定例").lastPathComponent, "2026-11-21_1030_定例")
        XCTAssertEqual(try Pipeline.makeFolder(root: root, date: date, title: "定例").lastPathComponent, "2026-11-21_1030_定例-2")
    }

    func testSplitKeepsAllLines() {
        let lines = (0..<100).map { "[00:00:\(String(format: "%02d", $0 % 60))] 話者A：発言\($0)" }
        let chunks = MinutesGenerator.split(lines: lines, threshold: 800)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(separator: "\n"), lines.joined(separator: "\n"))
        XCTAssertEqual(MinutesGenerator.split(lines: lines, threshold: 1_000_000).count, 1)
    }

    func testMultipartBody() throws {
        let directory = FileManager.default.temporaryDirectory
        let file = directory.appendingPathComponent("meetnote-test-\(UUID().uuidString).bin")
        let body = directory.appendingPathComponent("meetnote-test-\(UUID().uuidString).body")
        defer { [file, body].forEach { try? FileManager.default.removeItem(at: $0) } }
        try Data("AUDIO".utf8).write(to: file)

        try ElevenLabsProvider.writeMultipartBody(to: body, boundary: "B", fields: [("model_id", "scribe_v3")], fileURL: file)
        let text = String(decoding: try Data(contentsOf: body), as: UTF8.self)
        XCTAssertEqual(text, "--B\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\nscribe_v3\r\n--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nAUDIO\r\n--B--\r\n")
    }
}

final class AudioConverterTests: XCTestCase {
    /// 44.1kHz・ステレオの wav を作り、モノラル・16kHz の m4a に変換できることを確かめる。
    func testConvertsToSmallMonoM4A() async throws {
        let directory = FileManager.default.temporaryDirectory
        let source = directory.appendingPathComponent("meetnote-test-\(UUID().uuidString).wav")
        let destination = directory.appendingPathComponent("meetnote-test-\(UUID().uuidString).m4a")
        defer { [source, destination].forEach { try? FileManager.default.removeItem(at: $0) } }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let seconds = 5.0
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = sin(Float(frame) * 2 * .pi * 440 / 44_100) * 0.3
            }
        }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }

        let duration = try await AudioConverter.convert(source: source, destination: destination)
        XCTAssertEqual(duration, seconds, accuracy: 0.1)

        let asset = AVURLAsset(url: destination)
        let track = try await asset.loadTracks(withMediaType: .audio).first!
        let description = try await track.load(.formatDescriptions).first!
        let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)!.pointee
        XCTAssertEqual(stream.mSampleRate, 16_000)
        XCTAssertEqual(stream.mChannelsPerFrame, 1)
        XCTAssertEqual(stream.mFormatID, kAudioFormatMPEG4AAC)
        let written = try await asset.load(.duration).seconds
        XCTAssertEqual(written, seconds, accuracy: 0.2)

        // 後半2秒だけを切り出せること（長時間の音声を分割して送るときに使う）。
        let part = directory.appendingPathComponent("meetnote-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: part) }
        let range = CMTimeRange(start: CMTime(seconds: 3, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600))
        try await AudioConverter.convert(source: destination, destination: part, timeRange: range)
        let partDuration = try await AVURLAsset(url: part).load(.duration).seconds
        XCTAssertEqual(partDuration, 2, accuracy: 0.3)
    }
}

final class RecordingTests: XCTestCase {
    private func tone(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double, amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = sin(Float(frame) * 2 * .pi * 440 / Float(sampleRate)) * amplitude
            }
        }
        return buffer
    }

    /// 48kHz の入力を 16kHz・モノラルで書き、途切れた区間は無音で埋めて時間軸を保つこと。
    /// さらに、2トラックを混ぜて1本の m4a にできること。
    func testTrackWriterKeepsTimelineAndMixes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meetnote-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = RecordingFiles(directory: directory, startedAt: Date())

        // マイク：0〜1秒と、3〜4秒（間の2秒は届かなかった想定）。途中でステレオの機器に切り替わる。
        let mic = TrackWriter(url: recording.micURL)
        for index in 0..<10 {
            try mic.append(tone(sampleRate: 48_000, channels: 1, seconds: 0.1, amplitude: 0.3), at: Double(index) * 0.1)
        }
        for index in 0..<10 {
            try mic.append(tone(sampleRate: 44_100, channels: 2, seconds: 0.1, amplitude: 0.3), at: 3 + Double(index) * 0.1)
        }
        XCTAssertGreaterThan(mic.level, 0.1)
        mic.close()

        // システム音声：0.5秒遅れて始まり、6秒まで。
        let system = TrackWriter(url: recording.systemURL)
        for index in 0..<55 {
            try system.append(tone(sampleRate: 48_000, channels: 1, seconds: 0.1, amplitude: 0.2), at: 0.5 + Double(index) * 0.1)
        }
        system.close()

        let micDuration = try await AudioConverter.duration(of: recording.micURL)
        let systemDuration = try await AudioConverter.duration(of: recording.systemURL)
        XCTAssertEqual(micDuration, 4.0, accuracy: 0.1)
        XCTAssertEqual(systemDuration, 6.0, accuracy: 0.1)

        // 無音で埋めた区間（1.5〜2.5秒）は本当に無音であること。
        let file = try AVAudioFile(forReading: recording.micURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        file.framePosition = 24_000
        let gap = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)!
        try file.read(into: gap, frameCount: 16_000)
        let peak = (0..<Int(gap.frameLength)).map { abs(gap.floatChannelData![0][$0]) }.max() ?? 1
        XCTAssertEqual(peak, 0, accuracy: 0.001)

        let mixed = try await RecordingMixer.composition(of: [recording.micURL, recording.systemURL])
        let output = directory.appendingPathComponent("audio.m4a")
        let duration = try await AudioConverter.convert(asset: mixed, destination: output)
        XCTAssertEqual(duration, 6.0, accuracy: 0.1)
        let written = try await AudioConverter.duration(of: output)
        XCTAssertEqual(written, 6.0, accuracy: 0.2)
    }

    func testMixerRejectsEmptyRecording() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("meetnote-missing-\(UUID().uuidString).caf")
        do {
            _ = try await RecordingMixer.composition(of: [missing])
            XCTFail("エラーになるはず")
        } catch {}
    }
}

final class KeyStoreTests: XCTestCase {
    func testSavesKeysToOwnerOnlyFile() throws {
        let original = KeyStore.fileURL
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meetnote-test-\(UUID().uuidString)")
        KeyStore.fileURL = directory.appendingPathComponent("keys.json")
        defer {
            KeyStore.fileURL = original
            try? FileManager.default.removeItem(at: directory)
        }

        try KeyStore.set("first-key", for: .elevenLabs)
        try KeyStore.set("second-key", for: .elevenLabs)
        XCTAssertEqual(KeyStore.get(.elevenLabs), "second-key")
        XCTAssertTrue(KeyStore.exists(.elevenLabs))

        let permissions = try FileManager.default.attributesOfItem(atPath: KeyStore.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["keys.json"])
    }
}

/// README 用の画面写真を、見本のデータで描き出す。
/// `TEST_RUNNER_MEETNOTE_SCREENSHOTS=<出力先>` を付けてテストを実行したときだけ動く。
@MainActor
final class ScreenshotTests: XCTestCase {
    func testRenderScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["MEETNOTE_SCREENSHOTS"] else {
            throw XCTSkip("画面写真の出力先が指定されていません。")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let state = AppState.shared
        let settings = SettingsStore.shared
        let savedSystemAudio = settings.recordSystemAudio
        defer {
            settings.recordSystemAudio = savedSystemAudio
            state.applyPreview()
        }

        let done = AppState.Completed(
            title: "A社 定例",
            output: PipelineOutput(
                documentURL: URL(fileURLWithPath: "/tmp/議事録.md"),
                folder: URL(fileURLWithPath: "/tmp"),
                durationSeconds: 47 * 60,
                estimatedCostUSD: 0.27
            )
        )
        let scenes: [(String, () -> Void)] = [
            ("idle", { settings.recordSystemAudio = false; state.applyPreview() }),
            ("recording", { settings.recordSystemAudio = false; state.applyPreview(recordingSeconds: 12 * 60 + 34) }),
            ("done", { state.applyPreview(completed: done) }),
        ]

        for (name, configure) in scenes {
            configure()
            // メニューバーから開くウィンドウに似せて、角丸と細い枠を付ける。
            let content = MenuContentView()
                .environmentObject(state)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.15)))
            let hosting = NSHostingView(rootView: content)
            let size = hosting.fittingSize
            let window = NSWindow(
                contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.appearance = NSAppearance(named: .aqua)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = hosting
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))

            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
        }
    }
}
