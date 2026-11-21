import SwiftUI

@main
enum Main {
    static func main() {
        // `MeetNote --process <音声ファイル> [--title <タイトル>]` で、画面なしで1件だけ処理できる（動作確認用）。
        if let index = CommandLine.arguments.firstIndex(of: "--process"), CommandLine.arguments.count > index + 1 {
            Headless.run(arguments: CommandLine.arguments)
        } else {
            MeetNoteApp.main()
        }
    }
}

struct MeetNoteApp: App {
    @StateObject private var state = AppState.shared

    init() {
        // テスト実行時は、通知の許可ダイアログやショートカットの登録を行わない。
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Notifier.shared.setUp()
            HotKey.shared.register {
                Task { @MainActor in AppState.shared.toggleRecording() }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(state)
        } label: {
            if state.isRecording {
                Image(systemName: "record.circle.fill")
                Text(state.elapsedText)
            } else {
                Image(systemName: state.isProcessing ? "waveform.badge.magnifyingglass" : "waveform")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

enum Headless {
    static func run(arguments: [String]) -> Never {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
            return arguments[index + 1]
        }

        let path = value(after: "--process")!
        let title = value(after: "--title") ?? ""
        let environment = ProcessInfo.processInfo.environment

        Task {
            guard let elevenLabsKey = environment["ELEVENLABS_API_KEY"] ?? KeyStore.get(.elevenLabs),
                  let anthropicKey = environment["ANTHROPIC_API_KEY"] ?? KeyStore.get(.anthropic)
            else {
                FileHandle.standardError.write(Data("APIキーが設定されていません。\n".utf8))
                exit(2)
            }
            let settings = SettingsStore.shared.snapshot()
            let pipeline = Pipeline(
                settings: settings,
                provider: ElevenLabsProvider(apiKey: elevenLabsKey, modelID: settings.sttModel),
                claude: ClaudeClient(apiKey: anthropicKey),
                pricing: Pricing.load()
            )
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                let output = try await pipeline.run(
                    PipelineInput(source: .file(url), title: title, date: AppState.creationDate(of: url))
                ) { stage, detail in
                    print(detail.map { "\(stage.rawValue)（\($0)）" } ?? stage.rawValue)
                }
                print("完了: \(output.documentURL.path)")
                exit(0)
            } catch {
                let message = Redactor.mask(error.localizedDescription, secrets: [elevenLabsKey, anthropicKey])
                FileHandle.standardError.write(Data("失敗: \(message)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}
