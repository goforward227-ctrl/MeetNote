import SwiftUI

/// メニューバーのアイコンをクリックすると開くウィンドウ。
struct MenuContentView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.openSettings) private var openSettings
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 14) {
            TextField("会議タイトル", text: $state.title)
                .textFieldStyle(.roundedBorder)

            recorder

            if hasStatus {
                VStack(alignment: .leading, spacing: 10) {
                    if !state.hasKeys { keysRow }
                    if state.isProcessing { progressRow }
                    ForEach(state.leftovers, id: \.directory) { leftoverRow($0) }
                    if let error = state.lastError { errorRow(error) }
                    if let completed = state.lastCompleted { completedRow(completed) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Button { showSettings() } label: {
                    Label("設定", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                Spacer()
                moreMenu
            }
        }
        .padding(14)
        .frame(width: 280)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                    .overlay(Text("ドロップして議事録を作る").font(.headline))
                    .padding(6)
            }
        }
        // 既存の音声ファイル（m4a / mp3 / wav / mp4）は、ウィンドウのどこにドロップしてもよい。
        .dropDestination(for: URL.self) { urls, _ in
            state.enqueue(urls)
        } isTargeted: { isDropTargeted = $0 }
        .onAppear { state.refreshKeyStatus() }
    }

    private var hasStatus: Bool {
        !state.hasKeys || state.isProcessing || !state.leftovers.isEmpty || state.lastError != nil || state.lastCompleted != nil
    }

    // MARK: - 録音

    private var recorder: some View {
        VStack(spacing: 16) {
            Text(state.elapsedText)
                .font(.system(size: 30, weight: .light, design: .monospaced))
                .foregroundStyle(state.isRecording ? .primary : .tertiary)

            Button(action: state.toggleRecording) {
                RecordButtonFace(isRecording: state.isRecording)
            }
            .buttonStyle(.plain)
            .disabled(state.isSwitchingRecording)
            .help(state.isRecording ? "停止して議事録を作る（\(HotKey.displayText)）" : "録音開始（\(HotKey.displayText)）")
            .accessibilityLabel(state.isRecording ? "停止して議事録を作る" : "録音開始")

            // 高さを固定して、録音の開始・停止でウィンドウの大きさが変わらないようにする。
            VStack(spacing: 4) {
                if state.isRecording {
                    LevelBar(symbol: "mic.fill", level: state.micLevel)
                    if state.isRecordingSystemAudio {
                        LevelBar(symbol: "speaker.wave.2.fill", level: state.systemLevel)
                    }
                } else if settings.recordSystemAudio {
                    Label("Macの音も録音します", systemImage: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 22)
        }
        .padding(.vertical, 8)
    }

    // MARK: - 状況の表示

    private var keysRow: some View {
        StatusRow(symbol: "key.fill", tint: .orange, title: "APIキーを設定してください") {
            Button("設定") { showSettings() }
                .controlSize(.small)
        }
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.status ?? "処理中")
                    .font(.callout)
                Text(state.pendingCount > 0 ? "\(state.currentName ?? "")・ほか\(state.pendingCount)件" : state.currentName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// まだ議事録になっていない録音。キーが未設定だった場合や、録音中にアプリが落ちた場合に残る。
    private func leftoverRow(_ recording: RecordingFiles) -> some View {
        StatusRow(
            symbol: "waveform",
            tint: .secondary,
            title: "未処理の録音",
            subtitle: "\(Self.shortDate(recording.startedAt))・\(Self.length(recording.approximateDuration))"
        ) {
            Button {
                state.discardLeftover(recording)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("ゴミ箱に移す")
            .accessibilityLabel("この録音をゴミ箱に移す")

            Button("議事録を作る") { state.processLeftover(recording) }
                .controlSize(.small)
                .disabled(!state.hasKeys)
        }
    }

    private func errorRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let folder = state.lastErrorFolder {
                Button("残っている音声を表示") { NSWorkspace.shared.open(folder) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func completedRow(_ completed: AppState.Completed) -> some View {
        StatusRow(
            symbol: "checkmark.circle.fill",
            tint: .green,
            title: completed.title,
            subtitle: summary(of: completed.output)
        ) {
            Button {
                NSWorkspace.shared.open(completed.output.folder)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("フォルダを開く")
            .accessibilityLabel("フォルダを開く")

            Button("開く") { NSWorkspace.shared.open(completed.output.documentURL) }
                .controlSize(.small)
                .help("議事録を開く")
        }
    }

    // MARK: - その他のメニュー

    private var moreMenu: some View {
        Menu {
            Button("音声ファイルから作る…") { state.chooseFiles() }
                .disabled(!state.hasKeys)
            Toggle("Macの音も録音する（オンライン会議用）", isOn: $settings.recordSystemAudio)
                .disabled(state.isRecording)
            Divider()
            Button("MeetNote を終了") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("その他")
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    private func summary(of output: PipelineOutput) -> String {
        guard let cost = output.estimatedCostUSD else { return Self.length(output.durationSeconds) }
        return "\(Self.length(output.durationSeconds))・約 $\(String(format: "%.2f", cost))"
    }

    private static func length(_ seconds: Double) -> String {
        seconds < 60 ? "\(max(1, Int(seconds)))秒" : "\(Int((seconds / 60).rounded()))分"
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}

/// Apple 純正のアイコン（SF Symbols）を使った録音ボタン。
/// 止まっているときは「録音」（輪の中に赤い丸）、録音中は「停止」（グレーの丸に白い四角）。
private struct RecordButtonFace: View {
    let isRecording: Bool

    var body: some View {
        Group {
            if isRecording {
                Image(systemName: "stop.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(nsColor: .systemGray))
            } else {
                Image(systemName: "record.circle")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 56, weight: .light))
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 68, height: 68)
        .contentShape(Circle())
    }
}

/// アイコン・見出し・補足・右端の操作、という1行の表示。
private struct StatusRow<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            actions
        }
    }
}

/// 音が入っているかを確かめるための、細いレベル表示。
private struct LevelBar: View {
    let symbol: String
    let level: Float

    /// 小さな声でも動きが見えるよう、デシベルに直して 0〜1 に収める（-60dB〜0dB）。
    private var fraction: Double {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(Double(level))
        return min(1, max(0, (decibels + 60) / 60))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(Color.green).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 4)
            .animation(.linear(duration: 0.15), value: fraction)
        }
        .frame(width: 150)
    }
}

extension Notification.Name {
    static let apiKeysChanged = Notification.Name("local.meetnote.apiKeysChanged")
}
