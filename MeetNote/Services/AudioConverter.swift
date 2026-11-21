import AVFoundation

/// 音声・動画ファイルを、文字起こし用の小さな m4a（モノラル・16kHz・AAC）に変換する。
enum AudioConverter {
    static let sampleRate: Double = 16_000
    static let bitRate = 32_000

    static func duration(of url: URL) async throws -> Double {
        let duration = try await AVURLAsset(url: url).load(.duration)
        return duration.seconds.isFinite ? duration.seconds : 0
    }

    /// `source` の音声を `destination` に書き出し、書き出した長さ（秒）を返す。
    /// `timeRange` を渡すと、その区間だけを書き出す。
    @discardableResult
    static func convert(source: URL, destination: URL, timeRange: CMTimeRange? = nil) async throws -> Double {
        try await convert(asset: AVURLAsset(url: source), destination: destination, timeRange: timeRange)
    }

    /// 複数の音声トラックを持つ素材（録音したマイクとシステム音声など）は、1本に混ぜて書き出す。
    @discardableResult
    static func convert(asset: AVAsset, destination: URL, timeRange: CMTimeRange? = nil) async throws -> Double {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AppError("ファイルを読み込めませんでした：\(error.localizedDescription)")
        }
        guard !tracks.isEmpty else {
            throw AppError("このファイルには音声が含まれていません。")
        }
        let assetDuration = try await asset.load(.duration)

        nonisolated(unsafe) let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        nonisolated(unsafe) let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw AppError("音声の読み取りを準備できませんでした。") }
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        nonisolated(unsafe) let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw AppError("音声の書き出しを準備できませんでした。") }
        writer.add(input)

        guard reader.startReading() else {
            throw AppError("音声を読み取れませんでした：\(reader.error?.localizedDescription ?? "不明なエラー")")
        }
        guard writer.startWriting() else {
            throw AppError("音声を書き出せませんでした：\(writer.error?.localizedDescription ?? "不明なエラー")")
        }
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)

        let queue = DispatchQueue(label: "local.meetnote.convert")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let buffer = output.copyNextSampleBuffer() {
                        if !input.append(buffer) {
                            reader.cancelReading()
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                    } else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        if reader.status == .failed || reader.status == .cancelled {
            writer.cancelWriting()
            let reason = reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "不明なエラー"
            throw AppError("音声の変換に失敗しました：\(reason)")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AppError("音声の変換に失敗しました：\(writer.error?.localizedDescription ?? "不明なエラー")")
        }

        let seconds = (timeRange?.duration ?? assetDuration).seconds
        return seconds.isFinite ? seconds : 0
    }
}
