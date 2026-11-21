import Foundation

/// APIキーの保管場所。本人だけが読める権限（600）のファイルに保存する。
///
/// キーチェーンを使わないのは、Apple 発行の証明書で署名していないアプリだと、
/// ビルドし直すたびにキーチェーンがパスワードを求めるため。
/// 引き換えに、キーは暗号化されず、同じユーザーで動くほかのプログラムからも読める。
enum KeyStore {
    enum Account: String, CaseIterable {
        case elevenLabs = "elevenlabs-api-key"
        case anthropic = "anthropic-api-key"
    }

    /// テストでは別の場所に差し替える。
    static var fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MeetNote/keys.json")
    }()

    static func get(_ account: Account) -> String? {
        if let value = load()[account.rawValue], !value.isEmpty { return value }
        // 以前の版でキーチェーンに保存したキーがあれば、ファイルに移す（この1回だけキーチェーンの確認が出る）。
        if let legacy = Keychain.get(account.rawValue) {
            try? set(legacy, for: account)
            return legacy
        }
        return nil
    }

    /// 保存済みかどうか。キーの値は読まない（キーチェーンの確認を出さない）。
    static func exists(_ account: Account) -> Bool {
        if let value = load()[account.rawValue], !value.isEmpty { return true }
        return Keychain.exists(account.rawValue)
    }

    static func set(_ value: String, for account: Account) throws {
        var keys = load()
        keys[account.rawValue] = value
        try save(keys)
    }

    static func delete(_ account: Account) {
        var keys = load()
        keys[account.rawValue] = nil
        try? save(keys)
        Keychain.delete(account.rawValue)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let keys = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return keys
    }

    private static func save(_ keys: [String: String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(keys)

            // 最初から 600 の権限で作った一時ファイルに書き、置き換える（途中で他人に読める状態を作らない）。
            let temporary = directory.appendingPathComponent(".keys-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw AppError("ファイルを作れませんでした。")
            }
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw AppError("APIキーを保存できませんでした：\(error.localizedDescription)")
        }
    }
}
