import CloudKit
import Foundation
import Observation
import SwiftUI
import UIKit
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "app")

enum AppTab: String, CaseIterable, Hashable {
    case home, groups, calendar, you

    var title: String {
        switch self {
        case .home: return "HOME"
        case .groups: return "GROUPS"
        case .calendar: return "CALENDAR"
        case .you: return "YOU"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "map.fill"
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
    /// Watch (and react to) a Poop With Me session after my own DONE.
    case pwmWatch(UUID)
    case party(UUID)
    case highlights(HighlightPeriod, Date)
    /// Last week's highlights for one group (from a group highlights notification).
    case groupHighlights(ZoneRef)
    case profilePoster

    var id: String {
        switch self {
        case .friendInvite(let p): return "fi-" + p.t
        case .groupJoin(let id): return "gj-" + id.uuidString
        case .pwmInvite(let id): return "pwm-" + id.uuidString
        case .pwmWatch(let id): return "pwmw-" + id.uuidString
        case .party(let id): return "party-" + id.uuidString
        case .highlights(let p, let d): return "hl-\(p.rawValue)-\(d.timeIntervalSince1970)"
        case .groupHighlights(let z): return "ghl-" + z.description
        case .profilePoster: return "profile-poster"
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
    @ObservationIgnored let liveActivity = PoopingLiveActivityCoordinator()

    var availability: CloudAvailability = .unknown
    var tab: AppTab = .home
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
    /// True while "Delete all my data" runs (so our own zone deletions aren't treated as remote ones).
    @ObservationIgnored var isDeletingAll = false
    @ObservationIgnored private var pollTasks: [String: Task<Void, Never>] = [:]
    /// How many visible screens want each zone polled (panels can overlap during transitions).
    @ObservationIgnored private var pollRefs: [String: Int] = [:]
    @ObservationIgnored private var pollIntervals: [String: Double] = [:]
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var didFinishInitialStart = false
    /// "is pooping" alerts wait out the Undo window, so a mis-tap never reaches anyone.
    @ObservationIgnored private var pendingPoopPings: [UUID: PingIntent] = [:]
    @ObservationIgnored private var lastPoopPingAt: Date?
    /// At most one poop alert per this many seconds: a burst of logs doesn't spam every friend.
    static let poopPingCooldown: TimeInterval = 120

    init() {
        let dir = CloudConfig.localDirectory
        let filePersistence = FilePersistence(directory: dir)
        persistence = filePersistence
        var localMy = filePersistence.loadMy()
        // Location-backed poop pins are a core Home experience now. Existing users who have never
        // made a location choice inherit the new default; an explicit previous choice is preserved.
        if !localMy.settings.locationPrompted {
            localMy.settings.attachLocationByDefault = true
        }
        store = Store(my: localMy, cache: filePersistence.loadCache())
        cloud = CloudSync(store: store, directory: dir)
        shares = ShareService(cloud: cloud, store: store)
        pings = PingService(store: store, directory: dir)
        notifications = NotificationManager()
        location = LocationService()

        store.onDirty = { [weak self] _ in self?.scheduleSave() }
        store.onSessionChange = { [weak self] event in
            guard let self else { return }
            self.liveActivity.sync(event: event, cosmetic: self.store.profile.equippedCosmetic, privateMode: self.store.settings.lockScreenPrivate)
        }
        store.effectHandler = { [weak self] effect in self?.handle(effect) }
        cloud.onAvailabilityChange = { [weak self] a in self?.availability = a }
        cloud.onRemoteChangesApplied = { [weak self] in self?.pings.writeDirectory() }
        cloud.onMyDataDeletedRemotely = { [weak self] in self?.wipeAfterRemoteDeletion() }
    }

    // MARK: - Lifecycle

    /// Idempotent; concurrent callers wait for the same start.
    func start() async {
        liveActivity.sync(event: store.liveEvent, cosmetic: store.profile.equippedCosmetic, privateMode: store.settings.lockScreenPrivate)
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
        didFinishInitialStart = true
    }

    private func performStart() async {
        notifications.registerCategories()
        await notifications.refreshAuthorization()
        // Always register: iCloud sync relies on silent pushes, which need no alert permission.
        UIApplication.shared.registerForRemoteNotifications()
        await cloud.start()
        afterCloudStart()
    }

    private func afterCloudStart(scheduleInitialRefresh: Bool = true) {
        guard availability.isAvailable else { return }
        pings.writeDirectory()
        // Cached state paints Home immediately.  Stagger network/subscription work so MapKit gets
        // a clean first second instead of receiving several MainActor-heavy CloudKit callbacks at once.
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await pings.refreshSubscriptions(force: false)
        }
        if scheduleInitialRefresh { scheduleRefresh(afterNanoseconds: 1_250_000_000) }
        notifications.rescheduleSummaries(settings: store.settings, groups: store.groupSummaries)
        for p in store.parties() where store.myRSVP(p)?.response != .no { notifications.scheduleParty(p, settings: store.settings) }

        #if DEBUG
        // CKShare's system record type is only born after a real share is saved in Development.
        // Doing this automatically in debug makes the one-time Production schema deployment much harder to miss.
        Task { await shares.bootstrapDevelopmentSharingSchema() }
        #endif
    }

    /// Coalesces launch/foreground refreshes. SwiftUI can report `.active` while initial startup is still
    /// in flight; without this gate the app could start two full CloudKit fetches during cold launch.
    private func scheduleRefresh(afterNanoseconds delay: UInt64 = 0) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self else { return }
            defer { self.refreshTask = nil }
            guard !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    /// Foreground / pull-to-refresh: fetch everything, process pings, clean up.
    func refresh() async {
        if !availability.isAvailable {
            // Not signed in earlier (or iCloud was busy): try again, then continue this same refresh.
            await cloud.start()
            afterCloudStart(scheduleInitialRefresh: false)
            guard availability.isAvailable else { return }
        }
        pings.cleanupExpired()
        cleanupSpaces()
        await cloud.fetchAll()
        store.repairMyGroupRecords()
        // Groups may have been created, joined or left: keep per-group highlight alerts current.
        notifications.rescheduleSummaries(settings: store.settings, groups: store.groupSummaries)
        await processIncomingPings()
        await reconcileHistoryShareIfDue()
    }

    /// At most every 10 minutes: make sure only current friends can read my history.
    private func reconcileHistoryShareIfDue() async {
        let key = "sf.historyShareReconciledAt"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 600 { return }
        let allowed = Set(store.my.friendLinks.values.compactMap(\.userID))
        await shares.reconcileHistoryShare(allowed: allowed)
        UserDefaults.standard.set(Date(), forKey: key)
    }

    func enteredForeground() {
        isForeground = true
        liveActivity.sync(event: store.liveEvent, cosmetic: store.profile.equippedCosmetic, privateMode: store.settings.lockScreenPrivate)
        guard didFinishInitialStart else { return }
        scheduleRefresh()
    }

    func enteredBackground() {
        isForeground = false
        // iOS may suspend us before the Undo window ends; send what's still valid now.
        flushAllPoopPings()
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
            if case .poop(let eventID, _) = intent {
                queuePoopPing(intent, eventID: eventID)
            } else {
                pings.send(intent)
            }
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
            // Location is on by default for poop logs, but still requires the user's one-time iOS
            // permission. Ask contextually on the first located poop rather than during cold launch.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let allowed: Bool
                if self.location.isAuthorized {
                    allowed = true
                    if !self.store.settings.locationPrompted {
                        self.store.updateSettings { $0.locationPrompted = true }
                    }
                } else if self.location.isDenied {
                    // Every poop is pinned; there is no in-app "off". Without iOS permission the poop
                    // simply has no pin (Settings shows how to turn location back on).
                    allowed = false
                    if !self.store.settings.locationPrompted {
                        self.store.updateSettings { $0.locationPrompted = true }
                    }
                } else {
                    allowed = await self.location.requestAuthorization()
                    self.store.updateSettings { $0.locationPrompted = true }
                }
                guard allowed else { return }
                self.location.locateOnce { [weak self] loc in
                    guard let self, let loc else { return }
                    self.store.attachLocation(loc, to: eventID)
                }
            }
        case .refreshSubscriptions:
            pings.scheduleSubscriptionRefresh()
        case .refreshDirectory:
            pings.writeDirectory()
        case .rescheduleSummaries:
            notifications.rescheduleSummaries(settings: store.settings, groups: store.groupSummaries)
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

    // MARK: - Poop alerts

    private func queuePoopPing(_ intent: PingIntent, eventID: UUID) {
        pendingPoopPings[eventID] = intent
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Store.undoWindow + 0.5) * 1_000_000_000))
            self?.flushPoopPing(eventID)
        }
    }

    private func flushPoopPing(_ eventID: UUID) {
        guard let intent = pendingPoopPings.removeValue(forKey: eventID) else { return }
        // Undone or deleted inside the window: nobody hears about it.
        guard let event = store.my.events[eventID] else { return }
        // A timer already stopped inside the window must not announce "is pooping".
        if case .poop(_, let kind) = intent, kind == .poopStart, !event.isLive { return }
        let now = Date()
        if let last = lastPoopPingAt, now.timeIntervalSince(last) < AppModel.poopPingCooldown { return }
        lastPoopPingAt = now
        pings.send(intent)
    }

    private func flushAllPoopPings() {
        for id in Array(pendingPoopPings.keys) { flushPoopPing(id) }
    }

    // MARK: - Presentation

    /// SwiftUI can't present a cover or sheet while another one is still animating away. Use this when
    /// the same tap closes a sheet and opens something else.
    func afterDismissal(_ action: @escaping @MainActor (AppModel) -> Void) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self else { return }
            action(self)
        }
    }

    /// Opens the live session cover, waiting for a closing sheet first when needed.
    func presentSession(afterDismissal waits: Bool = false) {
        if waits || sheet != nil {
            sheet = nil
            afterDismissal { $0.showSession = true }
        } else {
            showSession = true
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
        show(Toast(style: .error, title: title, body: userFacingErrorMessage(error)))
    }

    /// Never expose CKRecord IDs, zone names, server schema strings, or other CloudKit internals in UI.
    func userFacingErrorMessage(_ error: Error) -> String {
        if let shareError = error as? ShareService.ShareError {
            return shareError.errorDescription ?? "iCloud couldn't finish that. Try again."
        }
        if let socialError = error as? SocialError {
            return socialError.errorDescription ?? "That didn't work. Try again."
        }
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated:
                return "Sign in to iCloud and try again."
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return "iCloud is temporarily unavailable. Try again in a moment."
            default:
                log.error("CloudKit operation failed: \(ckError.localizedDescription, privacy: .public)")
                return "iCloud couldn't finish that. Try again later."
            }
        }
        if let localized = error as? LocalizedError, let message = localized.errorDescription, !message.isEmpty {
            return message
        }
        log.error("operation failed: \(error.localizedDescription, privacy: .public)")
        return "Something went wrong. Try again."
    }

    // MARK: - Live polling (only while a social screen is visible)

    /// Reference-counted: every start must be balanced by a stop. The fastest requested interval wins.
    func startPolling(_ zone: ZoneRef, every seconds: Double = 4) {
        let key = zone.description
        pollRefs[key, default: 0] += 1
        let interval = min(seconds, pollIntervals[key] ?? seconds)
        if pollTasks[key] != nil, interval == pollIntervals[key] { return }
        pollTasks[key]?.cancel()
        pollIntervals[key] = interval
        pollTasks[key] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.cloud.fetch(zone: zone)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling(_ zone: ZoneRef) {
        let key = zone.description
        let remaining = max(0, (pollRefs[key] ?? 0) - 1)
        pollRefs[key] = remaining == 0 ? nil : remaining
        guard remaining == 0 else { return }
        pollTasks.removeValue(forKey: key)?.cancel()
        pollIntervals[key] = nil
    }

    /// Friends' presence while HOME is visible.
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
