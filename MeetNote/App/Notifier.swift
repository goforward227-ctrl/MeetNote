import AppKit
import UserNotifications

/// 処理の完了・失敗を macOS の通知で知らせる。通知をクリックすると、議事録（失敗時は音声の残っているフォルダ）を開く。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var authorized = false

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func notify(title: String, body: String, opening target: URL?) {
        guard authorized else {
            // 通知が許可されていない場合は、代わりに直接開く。
            if let target {
                DispatchQueue.main.async { NSWorkspace.shared.open(target) }
            }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let target { content.userInfo = ["path": target.path] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
    }
}
