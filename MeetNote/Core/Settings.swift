import Foundation

enum DefaultValues {
    static let claudeModel = "claude-sonnet-5-5"
    static let sttModel = "scribe_v3"

    static let claudeModels: [(id: String, label: String)] = [
        ("claude-sonnet-5-5", "Claude Sonnet 5.5（標準）"),
        ("claude-opus-5-5", "Claude Opus 5.5（高精度）"),
        ("claude-haiku-5-5", "Claude Haiku 5.5（最安）"),
        ("claude-fable-5-2", "Claude Fable 5.2（最上位）"),
    ]

    static let sttModels: [(id: String, label: String)] = [
        ("scribe_v3", "Scribe v3（最新・推奨）"),
        ("scribe_v2", "Scribe v2"),
    ]

    static var saveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/MeetNote")
    }

    static let minutesPrompt = """
    あなたは会議の議事録作成担当です。以下は話者ラベル付きの会議の文字起こしです。
    文字起こしには誤変換が含まれる可能性があります。文脈から明らかな誤変換は正しい語に直し、
    判断がつかないものは推測で埋めずに「（聞き取り不明）」と書いてください。

    次の形式のMarkdownで出力してください。

    # {会議タイトル}
    - 日時：
    - 参加者：（話者ラベルまたは名前）

    ## 要約
    （3〜5行）

    ## 議論の内容
    （話題ごとに見出しを立て、誰が何を言ったかを時系列で具体的に書く）

    ### （話題）
    - 

    ## 決定事項
    -

    ## ToDo
    | 担当 | 内容 | 期限 |
    |---|---|---|

    ## 論点・懸念事項
    -

    ## 次回までの確認事項
    -

    ルール：
    - 発言にない内容を補わない。期限や担当者が発言で明示されていない場合は「未定」と書く
    - 金額・日付・数量は発言どおりに正確に書く
    - 「要約」は短くまとめ、「議論の内容」は詳しく書く。発言に出た数字・固有名詞・理由・具体例・質問とその答えは省かない
    - 雑談は省く
    - 議事録の本文だけを出力する。前置き、追伸、読み手への質問や提案は書かない
    """
}

/// 1回の処理で使う設定のコピー。処理の途中で設定画面が変更されても影響を受けない。
struct SettingsSnapshot {
    var saveRoot: URL
    var claudeModel: String
    var sttModel: String
    var minutesPrompt: String
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var saveRootPath: String { didSet { defaults.set(saveRootPath, forKey: "saveRootPath") } }
    @Published var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "claudeModel") } }
    @Published var sttModel: String { didSet { defaults.set(sttModel, forKey: "sttModel") } }
    @Published var minutesPrompt: String { didSet { defaults.set(minutesPrompt, forKey: "minutesPrompt") } }
    /// オンライン会議用。オンにすると、Macから出る音（相手の声）もマイクとは別に録音する。
    @Published var recordSystemAudio: Bool { didSet { defaults.set(recordSystemAudio, forKey: "recordSystemAudio") } }

    private init() {
        saveRootPath = defaults.string(forKey: "saveRootPath") ?? DefaultValues.saveRoot.path
        claudeModel = defaults.string(forKey: "claudeModel") ?? DefaultValues.claudeModel
        sttModel = defaults.string(forKey: "sttModel") ?? DefaultValues.sttModel
        minutesPrompt = defaults.string(forKey: "minutesPrompt") ?? DefaultValues.minutesPrompt
        recordSystemAudio = defaults.bool(forKey: "recordSystemAudio")
    }

    func snapshot() -> SettingsSnapshot {
        let model = claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let stt = sttModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = minutesPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return SettingsSnapshot(
            saveRoot: URL(fileURLWithPath: (saveRootPath as NSString).expandingTildeInPath),
            claudeModel: model.isEmpty ? DefaultValues.claudeModel : model,
            sttModel: stt.isEmpty ? DefaultValues.sttModel : stt,
            minutesPrompt: prompt.isEmpty ? DefaultValues.minutesPrompt : minutesPrompt
        )
    }
}

/// 概算コストの単価。`~/Library/Application Support/MeetNote/pricing.json` を編集すると変更できる。
struct Pricing: Codable {
    struct TokenPrice: Codable {
        var input: Double
        var output: Double
    }

    /// 文字起こしの単価（USD／音声1時間）。キーはモデルID。
    var sttUSDPerHour: [String: Double]
    /// Claudeの単価（USD／100万トークン）。キーはモデルID。
    var claudeUSDPerMTok: [String: TokenPrice]

    enum CodingKeys: String, CodingKey {
        case sttUSDPerHour = "stt_usd_per_hour"
        case claudeUSDPerMTok = "claude_usd_per_mtok"
    }

    static let standard = Pricing(
        sttUSDPerHour: ["scribe_v3": 0.20, "scribe_v2": 0.20],
        claudeUSDPerMTok: [
            "claude-sonnet-5-5": TokenPrice(input: 2, output: 10),
            "claude-opus-5-5": TokenPrice(input: 4, output: 20),
            "claude-haiku-5-5": TokenPrice(input: 0.10, output: 0.50),
            "claude-fable-5-2": TokenPrice(input: 8, output: 40),
        ]
    )

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MeetNote/pricing.json")
    }

    /// 単価ファイルを読む。無ければ初期値で作る。壊れている場合は初期値を使う。
    static func load() -> Pricing {
        let url = fileURL
        if let data = try? Data(contentsOf: url) {
            if let pricing = try? JSONDecoder().decode(Pricing.self, from: data) { return pricing }
            appLog.error("pricing.json を読めないため、初期値の単価を使います")
            return .standard
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Pricing.standard) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        return .standard
    }

    func sttCost(model: String, seconds: Double) -> Double? {
        sttUSDPerHour[model].map { $0 * seconds / 3600 }
    }

    func claudeCost(model: String, inputTokens: Int, outputTokens: Int) -> Double? {
        claudeUSDPerMTok[model].map {
            ($0.input * Double(inputTokens) + $0.output * Double(outputTokens)) / 1_000_000
        }
    }
}
