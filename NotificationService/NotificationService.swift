import CloudKit
import UserNotifications

/// Rewrites anonymous CloudKit ping pushes into real alerts, entirely on-device.
///
/// The push only contains an opaque inbox token, a kind, an optional sender group token and an
/// AES-GCM sealed payload. The app keeps a small directory in the shared App Group container that maps
/// my tokens to friend handles / group names and keys. Nothing readable ever leaves the devices.
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

        guard let note = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo) as? CKQueryNotification,
              let fields = note.recordFields,
              let to = fields[PingField.to] as? String,
              let kindRaw = fields[PingField.kind] as? String,
              let kind = PingKind(rawValue: kindRaw) else {
            contentHandler(content)
            return
        }

        let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup).flatMap { PingDirectory.read(from: $0) }
        let entry = directory?.entries[to]
        var payload: PingPayload?
        if let ref = fields[PingField.ref] as? String, let key = entry?.key {
            payload = try? AESSealer().openPayload(ref, keyBase64URL: key)
        }

        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let quiet = directory?.isQuiet(minutesFromMidnight: minutes) ?? false
        let text = NotificationTextBuilder.text(
            kind: kind,
            entry: entry,
            senderToken: fields[PingField.from] as? String,
            payload: payload,
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

        // Hand the app what it needs to act on a tap (JOIN, open party...).
        var info = content.userInfo
        info["sf_kind"] = kind.rawValue
        if let s = payload?.sessionID { info["sf_session"] = s }
        if let g = payload?.groupID { info["sf_group"] = g }
        if let u = payload?.shareURL, kind == .pwmInvite || kind == .partyInvite { info["sf_share"] = u }
        if let p = payload?.partyID { info["sf_party"] = p }
        content.userInfo = info

        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }
}
