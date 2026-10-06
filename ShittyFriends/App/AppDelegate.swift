import CloudKit
import UIKit
import UserNotifications
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "delegate")

/// Owns the AppModel and bridges UIKit-only callbacks: remote pushes, notification taps/actions,
/// and accepted iCloud share links (via the scene delegate).
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

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log.info("registered for remote notifications")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("remote notification registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// CloudKit pushes: ping subscriptions (alerts) and the sync engines' silent database pushes.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        let subscriptionID = CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID ?? ""
        if subscriptionID.hasPrefix(SubscriptionSpec.idPrefix) {
            await model.processIncomingPings()
        }
        await model.cloud.fetchAll()
        model.saveNow()
        return .newData
    }

    func acceptShare(_ metadata: CKShare.Metadata) {
        Task { @MainActor in
            await model.start()
            await model.openCloudShare(metadata: metadata)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        await MainActor.run {
            if CKNotification(fromRemoteNotificationDictionary: info) != nil {
                Task { await self.model.processIncomingPings() }
            }
        }
        return [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        await MainActor.run {
            self.model.handleNotification(userInfo: info, action: action)
        }
    }
}

/// Receives iCloud share links the system opens for us (CKSharingSupported = YES).
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { @MainActor in AppDelegate.shared?.acceptShare(metadata) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in AppDelegate.shared?.acceptShare(cloudKitShareMetadata) }
    }
}
