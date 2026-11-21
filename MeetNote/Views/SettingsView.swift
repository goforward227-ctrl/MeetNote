import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
            PromptSettingsView()
                .tabItem { Label("プロンプト", systemImage: "text.alignleft") }
        }
        .frame(width: 560, height: 470)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("APIキー（このMacの中のファイルに保存されます）") {
                APIKeyRow(label: "ElevenLabs", account: .elevenLabs)
                APIKeyRow(label: "Anthropic", account: .anthropic)
            }

            Section("保存先") {
                HStack {
                    Text(settings.saveRootPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("変更…") { chooseFolder() }
                }
            }

            Section("モデル") {
                ModelPicker(title: "議事録（Claude）", selection: $settings.claudeModel, options: DefaultValues.claudeModels)
                ModelPicker(title: "文字起こし", selection: $settings.sttModel, options: DefaultValues.sttModels)
            }

            Section("概算コストの単価") {
                HStack {
                    Text("単価は設定ファイルで変更できます。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("pricing.json を表示") {
                        _ = Pricing.load()
                        NSWorkspace.shared.activateFileViewerSelecting([Pricing.fileURL])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "選択"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveRootPath = url.path
        }
    }
}

/// 一覧から選ぶか、一覧にないモデルIDを直接入力できる。
private struct ModelPicker: View {
    let title: String
    @Binding var selection: String
    let options: [(id: String, label: String)]

    private static let customTag = "__custom__"
    @State private var isCustom = false

    var body: some View {
        Picker(title, selection: pickerBinding) {
            ForEach(options, id: \.id) { option in
                Text(option.label).tag(option.id)
            }
            Text("その他（IDを入力）").tag(Self.customTag)
        }
        if isCustom || !options.contains(where: { $0.id == selection }) {
            TextField("モデルID", text: $selection)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var pickerBinding: Binding<String> {
        Binding(
            get: {
                if isCustom { return Self.customTag }
                return options.contains(where: { $0.id == selection }) ? selection : Self.customTag
            },
            set: { value in
                if value == Self.customTag {
                    isCustom = true
                } else {
                    isCustom = false
                    selection = value
                }
            }
        )
    }
}

/// 保存済みのキーは画面に読み出さない。入力したときだけ上書きする。
private struct APIKeyRow: View {
    let label: String
    let account: KeyStore.Account

    @State private var input = ""
    @State private var isSaved = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(label, text: $input, prompt: Text(isSaved ? "保存済み（変更するときだけ入力）" : "未設定"))
                    .onSubmit(save)
                Button("保存", action: save)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("削除", role: .destructive) {
                    KeyStore.delete(account)
                    refresh()
                    message = "削除しました"
                }
                .disabled(!isSaved)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refresh)
    }

    private func save() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try KeyStore.set(value, for: account)
            input = ""
            message = "保存しました"
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        isSaved = KeyStore.exists(account)
        NotificationCenter.default.post(name: .apiKeysChanged, object: nil)
    }
}

private struct PromptSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("議事録を作るときに Claude に渡す指示です。")
                .foregroundStyle(.secondary)
            TextEditor(text: $settings.minutesPrompt)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("初期値に戻す") { settings.minutesPrompt = DefaultValues.minutesPrompt }
                    .disabled(settings.minutesPrompt == DefaultValues.minutesPrompt)
            }
        }
        .padding(16)
    }
}
