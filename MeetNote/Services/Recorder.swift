import AVFoundation
import ScreenCaptureKit

/// 録音中の生データの置き場所。処理が終わって audio.m4a ができたら削除する。
struct RecordingFiles: Equatable {
    var directory: URL
    var startedAt: Date

    var micURL: URL { directory.appendingPathComponent("mic.caf") }
    var systemURL: URL { directory.appendingPathComponent("system.caf") }

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MeetNote/Recordings")
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func create(startedAt: Date = Date()) throws -> RecordingFiles {
        let directory = root.appendingPathComponent(nameFormatter.string(from: startedAt))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RecordingFiles(directory: directory, startedAt: startedAt)
    }

    /// 処理されずに残っている録音（録音中にアプリが落ちた場合など）を探す。
    static func leftovers(excluding active: [URL] = []) -> [RecordingFiles] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let activePaths = Set(active.map(\.standardizedFileURL.path))
        return contents
            .filter { !activePaths.contains($0.standardizedFileURL.path) }
            .compactMap { directory in
                guard let date = nameFormatter.date(from: directory.lastPathComponent) else { return nil }
                return RecordingFiles(directory: directory, startedAt: date)
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func delete() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 録音のおおよその長さ（秒）。ファイルサイズから求める（16kHz・16bit・モノラル＝1秒あたり32,000バイト）。
    var approximateDuration: Double {
        let sizes = [micURL, systemURL].map { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }
        return Double(sizes.max() ?? 0) / 32_000
    }
}

/// 1トラック分の音声を、モノラル・16kHz の CAF ファイルに書き足していく。
/// CAF（非圧縮）は書き込み途中でアプリが落ちても、そこまでの音声を読める。
final class TrackWriter {
    static let sampleRate: Double = 16_000
    static let processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    let url: URL
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private(set) var framesWritten: AVAudioFramePosition = 0
    /// 直近に書いた音声の大きさ（0〜1）。レベル表示に使う。
    private(set) var level: Float = 0

    init(url: URL) {
        self.url = url
    }

    /// `position` は録音開始からの経過秒。前回の続きより先の時刻なら、間を無音で埋めて時間軸を保つ。
    func append(_ buffer: AVAudioPCMBuffer, at position: Double) throws {
        guard buffer.frameLength > 0 else { return }
        if file == nil {
            file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: Self.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }

        let gap = position - Double(framesWritten) / Self.sampleRate
        if gap > 0.05 {
            try writeSilence(frames: AVAudioFrameCount(gap * Self.sampleRate))
        }

        if converter == nil || inputFormat != buffer.format {
            guard let created = AVAudioConverter(from: buffer.format, to: Self.processingFormat) else {
                throw AppError("録音の形式を変換できませんでした。")
            }
            created.downmix = buffer.format.channelCount > 1
            converter = created
            inputFormat = buffer.format
        }

        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.processingFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        converter!.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        guard output.frameLength > 0 else { return }

        try file!.write(from: output)
        framesWritten += AVAudioFramePosition(output.frameLength)
        level = Self.rms(output)
    }

    private func writeSilence(frames: AVAudioFrameCount) throws {
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, 16_000)
            guard let silence = AVAudioPCMBuffer(pcmFormat: Self.processingFormat, frameCapacity: count) else { return }
            silence.frameLength = count
            memset(silence.floatChannelData![0], 0, Int(count) * MemoryLayout<Float>.size)
            try file!.write(from: silence)
            framesWritten += AVAudioFramePosition(count)
            remaining -= count
        }
    }

    func close() {
        file = nil
        converter = nil
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            sum += samples[index] * samples[index]
        }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}

/// 会議を録音する。
/// - マイクだけ（対面の会議）：AVCaptureSession で録る。必要な許可はマイクだけ。
/// - Macの音も録る（オンライン会議）：ScreenCaptureKit の1つのストリームから、マイクとシステム音声を
///   別々のファイルに録る。同じストリームなので2つのトラックの時刻が揃う。
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// マイクとシステム音声の大きさ（0〜1）。メインスレッドで呼ばれる。
    var onLevels: ((_ mic: Float, _ system: Float) -> Void)?
    /// 録音が外的な理由で止まったとき（権限の取り消しなど）。メインスレッドで呼ばれる。
    var onInterrupted: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "local.meetnote.recorder")
    private var stream: SCStream?
    private var session: AVCaptureSession?
    private var observers: [NSObjectProtocol] = []
    private var files: RecordingFiles?
    private var micWriter: TrackWriter?
    private var systemWriter: TrackWriter?
    private var origin: CMTime?
    private var lastLevelReport = Date.distantPast
    private var writeFailed = false

    func start(includeSystemAudio: Bool) async throws -> RecordingFiles {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw AppError("マイクの使用が許可されていません。システム設定 →「プライバシーとセキュリティ」→「マイク」で MeetNote を許可してください。")
        }
        return includeSystemAudio ? try await startWithSystemAudio() : try startMicrophoneOnly()
    }

    /// 録音を止めて、ファイルを閉じる。
    @discardableResult
    func stop() async -> RecordingFiles? {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        session?.stopRunning()
        session = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        return queue.sync {
            micWriter?.close()
            systemWriter?.close()
            micWriter = nil
            systemWriter = nil
            let finished = files
            files = nil
            return finished
        }
    }

    private func prepare(_ created: RecordingFiles, withSystemTrack: Bool) {
        queue.sync {
            files = created
            micWriter = TrackWriter(url: created.micURL)
            systemWriter = withSystemTrack ? TrackWriter(url: created.systemURL) : nil
            origin = nil
            writeFailed = false
        }
    }

    // MARK: - マイクだけ

    private func startMicrophoneOnly() throws -> RecordingFiles {
        let session = AVCaptureSession()
        try attachDefaultMicrophone(to: session)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else { throw AppError("マイクの録音を準備できませんでした。") }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)

        let created = try RecordingFiles.create()
        prepare(created, withSystemTrack: false)
        session.startRunning()
        guard session.isRunning else {
            created.delete()
            throw AppError("マイクの録音を開始できませんでした。")
        }
        self.session = session

        let center = NotificationCenter.default
        observers = [
            // 録音中にマイク（AirPods など）が外れたら、そのときの既定のマイクに切り替えて続ける。
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] notification in
                guard let self, let session = self.session,
                      let device = notification.object as? AVCaptureDevice,
                      let input = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.uniqueID == device.uniqueID })
                else { return }
                session.beginConfiguration()
                session.removeInput(input)
                let result = Result { try self.attachDefaultMicrophone(to: session) }
                session.commitConfiguration()
                if case .failure(let error) = result { self.onInterrupted?(error) }
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                self?.onInterrupted?(error ?? AppError("マイクの録音が止まりました。"))
            },
        ]
        return created
    }

    private func attachDefaultMicrophone(to session: AVCaptureSession) throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw AppError("マイクが見つかりません。")
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AppError("マイクを使えませんでした：\(error.localizedDescription)")
        }
        guard session.canAddInput(input) else { throw AppError("マイクの録音を準備できませんでした。") }
        session.addInput(input)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        write(sampleBuffer, to: micWriter)
    }

    // MARK: - マイク＋システム音声

    private func startWithSystemAudio() async throws -> RecordingFiles {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw AppError("Macの音を録音する許可がありません。システム設定 →「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」で MeetNote を許可し、アプリを起動し直してください。")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AppError("Macの音の録音を準備できませんでした。「画面収録とシステムオーディオ録音」の許可を確認してください：\(error.localizedDescription)")
        }
        guard let display = content.displays.first else {
            throw AppError("ディスプレイが見つからないため、Macの音を録音できません。")
        }

        // 画面は使わないので、映像は最小サイズ・最低頻度にして捨てる。
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.captureMicrophone = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let created = try RecordingFiles.create()
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            prepare(created, withSystemTrack: true)
            try await stream.startCapture()
        } catch {
            created.delete()
            throw AppError("録音を開始できませんでした：\(error.localizedDescription)")
        }
        self.stream = stream
        return created
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: write(sampleBuffer, to: systemWriter)
        case .microphone: write(sampleBuffer, to: micWriter)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.onInterrupted?(error)
        }
    }

    // MARK: - 書き込み（録音用のキューの上で呼ばれる）

    private func write(_ sampleBuffer: CMSampleBuffer, to writer: TrackWriter?) {
        guard let writer, sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let description = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription)
        else { return }

        let time = sampleBuffer.presentationTimeStamp
        if origin == nil { origin = time }
        let position = max(0, (time - origin!).seconds)

        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
                try writer.append(buffer, at: position)
            }
        } catch {
            if !writeFailed {
                writeFailed = true
                appLog.error("録音の書き込みに失敗しました：\(error.localizedDescription, privacy: .public)")
            }
        }

        let now = Date()
        if now.timeIntervalSince(lastLevelReport) > 0.15 {
            lastLevelReport = now
            let mic = micWriter?.level ?? 0
            let system = systemWriter?.level ?? 0
            DispatchQueue.main.async { [weak self] in self?.onLevels?(mic, system) }
        }
    }
}

enum RecordingMixer {
    /// マイクとシステム音声を重ねた1本の音声にする（中身のあるトラックだけを使う）。
    static func composition(of urls: [URL]) async throws -> AVAsset {
        let composition = AVMutableComposition()
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration),
                  duration.seconds > 0.1,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        guard !composition.tracks.isEmpty else {
            throw AppError("録音データがありません。")
        }
        return composition
    }
}
