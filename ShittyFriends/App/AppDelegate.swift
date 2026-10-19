import UIKit
import UserNotifications
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "delegate")

/// Owns the AppModel and bridges UIKit-only callbacks: the APNs token (for Firebase Cloud Messaging),
/// remote pushes and notification taps/actions.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static private(set) weak var shared: AppDelegate?
    lazy var model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppDelegate.shared = self
        UNUserNotificationCenter.current().delegate = self
        Haptics.prepare()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log.info("registered for remote notifications")
        model.push.apnsTokenReceived(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("remote notification registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Pushes from Firebase Cloud Messaging (alerts; the Notification Service Extension shaped the text).
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        model.push.didReceive(userInfo)
        await model.refresh()
        model.saveNow()
        return .newData
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        await MainActor.run {
            self.model.push.didReceive(info)
            Task { await self.model.refresh() }
        }
        return [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        await MainActor.run {
            self.model.push.didReceive(info)
            self.model.handleNotification(userInfo: info, action: action)
        }
    }
}
