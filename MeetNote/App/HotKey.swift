import Carbon.HIToolbox
import Foundation

/// どのアプリを使っていても効く、録音開始／停止のショートカット（⌃⌥⌘R）。
final class HotKey {
    static let shared = HotKey()
    static let displayText = "⌃⌥⌘R"

    private var reference: EventHotKeyRef?
    private var handler: (() -> Void)?

    func register(_ handler: @escaping () -> Void) {
        guard reference == nil else { return }
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.handler?() }
            return noErr
        }, 1, &eventType, nil, nil)

        let identifier = EventHotKeyID(signature: OSType(0x4D54_4E54), id: 1)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        if status != noErr {
            appLog.error("ショートカットを登録できませんでした（\(status)）")
        }
    }
}
