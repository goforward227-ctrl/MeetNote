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

/// アプリをもう一度開いたとき（Spotlight やアプリケーションフォルダから）、操作画面を前に出す。
/// メニューバーのアイコンが画面の切り欠きに隠れていても操作できるようにするため。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 操作画面のウインドウを開く処理。メニューバーのラベル（常に存在するビュー）が設定する。
    @MainActor static var openMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        guard let open = Self.openMainWindow else { return true }
        open()
        return false
    }
}

/// メニューバーに出すアイコン。録音中は経過時間も出す。
private struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if state.isRecording {
                Image(systemName: "record.circle.fill")
                Text(state.elapsedText)
            } else {
                Image(systemName: state.isProcessing ? "waveform.badge.magnifyingglass" : "waveform")
            }
        }
        .onAppear {
            AppDelegate.openMainWindow = { openWindow(id: "main") }
        }
    }
}

struct MeetNoteApp: App {
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    init() {
        // テスト実行時は、通知の許可ダイアログやショートカットの登録を行わない。
        if !Self.isTesting {
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
            MenuBarLabel()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)

        // メニューバーと同じ操作画面をウインドウでも出す。アプリを開く（開き直す）と表示される。
        Window("MeetNote", id: "main") {
            MenuContentView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Self.isTesting ? .suppressed : .presented)
        .restorationBehavior(.disabled)

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
