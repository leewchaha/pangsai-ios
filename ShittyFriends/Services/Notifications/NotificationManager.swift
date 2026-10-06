import Foundation
import UserNotifications
import UIKit
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "notifications")

/// Local notifications (reminders, party alerts, reports) and notification categories.
/// Remote "friend is pooping" alerts come from CloudKit subscriptions and are rewritten on-device
/// by the Notification Service Extension.
@MainActor
final class NotificationManager {
    let center = UNUserNotificationCenter.current()
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    // userInfo keys shared with the Notification Service Extension.
    enum Key {
        static let kind = "sf_kind"
        static let session = "sf_session"
        static let group = "sf_group"
        static let share = "sf_share"
        static let party = "sf_party"
        static let event = "sf_event"
    }

    func registerCategories() {
        let join = UNNotificationAction(identifier: NotificationCategory.actionJoin, title: "JOIN 💩", options: [.foreground])
        let view = UNNotificationAction(identifier: NotificationCategory.actionView, title: "View", options: [.foreground])
        let done = UNNotificationAction(identifier: NotificationCategory.actionDone, title: "DONE", options: [])
        let categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: NotificationCategory.general, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCategory.pwmInvite, actions: [join, view], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCategory.partyInvite, actions: [view], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCategory.partyStart, actions: [join, view], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCategory.friendRequest, actions: [view], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCategory.longSession, actions: [done], intentIdentifiers: [], options: [])
        ]
        center.setNotificationCategories(categories)
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks once; returns whether alerts are allowed. Also registers for remote notifications.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            UIApplication.shared.registerForRemoteNotifications()
            return granted
        } catch {
            log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func isQuiet(_ date: Date, settings: AppSettings) -> Bool {
        settings.isQuiet(minutesFromMidnight: CalendarMath.minutesFromMidnight(date, calendar: CalendarMath.standard()))
    }

    private func add(id: String, title: String, body: String, at date: Date, category: String, userInfo: [String: Any] = [:], settings: AppSettings) {
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        if isQuiet(date, settings: settings) {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
        }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        center.add(request) { error in
            if let error { log.error("schedule \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - Long session

    private func longID(_ eventID: UUID) -> String { "long-" + eventID.uuidString }

    func scheduleLongSessionReminder(eventID: UUID, at date: Date, settings: AppSettings) {
        add(id: longID(eventID), title: "Still pooping?", body: "Tap DONE if you finished. No judgment.", at: date, category: NotificationCategory.longSession, userInfo: [Key.event: eventID.uuidString], settings: settings)
    }

    func cancelLongSessionReminder(eventID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [longID(eventID)])
        center.removeDeliveredNotifications(withIdentifiers: [longID(eventID)])
    }

    // MARK: - Parties

    func scheduleParty(_ view: PartyView, settings: AppSettings) {
        cancelParty(view.party.id)
        guard settings.notifyParties, view.party.status == .scheduled else { return }
        let info: [String: Any] = [Key.party: view.party.id.uuidString, Key.kind: "partyStart"]
        let title = view.party.title.uppercased()
        add(id: "party-pre-" + view.party.id.uuidString, title: "POOP PARTY STARTS IN 5 MINUTES", body: view.groupName.map { "\(title) · \($0)" } ?? title, at: view.party.scheduledAt.addingTimeInterval(-5 * 60), category: NotificationCategory.partyStart, userInfo: info, settings: settings)
        add(id: "party-start-" + view.party.id.uuidString, title: "🚨 POOP PARTY", body: "\(title) is on. JOIN if you're going.", at: view.party.scheduledAt, category: NotificationCategory.partyStart, userInfo: info, settings: settings)
    }

    func cancelParty(_ id: UUID) {
        let ids = ["party-pre-" + id.uuidString, "party-start-" + id.uuidString]
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Reports

    func rescheduleSummaries(settings: AppSettings, now: Date = Date()) {
        let ids = ["summary-daily", "summary-weekly", "summary-monthly"]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        let cal = Calendar.current
        func next(_ comps: DateComponents) -> Date? {
            cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
        }
        if settings.dailySummary, let d = next(DateComponents(hour: 21, minute: 30)) {
            add(id: "summary-daily", title: "TODAY IN SHIT", body: "Your daily report is ready.", at: d, category: NotificationCategory.general, userInfo: [Key.kind: "highlights-day"], settings: settings)
        }
        if settings.weeklyReport, let d = next(DateComponents(hour: 10, minute: 0, weekday: 2)) {
            add(id: "summary-weekly", title: "THE WEEK IN SHIT", body: "Last week, ranked. Open to see who held the throne.", at: d, category: NotificationCategory.general, userInfo: [Key.kind: "highlights-week"], settings: settings)
        }
        if settings.monthlyHighlights, let d = next(DateComponents(day: 1, hour: 10, minute: 0)) {
            add(id: "summary-monthly", title: "THE MONTH IN SHIT", body: "Your monthly highlights are in.", at: d, category: NotificationCategory.general, userInfo: [Key.kind: "highlights-month"], settings: settings)
        }
    }

    /// In-app event worth a banner when the app is in the background (e.g. achievement while backgrounded).
    func notifyNow(title: String, body: String, settings: AppSettings) {
        add(id: "now-" + UUID().uuidString, title: title, body: body, at: Date().addingTimeInterval(1), category: NotificationCategory.general, settings: settings)
    }

    func clearAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
