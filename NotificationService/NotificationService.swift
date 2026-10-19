import UserNotifications

/// Finishes Firebase Cloud Messaging alerts on-device.
///
/// The server already applied everyone's alert preferences and sends a readable alert plus data fields
/// (`sf_kind`, `sf_sender`, `sf_group`, ...). This extension re-renders the text from those fields so the
/// **Private lock screen** and **quiet hours** settings of *this device* are honoured even if the server
/// saw an older copy of them. The settings come from a tiny file the app keeps in the App Group.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    static let appGroup = "group.com.sakara.shittyfriends"

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttempt = content

        let info = request.content.userInfo
        guard let kindRaw = info[PushField.kind] as? String, let kind = PingKind(rawValue: kindRaw) else {
            contentHandler(content)
            return
        }

        let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup).flatMap { PingDirectory.read(from: $0) }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let quiet = directory?.isQuiet(minutesFromMidnight: minutes) ?? false
        let text = NotificationTextBuilder.text(
            kind: kind,
            sender: info[PushField.sender] as? String,
            groupName: info[PushField.group] as? String,
            partyTitle: info[PushField.title] as? String,
            privateMode: directory?.lockScreenPrivate ?? false,
            quiet: quiet
        )

        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = text.category
        content.threadIdentifier = text.threadID
        if text.silent {
            content.sound = nil
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
            content.interruptionLevel = .active
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }
}
