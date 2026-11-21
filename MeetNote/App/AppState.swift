import AppKit
import Foundation
import UniformTypeIdentifiers

/// メニューバーの画面が表示する状態と、録音・処理待ちの管理。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    static let supportedExtensions: Set<String> = ["m4a", "mp3", "wav", "mp4", "mov", "aac"]

    struct Job {
        var source: AudioSource
        var title: String
        var date: Date
    }

    struct Completed {
        var title: String
        var output: PipelineOutput
    }

    @Published var title = ""
    /// 2つのAPIキーが両方とも保存されているか。
    @Published private(set) var hasKeys = true

    // 録音
    @Published private(set) var isRecording = false
    @Published private(set) var isSwitchingRecording = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    /// いまの録音が、Macの音（相手の声）も録っているかどうか。
    @Published private(set) var isRecordingSystemAudio = false
    /// 処理されずに残っている録音（録音中にアプリが落ちた場合や、処理の準備で失敗した場合）。
    @Published private(set) var leftovers: [RecordingFiles] = []

    // 処理
    @Published private(set) var isProcessing = false
    @Published private(set) var status: String?
    @Published private(set) var currentName: String?
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastCompleted: Completed?
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorFolder: URL?

    private let recorder = Recorder()
    private var activeRecording: RecordingFiles?
    private var timer: Timer?
    private var queue: [Job] = []
    private var currentJob: Job?

    private init() {
        recorder.onLevels = { [weak self] mic, system in
            self?.micLevel = mic
            self?.systemLevel = system
        }
        recorder.onInterrupted = { [weak self] error in
            Task { @MainActor in
                await self?.stopRecording(interruptedBy: error)
            }
        }
        NotificationCenter.default.addObserver(forName: .apiKeysChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshKeyStatus() }
        }
        refreshKeyStatus()
        refreshLeftovers()
    }

    func refreshKeyStatus() {
        hasKeys = KeyStore.exists(.elevenLabs) && KeyStore.exists(.anthropic)
    }

    var elapsedText: String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - 録音

    func toggleRecording() {
        guard !isSwitchingRecording else { return }
        Task {
            if isRecording {
                await stopRecording(interruptedBy: nil)
            } else {
                await startRecording()
            }
        }
    }

    private func startRecording() async {
        isSwitchingRecording = true
        defer { isSwitchingRecording = false }
        lastError = nil
        lastErrorFolder = nil
        do {
            let includeSystemAudio = SettingsStore.shared.recordSystemAudio
            let files = try await recorder.start(includeSystemAudio: includeSystemAudio)
            isRecordingSystemAudio = includeSystemAudio
            activeRecording = files
            elapsedSeconds = 0
            micLevel = 0
            systemLevel = 0
            isRecording = true
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let started = self.activeRecording?.startedAt else { return }
                    self.elapsedSeconds = Int(Date().timeIntervalSince(started))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func stopRecording(interruptedBy error: Error?) async {
        guard isRecording else { return }
        isSwitchingRecording = true
        defer { isSwitchingRecording = false }
        timer?.invalidate()
        timer = nil
        isRecording = false

        let files = await recorder.stop() ?? activeRecording
        activeRecording = nil
        if let error {
            lastError = "録音が中断されました。そこまでの音声で議事録を作ります：\(error.localizedDescription)"
            lastErrorFolder = nil
        }
        guard let files else { return }
        enqueue(Job(source: .recording(files), title: takeTitle(), date: files.startedAt))
    }

    /// 残っていた録音から議事録を作る。
    func processLeftover(_ recording: RecordingFiles) {
        enqueue(Job(source: .recording(recording), title: takeTitle(), date: recording.startedAt))
    }

    /// 残っていた録音をゴミ箱に移す（間違えても Finder のゴミ箱から戻せる）。
    func discardLeftover(_ recording: RecordingFiles) {
        do {
            try FileManager.default.trashItem(at: recording.directory, resultingItemURL: nil)
        } catch {
            lastError = "録音をゴミ箱に移せませんでした：\(error.localizedDescription)"
            lastErrorFolder = nil
        }
        refreshLeftovers()
    }

    private func refreshLeftovers() {
        var active = queue.compactMap { job -> URL? in
            if case .recording(let files) = job.source { return files.directory }
            return nil
        }
        if let activeRecording { active.append(activeRecording.directory) }
        if case .recording(let files)? = currentJob?.source { active.append(files.directory) }
        leftovers = RecordingFiles.leftovers(excluding: active)
    }

    // MARK: - ファイルの読み込み

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "音声ファイルを選択"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            enqueue(panel.urls)
        }
    }

    /// ファイルを処理待ちに加える。対応していない形式は弾いて、その旨を表示する。
    @discardableResult
    func enqueue(_ urls: [URL]) -> Bool {
        let accepted = urls.filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
        let rejected = urls.count - accepted.count
        if rejected > 0 {
            lastError = "対応していない形式のファイルが\(rejected)件ありました（対応：m4a / mp3 / wav / mp4）。"
            lastErrorFolder = nil
        }
        guard !accepted.isEmpty else { return false }
        // キーが無いと処理できない。画面にはキーの設定を促す表示が出ているので、ここでは受け付けないだけにする。
        refreshKeyStatus()
        guard hasKeys else { return false }

        // タイトルは最初の1件にだけ使う。複数まとめて入れた場合、残りは日時だけになる。
        let entered = takeTitle()
        for (index, url) in accepted.enumerated() {
            enqueue(Job(source: .file(url), title: index == 0 ? entered : "", date: Self.creationDate(of: url)))
        }
        return true
    }

    private func takeTitle() -> String {
        let entered = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = ""
        return entered
    }

    // MARK: - 処理

    private func enqueue(_ job: Job) {
        queue.append(job)
        pendingCount = queue.count
        refreshLeftovers()
        if !isProcessing {
            Task { await drain() }
        }
    }

    private func drain() async {
        isProcessing = true
        while !queue.isEmpty {
            let job = queue.removeFirst()
            pendingCount = queue.count
            currentJob = job
            await process(job)
            currentJob = nil
            refreshLeftovers()
        }
        isProcessing = false
        status = nil
        currentName = nil
    }

    private func process(_ job: Job) async {
        currentName = job.title.isEmpty ? job.source.displayName : job.title
        status = "準備中"
        lastError = nil
        lastErrorFolder = nil

        // キーが無い場合、録音は「未処理の録音」として残る。画面にはキーの設定を促す表示が出る。
        guard let elevenLabsKey = KeyStore.get(.elevenLabs), let anthropicKey = KeyStore.get(.anthropic) else {
            refreshKeyStatus()
            return
        }

        let settings = SettingsStore.shared.snapshot()
        let pipeline = Pipeline(
            settings: settings,
            provider: ElevenLabsProvider(apiKey: elevenLabsKey, modelID: settings.sttModel),
            claude: ClaudeClient(apiKey: anthropicKey),
            pricing: Pricing.load()
        )
        let input = PipelineInput(source: job.source, title: job.title, date: job.date)

        do {
            let output = try await pipeline.run(input) { [weak self] stage, detail in
                Task { @MainActor in
                    self?.status = detail.map { "\(stage.rawValue)（\($0)）" } ?? stage.rawValue
                }
            }
            let name = job.title.isEmpty ? MinutesGenerator.dateText(job.date) : job.title
            lastCompleted = Completed(title: name, output: output)
            Notifier.shared.notify(title: "議事録ができました", body: name, opening: output.documentURL)
        } catch {
            let failure = error as? PipelineFailure
            let message = Redactor.mask(error.localizedDescription, secrets: [elevenLabsKey, anthropicKey])
            fail(message, folder: failure?.folder)
        }
    }

    private func fail(_ message: String, folder: URL?) {
        appLog.error("処理に失敗しました：\(message, privacy: .public)")
        lastError = message
        lastErrorFolder = folder
        Notifier.shared.notify(title: "議事録の作成に失敗しました", body: message, opening: folder)
    }

    static func creationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }
}

#if DEBUG
extension AppState {
    /// README に載せる画面写真を作るための、見本の状態。テストからだけ使う（配布用のビルドには含まれない）。
    func applyPreview(recordingSeconds: Int? = nil, systemAudio: Bool = false, status: String? = nil, completed: Completed? = nil) {
        isRecording = recordingSeconds != nil
        elapsedSeconds = recordingSeconds ?? 0
        isRecordingSystemAudio = systemAudio
        micLevel = recordingSeconds == nil ? 0 : 0.06
        systemLevel = recordingSeconds == nil ? 0 : 0.02
        isProcessing = status != nil
        self.status = status
        currentName = status == nil ? nil : "A社 定例"
        pendingCount = 0
        lastCompleted = completed
        lastError = nil
        leftovers = []
        hasKeys = true
    }
}
#endif
