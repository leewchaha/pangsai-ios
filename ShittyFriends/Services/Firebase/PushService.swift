import FirebaseFirestore
import FirebaseMessaging
import Foundation
import UIKit
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "push")

/// Firebase Cloud Messaging on the device: registers this device's token under my user record (the
/// Cloud Functions send to every registered device) and hands the Notification Service Extension the
/// settings it applies on-device (private lock screen, quiet hours).
@MainActor
final class PushService: NSObject, MessagingDelegate {
    let store: Store
    private var uid: UserID?
    private var token: String?

    init(store: Store) {
        self.store = store
        super.init()
    }

    func start() {
        guard FirebaseConfig.isConfigured else { return }
        Messaging.messaging().delegate = self
    }

    /// Called whenever the signed-in user changes.
    func setUser(_ uid: UserID?) {
        let previous = self.uid
        self.uid = uid
        if previous != nil, previous != uid, let previous, let token {
            // Another account on this device must not receive the old account's alerts.
            Firestore.firestore().document("users/\(previous)/devices/\(token)").delete { _ in }
        }
        registerTokenIfPossible()
    }

    func apnsTokenReceived(_ deviceToken: Data) {
        guard FirebaseConfig.isConfigured else { return }
        Messaging.messaging().apnsToken = deviceToken
    }

    /// Lets FCM account for a delivered message (analytics, token refresh).
    func didReceive(_ userInfo: [AnyHashable: Any]) {
        guard FirebaseConfig.isConfigured else { return }
        Messaging.messaging().appDidReceiveMessage(userInfo)
    }

    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Task { @MainActor in
            self.token = fcmToken
            self.registerTokenIfPossible()
        }
    }

    private func registerTokenIfPossible() {
        guard FirebaseConfig.isConfigured, let uid, let token else { return }
        let doc = Firestore.firestore().document("users/\(uid)/devices/\(token)")
        doc.setData(["platform": "ios", "updatedAt": FieldValue.serverTimestamp(), "app": Bundle.main.bundleIdentifier ?? "com.sakara.shittyfriends"], merge: true) { error in
            if let error { log.error("device registration failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Removes this device from my account (sign out / delete).
    func unregister() async {
        guard FirebaseConfig.isConfigured, let uid, let token else { return }
        try? await Firestore.firestore().document("users/\(uid)/devices/\(token)").delete()
    }

    // MARK: - Directory for the Notification Service Extension

    func writeDirectory() {
        guard let dir = FirebaseConfig.appGroupDirectory else {
            log.error("App Group container unavailable; private lock screen can't be applied on-device")
            return
        }
        do {
            try PingDirectory(settings: store.settings).write(to: dir)
        } catch {
            log.error("directory write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forget everything (account switch / delete all data).
    func reset() {
        if let dir = FirebaseConfig.appGroupDirectory {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(PingDirectory.fileName))
        }
    }
}
