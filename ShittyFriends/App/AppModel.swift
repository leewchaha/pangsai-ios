import CloudKit
import Foundation
import Observation
import SwiftUI
import UIKit
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "app")

enum AppTab: String, CaseIterable, Hashable {
    case today, map, groups, calendar, you

    var title: String {
        switch self {
        case .today: return "TODAY"
        case .map: return "MAP"
        case .groups: return "GROUPS"
        case .calendar: return "CALENDAR"
        case .you: return "YOU"
        }
    }

    var symbol: String {
        switch self {
        case .today: return "sun.max.fill"
        case .map: return "map.fill"
        case .groups: return "person.3.fill"
        case .calendar: return "calendar"
        case .you: return "face.smiling.inverse"
        }
    }
}

/// Short-lived banner at the top of the screen.
struct Toast: Identifiable, Equatable {
    enum Style: Equatable { case achievement(AchievementID), cosmetic(CosmeticID), info, error, social }
    let id = UUID()
    var style: Style
    var title: String
    var body: String
}

/// A group invite waiting for the user's confirmation.
struct GroupJoinOffer: Identifiable {
    let id = UUID()
    var name: String
    var color: IdentityColor
    var object: GroupObject
    var metadata: CKShare.Metadata?
    var url: URL?
}

/// Which full-screen experience is up.
enum ActiveSheet: Identifiable, Equatable {
    case friendInvite(FriendInvitePayload)
    case groupJoin(UUID)
    case pwmInvite(UUID)
    case party(UUID)
    case highlights(HighlightPeriod, Date)

    var id: String {
        switch self {
        case .friendInvite(let p): return "fi-" + p.t
        case .groupJoin(let id): return "gj-" + id.uuidString
        case .pwmInvite(let id): return "pwm-" + id.uuidString
        case .party(let id): return "party-" + id.uuidString
        case .highlights(let p, let d): return "hl-\(p.rawValue)-\(d.timeIntervalSince1970)"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let store: Store
    @ObservationIgnored let persistence: FilePersistence
    @ObservationIgnored let cloud: CloudSync
    @ObservationIgnored let shares: ShareService
    @ObservationIgnored let pings: PingService
    @ObservationIgnored let notifications: NotificationManager
    @ObservationIgnored let location: LocationService

    var availability: CloudAvailability = .unknown
    var tab: AppTab = .today
    var toasts: [Toast] = []
    var sheet: ActiveSheet?
    var groupOffers: [UUID: GroupJoinOffer] = [:]
    /// Live timed session cover.
    var showSession = false
    /// Poop With Me session to show on top of the live session.
    var openPWM: UUID?
    /// Short status for slow social operations ("Inviting…"). Never used for logging.
    var busy: String?
    var isForeground = true

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored var processing = false
    @ObservationIgnored private var pollTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init() {
        let dir = CloudConfig.localDirectory
        persistence = FilePersistence(directory: dir)
        store = Store(my: persistence.loadMy(), cache: persistence.loadCache())
        cloud = CloudSync(store: store, directory: dir)
        shares = ShareService(cloud: cloud, store: store)
        pings = PingService(store: store, directory: dir)
        notifications = NotificationManager()
        location = LocationService()

        store.onDirty = { [weak self] _ in self?.scheduleSave() }
        store.effectHandler = { [weak self] effect in self?.handle(effect) }
        cloud.onAvailabilityChange = { [weak self] a in self?.availability = a }
        cloud.onRemoteChangesApplied = { [weak self] in self?.pings.writeDirectory() }
    }

    // MARK: - Lifecycle

    /// Idempotent; concurrent callers wait for the same start.
    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        notifications.registerCategories()
        await notifications.refreshAuthorization()
        if notifications.authorization == .authorized || notifications.authorization == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
        await cloud.start()
        afterCloudStart()
    }

    private func afterCloudStart() {
        guard availability.isAvailable else { return }
        pings.writeDirectory()
        Task {
            await pings.refreshSubscriptions(force: false)
            await refresh()
        }
        notifications.rescheduleSummaries(settings: store.settings)
        for p in store.parties() where store.myRSVP(p)?.response != .no { notifications.scheduleParty(p, settings: store.settings) }
    }

    /// Foreground / pull-to-refresh: fetch everything, process pings, clean up.
    func refresh() async {
        guard availability.isAvailable else {
            // Not signed in earlier (or iCloud was busy): try again; afterCloudStart re-enters refresh when ready.
            await cloud.start()
            afterCloudStart()
            return
        }
        pings.cleanupExpired()
        cleanupSpaces()
        await cloud.fetchAll()
        await processIncomingPings()
    }

    func enteredForeground() {
        isForeground = true
        Task { await refresh() }
    }

    func enteredBackground() {
        isForeground = false
        saveNow()
        Task { await cloud.sendAll() }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try persistence.save(my: store.my)
            try persistence.save(cache: store.cache)
        } catch {
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
        cloud.metadata.flush()
    }

    /// Pushes queued CloudKit changes soon (live sessions feel snappier than the engine's default batching).
    private func scheduleSend() {
        sendTask?.cancel()
        sendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.cloud.sendAll()
        }
    }

    // MARK: - Effects

    private func handle(_ effect: Effect) {
        switch effect {
        case .save(let ref):
            cloud.save(ref)
            scheduleSend()
        case .delete(let ref):
            cloud.delete(ref)
            if case .invite(let token) = ref { Task { await shares.deleteInviteCard(token: token) } }
            scheduleSend()
        case .ping(let intent):
            pings.send(intent)
        case .cancelPings(let eventID):
            pings.cancel(eventID: eventID)
        case .scheduleLongSessionReminder(let id, let at):
            notifications.scheduleLongSessionReminder(eventID: id, at: at, settings: store.settings)
        case .cancelLongSessionReminder(let id):
            notifications.cancelLongSessionReminder(eventID: id)
        case .scheduleParty(_, let partyID):
            if let p = store.party(partyID) { notifications.scheduleParty(p, settings: store.settings) }
        case .cancelParty(let id):
            notifications.cancelParty(id)
        case .requestLocation(let eventID):
            location.locateOnce { [weak self] loc in
                guard let self, let loc else { return }
                self.store.attachLocation(loc, to: eventID)
            }
        case .refreshSubscriptions:
            pings.scheduleSubscriptionRefresh()
        case .refreshDirectory:
            pings.writeDirectory()
        case .rescheduleSummaries:
            notifications.rescheduleSummaries(settings: store.settings)
        case .achievementsUnlocked(let ids):
            for id in ids {
                show(Toast(style: .achievement(id), title: id.title.uppercased(), body: id.detail))
                if !isForeground && store.settings.notifyAchievements {
                    notifications.notifyNow(title: "🏆 \(id.title)", body: id.detail, settings: store.settings)
                }
            }
        case .cosmeticUnlocked(let id):
            show(Toast(style: .cosmetic(id), title: id.displayName.uppercased(), body: id.tagline))
        case .friendZoneGone(let uid):
            Task { await shares.unshareMyHistory(from: uid) }
        case .ensureZone(let zone):
            cloud.ensureZone(zone)
        case .haptic(let kind):
            Haptics.play(kind)
        }
    }

    // MARK: - Toasts

    func show(_ toast: Toast) {
        toasts.append(toast)
        let id = toast.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            self?.toasts.removeAll { $0.id == id }
        }
    }

    func info(_ title: String, _ body: String = "") { show(Toast(style: .info, title: title, body: body)) }

    func error(_ title: String, _ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        show(Toast(style: .error, title: title, body: message))
    }

    // MARK: - Live polling (only while a social screen is visible)

    func startPolling(_ zone: ZoneRef, every seconds: Double = 4) {
        let key = zone.description
        guard pollTasks[key] == nil else { return }
        pollTasks[key] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.cloud.fetch(zone: zone)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stopPolling(_ zone: ZoneRef) {
        pollTasks.removeValue(forKey: zone.description)?.cancel()
    }

    /// Friends' presence while TODAY is visible.
    func startPresencePolling() {
        guard pollTasks["presence"] == nil else { return }
        pollTasks["presence"] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await self?.cloud.fetchShared()
            }
        }
    }

    func stopPresencePolling() {
        pollTasks.removeValue(forKey: "presence")?.cancel()
    }
}
